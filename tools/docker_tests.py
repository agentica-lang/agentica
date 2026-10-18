#!/usr/bin/env python3
"""Run a test group in one owned Docker container.

The Ubuntu image (tools/ubuntu-test.Dockerfile) gets the checkout read-only at /source and two disposable named
volumes over /source/build and /source/dist, so the build artifacts never reach the checkout. The Windows image
(tools/windows-check.Dockerfile) runs the Wine checks against an .exe built on the host. Every mode checks the
container boundary before it runs a test, and the launcher always removes only the container it created.
"""

from __future__ import annotations

import argparse
import os
import shutil
import signal
import subprocess
import sys
import uuid
from pathlib import Path

CONTAINER_USER = "65534:65534"
CLEANUP_TIMEOUT = 15
MAX_TIMEOUT = 7200
# One mode, one limit in seconds: the build of a cold volume is about two minutes, and the slow tier is long.
MODE_TIMEOUTS = {
    "probe": 120,
    "fast": 1800,
    "files": 1800,
    "slow": 3600,
    "all": 5400,
    "bdd": 600,
    "windows-wine-tests": 900,
}
MODES = tuple(MODE_TIMEOUTS)
# Modes that run in the Ubuntu image; the rest use the Windows/Wine image the Makefile built.
UBUNTU_MODES = ("probe", "fast", "files", "slow", "all", "bdd")
# The destructive modes get no network and no host-visible storage.
NETWORKLESS_MODES = ("probe", "files", "bdd", "windows-wine-tests")
DESTRUCTIVE_MODES = ("files", "bdd", "windows-wine-tests")
ARTIFACT_DIRS = ("/source/build", "/source/dist")
VOLUME_PREFIX = "agentica-test-build"
DEFAULT_IMAGE = "agentica-ubuntu-test"

PROBE_MOUNTS = r"""
mount_options() { awk -v m="$1" '$5 == m { print $6 }' /proc/self/mountinfo; }
check_read_only() {
  options=$(mount_options "$1")
  [ -n "$options" ] || { echo "$1 is not a mount of its own" >&2; return 1; }
  case ",$options," in *,ro,*) return 0 ;; esac
  echo "$1 must be read-only in this sandbox" >&2
  return 1
}
check_read_only /
check_read_only /source
test -r /source/Makefile
test "${HOME#/tmp/}" != "$HOME"
test "${TEMP#/tmp/}" != "$TEMP"
test "${TMPDIR#/tmp/}" != "$TMPDIR"
"""
PROBE_TMPFS = r"""
mount_fstype() { awk -v m="$1" '$5 != m { next } { for (i = 7; i <= NF; i++) if ($i == "-") { print $(i + 1); exit } }' /proc/self/mountinfo; }
for directory in /tmp /var/tmp; do
  [ "$(mount_fstype "$directory")" = tmpfs ] || { echo "$directory must be disposable tmpfs storage" >&2; exit 1; }
done
"""
PROBE_ARTIFACTS = r"""
for part in /source/build /source/dist; do
  options=$(mount_options "$part")
  [ -n "$options" ] || { echo "$part must be a disposable volume, not the checkout" >&2; exit 1; }
  case ",$options," in *,ro,*) echo "$part must be writable inside the sandbox" >&2; exit 1 ;; esac
done
"""
PROBE_COMMAND = r"""
set -eu
mkdir -p "$HOME" "$TEMP" "$TMPDIR" "$WINEPREFIX" "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
""" + PROBE_MOUNTS + PROBE_TMPFS

