#!/usr/bin/env python3
"""Run removal-test boundary probes and regressions in one owned Docker container."""

from __future__ import annotations

import argparse
import os
import shutil
import signal
import subprocess
import sys
import uuid
from pathlib import Path

CONTAINER_TIMEOUT = 120
CLEANUP_TIMEOUT = 15
PROBE_COMMAND = r"""
set -eu
mkdir -p "$HOME" "$TEMP" "$WINEPREFIX"
test -r /source/Makefile
check_mount() {
  wanted=$1
  while IFS= read -r line; do
    set -- $line
    if [ "$5" = "$wanted" ]; then
      if [ "$wanted" != /tmp ]; then
        case ",$6," in *,ro,*) : ;; *) return 1 ;; esac
      else
        while [ "$1" != - ]; do shift; done
        shift
        [ "$1" = tmpfs ] || return 1
      fi
      return 0
    fi
  done < /proc/self/mountinfo
  return 1
}
check_mount /
check_mount /source
check_mount /tmp
test "${HOME#/tmp/}" != "$HOME"
test "${TEMP#/tmp/}" != "$TEMP"
test "${WINEPREFIX#/tmp/}" != "$WINEPREFIX"
printf "%s\n" "sandbox boundary probe passed"
"""
REMOVE_TEST_COMMAND = r"""
set -eu
for binary in /source/build/vm/release/tree-test /source/build/vm/release/files_private-test; do
  test -x "$binary"
  missing=$(ldd "$binary" | grep 'not found' || true)
  if [ -n "$missing" ]; then
    printf 'test runtime dependency missing:\n%s\n' "$missing" >&2
    exit 1
  fi
done
printf "%s\n" "starting isolated Linux removal regressions"
/source/build/vm/release/tree-test
/source/build/vm/release/files_private-test
cd /source
export PYTHONPATH=/source PYTHONDONTWRITEBYTECODE=1
export AGENTICA_TEST_EXECUTABLE=/source/dist/agentica
export AGENTICA_VM_BINARY=/source/dist/agentica
export AGENTICA_REQUIRE_VM=1 AGENTICA_TEST_TARGET_OS=linux
python3 -m unittest tests.test_vm_os_remove tests.test_bdd_cleanup
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
python3 -m unittest tests.test_windows_remove_refusal
"""
BDD_CHECK_COMMAND = r"""
set -eu
mkdir -p /tmp/bdd-work
cd /source
TMPDIR=/tmp/bdd-work /source/dist/agentica test /source/tests/bdd/specs/ --steps /source/tests/bdd/handlers.agc
"""


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


def run_probe(
    image: str,
    timeout: int = CONTAINER_TIMEOUT,
    mode: str = "probe",
) -> int:
    """Run the explicit probe or isolated Linux removal suite in one owned container."""
    docker = shutil.which("docker")
    if docker is None:
        raise SandboxError("Docker is required; refusing to run the probe on the host")
    if timeout < 1 or timeout > CONTAINER_TIMEOUT:
        raise SandboxError(f"timeout must be between 1 and {CONTAINER_TIMEOUT} seconds")
    if mode not in ("probe", "remove-tests", "bdd-check", "windows-wine-tests"):
        raise SandboxError("unknown sandbox mode")
    if os.name != "posix":
        raise SandboxError("the Docker runner requires POSIX process-group cleanup support")

    repo = Path(__file__).resolve().parents[1]
    name = f"agentica-remove-probe-{uuid.uuid4().hex}"
    inspected = _run_docker(docker, ["image", "inspect", image], timeout=10)
    if inspected.returncode:
        raise SandboxError(f"required preloaded Docker image is unavailable: {image}")

    container_command = PROBE_COMMAND
    if mode == "remove-tests":
        container_command += REMOVE_TEST_COMMAND
    elif mode == "bdd-check":
        container_command += BDD_CHECK_COMMAND
    elif mode == "windows-wine-tests":
        container_command += WINDOWS_WINE_TEST_COMMAND

    create_args = [
        "create",
        "--name",
        name,
        "--read-only",
        "--cap-drop=ALL",
        "--security-opt=no-new-privileges",
        *(["--user=65534:65534"] if mode == "remove-tests" else []),
        "--network=none",
        "--memory=2g",
        "--memory-swap=2g",
        "--pids-limit=128",
        # Test peers and the Wine wrapper execute only from disposable storage.
        "--tmpfs",
        "/tmp:rw,nosuid,nodev,exec,size=512m,mode=1777",
        "--mount",
        f"type=bind,src={repo},dst=/source,readonly",
        "--workdir",
        "/tmp",
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
        image,
        "-ec",
        container_command,
    ]
    process: subprocess.Popen[str] | None = None
    status = 1
    cleanup_error: str | None = None
    create_attempted = False
    try:
        create_attempted = True
        created = _run_docker(docker, create_args, timeout=30)
        if created.returncode:
            raise SandboxError(f"could not create isolated probe container: {created.stderr.strip()}")
        process = subprocess.Popen(
            [docker, "start", "--attach", name],
            start_new_session=True,
        )
        try:
            status = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired as exc:
            _stop_client(process)
            raise SandboxError(f"sandbox probe exceeded {timeout} seconds") from exc
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
                cleanup_error = removed.stderr.strip() or "Docker could not remove the owned probe container"

    if cleanup_error:
        raise SandboxError(cleanup_error)
    return status


def main(argv: list[str] | None = None) -> int:
    """Select an isolated mode and report execution or cleanup failures."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--mode",
        choices=("probe", "remove-tests", "bdd-check", "windows-wine-tests"),
        default="probe",
    )
    parser.add_argument("--image", default=os.environ.get("WINDOWS_IMAGE", "agentica-windows-check"))
    parser.add_argument("--timeout", type=int, default=CONTAINER_TIMEOUT)
    args = parser.parse_args(argv)

    def interrupt(signum: int, frame: object) -> None:
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupt)
    signal.signal(signal.SIGHUP, interrupt)
    try:
        status = run_probe(args.image, args.timeout, args.mode)
    except (SandboxError, subprocess.TimeoutExpired, OSError) as exc:
        print(f"windows-docker-remove-check: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("windows-docker-remove-check: interrupted; owned container cleanup attempted", file=sys.stderr)
        return 130
    if status:
        print(f"windows-docker-remove-check: probe exited with status {status}", file=sys.stderr)
    return status


if __name__ == "__main__":
    raise SystemExit(main())