BUILD_COMMAND = r"""
cd /source
export PYTHONDONTWRITEBYTECODE=1
export AGENTICA_TEST_EXECUTABLE=/source/dist/agentica
export AGENTICA_VM_BINARY=/source/dist/agentica
export AGENTICA_TEST_TARGET_OS=linux
export AGENTICA_REQUIRE_VM=1
export PYTEST_ADDOPTS="${PYTEST_ADDOPTS:-} -p no:cacheprovider"
jobs=${JOBS:-4}
make -j"$jobs" dist/agentica
"""
FAST_COMMAND = BUILD_COMMAND + r"""
make -j"$jobs" test AGENTICA_TEST_SLOW=
"""
SLOW_COMMAND = BUILD_COMMAND + r"""
make -j"$jobs" test-slow
"""
FILES_COMMAND = BUILD_COMMAND + r"""
make -j"$jobs" build/vm/release/tree-test build/vm/release/files_private-test
build/vm/release/tree-test
build/vm/release/files_private-test
python3 -m pytest -p no:cacheprovider tests/test_vm_os_remove.py tests/test_bdd_cleanup.py
"""
BDD_COMMAND = BUILD_COMMAND + r"""
cd /source
TMPDIR=/tmp/temp /source/dist/agentica test /source/tests/bdd/specs/ --steps /source/tests/bdd/handlers.agc
"""
WINDOWS_WINE_TEST_COMMAND = r"""
set -eu
test -x /source/dist/agentica.exe
command -v wine >/dev/null
export WINEDEBUG=-all WINEDLLOVERRIDES=mscoree,mshtml=
wrapper=/tmp/wine-agentica
printf '#!/bin/sh\nexec wine /source/dist/agentica.exe "$@"\n' > "$wrapper"
chmod 555 "$wrapper"
cd /source
export PYTHONPATH=/source PYTHONDONTWRITEBYTECODE=1
export AGENTICA_TEST_TARGET_OS=windows AGENTICA_TEST_WINE=1
export AGENTICA_TEST_EXECUTABLE="$wrapper" AGENTICA_VM_BINARY="$wrapper"
export AGENTICA_REQUIRE_VM=1
python3 -m pytest -p no:cacheprovider tests/test_windows_filesystem_safety.py tests/test_windows_metadata_and_locks.py
"""
GROUP_COMMANDS = {
    "probe": "",
    "fast": FAST_COMMAND,
    "slow": SLOW_COMMAND,
    "files": FILES_COMMAND,
    "all": FAST_COMMAND + SLOW_COMMAND + FILES_COMMAND,
    "bdd": BDD_COMMAND,
    "windows-wine-tests": WINDOWS_WINE_TEST_COMMAND,
}


class SandboxError(RuntimeError):
    """A preflight, Docker, timeout, or cleanup failure."""


def _stop_client(process: subprocess.Popen[str]) -> None:
    """Stop the Docker CLI process group without leaving its client running."""
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()


def _run_docker(
    docker: str, arguments: list[str], *, timeout: int
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [docker, *arguments],
        check=False,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def _require_docker(mode: str) -> str:
    docker = shutil.which("docker")
    if docker is None:
        raise SandboxError(f"Docker is required for mode {mode}; refusing to run it on the host")
    if os.name != "posix":
        raise SandboxError("the Docker runner requires POSIX process-group cleanup support")
    return docker


def _image_id(docker: str, image: str) -> str:
    inspected = _run_docker(docker, ["image", "inspect", "--format", "{{.Id}}", image], timeout=15)
    if inspected.returncode or not inspected.stdout.strip():
        raise SandboxError(f"the Docker image {image} is missing: build it with make docker-test-image")
    return inspected.stdout.strip()


def _artifact_volumes(docker: str, image: str, mode: str) -> dict[str, str]:
    """Create the disposable build volumes; their name follows the image so a rebuilt image builds again."""
    if mode not in UBUNTU_MODES:
        return {}
    digest = _image_id(docker, image).split(":")[-1][:12]
    volumes = {f"{VOLUME_PREFIX}-{role}-{digest}": path
               for role, path in zip(("build", "dist"), ARTIFACT_DIRS)}
    for name in volumes:
        created = _run_docker(docker, ["volume", "create", name], timeout=30)
        if created.returncode:
            raise SandboxError(f"could not create the disposable build volumes: {created.stderr.strip()}")
    return volumes


def _prepare_volumes(docker: str, image: str, volumes: dict[str, str]) -> None:
    """Give the unprivileged container user the disposable volumes it writes its build into."""
    if not volumes:
        return
    mounts: list[str] = []
    roots: list[str] = []
    for name, target in volumes.items():
        root = "/mnt" + target.removeprefix("/source")
        roots.append(root)
        mounts += ["--mount", f"type=volume,src={name},dst={root}"]
    prepared = _run_docker(
        docker,
        ["run", "--rm", "--user=0:0", *mounts, "--entrypoint", "/bin/sh", image, "-ec",
         f"chown {CONTAINER_USER} " + " ".join(roots)],
        timeout=60,
    )
    if prepared.returncode:
        raise SandboxError(f"could not prepare the disposable build volumes: {prepared.stderr.strip()}")


def _container_arguments(
    docker: str,
    *,
    name: str,
    image: str,
    repository: Path,
    mode: str,
    volumes: dict[str, str],
    command: str,
) -> list[str]:
    arguments = [
        "create",
        "--name",
        name,
        "--read-only",
        "--cap-drop=ALL",
        "--security-opt=no-new-privileges",
        f"--user={CONTAINER_USER}",
        f"--memory={os.environ.get('DOCKER_MEMORY', '4g')}",
        f"--memory-swap={os.environ.get('DOCKER_MEMORY', '4g')}",
        "--pids-limit=512",
        # Tests and the Wine wrapper execute only from disposable storage.
        "--tmpfs",
        # A fresh 64-bit Wine prefix alone needs about 1.4 GiB in this image.
        # Keep its storage disposable and bounded without starving initialization.
        f"/tmp:rw,nosuid,nodev,exec,size={'3g' if mode == 'windows-wine-tests' else '1g'},mode=1777",
        "--tmpfs",
        "/var/tmp:rw,nosuid,nodev,exec,size=512m,mode=1777",
        "--mount",
        f"type=bind,src={repository},dst=/source,readonly",
    ]
    for volume, target in volumes.items():
        arguments += ["--mount", f"type=volume,src={volume},dst={target}"]
    if mode in NETWORKLESS_MODES:
        arguments.append("--network=none")
    arguments += [
        "--workdir",
        "/source",
        "--entrypoint",
        "/bin/sh",
        "-e",
        "HOME=/tmp/home",
        "-e",
        "TEMP=/tmp/temp",
        "-e",
        "TMP=/tmp/temp",
        "-e",
        "TMPDIR=/tmp/temp",
        "-e",
        "WINEPREFIX=/tmp/wine",
        "-e",
        "XDG_RUNTIME_DIR=/tmp/xdg",
        "-e",
        f"JOBS={os.environ.get('JOBS', '4')}",
    ]
    if mode in DESTRUCTIVE_MODES:
        arguments += ["-e", "AGENTICA_REMOVE_TEST_MODE=docker"]
    arguments += [image, "-ec", command]
    return arguments


def run_group(
    image: str,
    mode: str = "probe",
    timeout: int | None = None,
) -> int:
    """Run one test group in one container this launcher owns."""
    docker = _require_docker(mode)
    limit = MODE_TIMEOUTS[mode] if timeout is None else timeout
    if limit < 1 or limit > MAX_TIMEOUT:
        raise SandboxError(f"timeout must be between 1 and {MAX_TIMEOUT} seconds")

    repo = Path(__file__).resolve().parents[1]
    name = f"agentica-test-{uuid.uuid4().hex}"
    probe = PROBE_COMMAND + (PROBE_ARTIFACTS if mode in UBUNTU_MODES else "")
    command = probe + "\n" + GROUP_COMMANDS[mode]

    volumes = _artifact_volumes(docker, image, mode)
    _prepare_volumes(docker, image, volumes)
    create_args = _container_arguments(
        docker,
        name=name,
        image=image,
        repository=repo,
        mode=mode,
        volumes=volumes,
        command=command,
    )

    process: subprocess.Popen[str] | None = None
    status = 1
    cleanup_error: str | None = None
    create_attempted = False
    try:
        create_attempted = True
        created = _run_docker(docker, create_args, timeout=30)
        if created.returncode:
            raise SandboxError(f"could not create the sandbox container: {created.stderr.strip()}")
        process = subprocess.Popen([docker, "start", "--attach", name], start_new_session=True)
        try:
            status = process.wait(timeout=limit)
        except subprocess.TimeoutExpired as exc:
            _stop_client(process)
            raise SandboxError(f"mode {mode} exceeded {limit} seconds") from exc
    except KeyboardInterrupt:
        if process is not None:
            _stop_client(process)
        raise
    finally:
        if process is not None:
            _stop_client(process)
        if create_attempted:
            removed = _run_docker(docker, ["rm", "--force", name], timeout=CLEANUP_TIMEOUT)
            if removed.returncode:
                cleanup_error = removed.stderr.strip() or "Docker could not remove the container it created"

    if cleanup_error:
        raise SandboxError(cleanup_error)
    return status


def main(argv: list[str] | None = None) -> int:
    """Select a test group and report execution or cleanup failures."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=MODES, default="probe")
    parser.add_argument("--image", default=os.environ.get("TEST_IMAGE", DEFAULT_IMAGE))
    parser.add_argument("--timeout", type=int, default=None)
    args = parser.parse_args(argv)

    def interrupt(signum: int, frame: object) -> None:
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupt)
    signal.signal(signal.SIGHUP, interrupt)
    try:
        status = run_group(args.image, args.mode, args.timeout)
    except (SandboxError, subprocess.TimeoutExpired, OSError) as exc:
        print(f"docker-tests: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("docker-tests: interrupted; owned container cleanup attempted", file=sys.stderr)
        return 130
    if status:
        print(f"docker-tests: mode {args.mode} exited with status {status}", file=sys.stderr)
    return status


if __name__ == "__main__":
    raise SystemExit(main())
