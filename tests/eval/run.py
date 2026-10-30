#!/usr/bin/env python3
import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EVAL = ROOT / "tests" / "eval"
TASKS = EVAL / "tasks"
SKILL = ROOT / ".agents" / "skills" / "agentica-programming"
ARMS = {"skill": "agc", "grammar": "agc", "binary": "agc", "python": "py", "typed-python": "py", "skill-nocli": "agc"}
TYPED_ARMS = {"typed-python"}
SKILL_ARMS = {"skill", "skill-nocli"}
# Arms that run only when asked for with --arms: the default is the five arms of the early rounds.
OPT_IN_ARMS = {"skill-nocli"}
NOCLI_NOTE = "agentica --help and agentica help still name the four query commands; the wrapper only refuses them"
REFERENCE_ARMS = ["binary", "python", "typed-python"]
CHECKER = ["mypy", "--strict", "--cache-dir=/dev/null"]
CHECK_TIMEOUT = 90
NET_STRONG = re.compile(r"\bwget\b|\bgit\s+clone\b|github\.com|\bpip3?\s+install\b|\bnpm\b|\bapt(?:-get)?\b")
NET_WEAK = re.compile(r"\bcurl\b|\burllib\b")
LOOPBACK = re.compile(r"\blocalhost\b|127\.0\.0\.1")
COMMAND_PREFIX = r"^\s*(?:(?:env|time|timeout\s+(?:-\S+\s+)*\d\S*|\w+=\S*)\s+)*"
CHECK_COMMAND = re.compile(COMMAND_PREFIX + r"(?:(?:python3?\s+-m\s+)?(?:\S*/)?mypy|(?:\S*/)?agentica\s+check)\b")
MYPY_COMMAND = re.compile(COMMAND_PREFIX + r"(?:python3?\s+-m\s+)?(?:\S*/)?mypy\b")
# `agentica [--json|--ai|--partial] outline|type-at|symbol|refs ...`, also through a path (`dist/agentica`) or the
# renamed binary of the skill-nocli arm (`agentica-real`).
# Global options may come first: flags, `--` and the four that take a value.
QUERY_COMMAND = re.compile(COMMAND_PREFIX + r"(?:\S*/)?agentica(?:-real)?\s+"
                           r"(?:(?:--(?:json|ai|partial|deny-run|deny-native|dump|dump-ir)|--)\s+"
                           r"|--(?:max-steps|seed|flush-timeout|schedulers|steps)\s+\S+\s+)*"
                           r"(?:outline|type-at|symbol|refs)(?=\s|$)")
READ_COMMAND = re.compile(COMMAND_PREFIX + r"(?:\S*/)?(?:cat|rg|sed|head|grep|tail)(?=\s|$)")
REFUSED_LOG = ".refused-queries"
REAL_BINARY = "agentica-real"
# The wrapper of the skill-nocli arm. It refuses the first word that is not an option (or the value of one) when it
# names a query command (exit 2, a short stderr line, one line in REFUSED_LOG so the runner can count refusals) and
# hands everything else to the real binary, with exec so the exit status and the signals are the binary's.
QUERY_WRAPPER = """#!/bin/sh
case $0 in */*) here=${0%/*} ;; *) here=. ;; esac
skip=0
for word in "$@"; do
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case $word in
    --max-steps|--seed|--flush-timeout|--schedulers|--steps) skip=1 ;;
    -*) ;;
    outline|type-at|symbol|refs)
      echo "$word" >> "$here/@LOG@"
      echo "agentica: '$word' is not available in this evaluation arm" >&2
      exit 2 ;;
    *) break ;;
  esac
done
exec "$here/@REAL@" "$@"
""".replace("@LOG@", REFUSED_LOG).replace("@REAL@", REAL_BINARY)
# What the skill copy of the skill-nocli arm must not name any more.
QUERY_MENTION = re.compile(r"queries\.md|analysis\.md|QUERY-|std/analysis|`type-at`|agentica\s+(?:outline|type-at|symbol|refs)\b")
TYPE_SILENCE = re.compile(r"#\s*mypy:|#\s*type:\s*ignore")
TYPE_ESCAPE = re.compile(r"\bAny\b|\bcast\(|\bno_type_check\b|\bTYPE_CHECKING\b")
MISSING_COMMAND = (126, 127)
AGENT_NETWORK = True
CASE_TIMEOUT = 10
WRITE_LOCK = threading.Lock()
WORKSPACE = Path("/workspace")
SYSTEM_PATH = "/usr/local/bin:/usr/bin:/bin"
ROOTFS_PATH = f"/workspace/bin:{SYSTEM_PATH}"
SAFE_ENV = {"LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "PYTHONUTF8": "1", "TMPDIR": "/tmp"}
DEFAULT_IMAGE = "agentica-eval:local"
DEFAULT_ARMS = [arm for arm in ARMS if arm not in OPT_IN_ARMS]


def build() -> None:
    subprocess.run(["make"], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    runtime = ROOT / "dist" / "runtime"
    shutil.rmtree(runtime, ignore_errors=True)
    (runtime / "bin").mkdir(parents=True)
    shutil.copy2(ROOT / "dist" / "agentica", runtime / "bin" / "agentica")


def clone_rootfs(template: Path, destination: Path) -> Path:
    if not template.is_dir():
        raise SystemExit(f"chroot root filesystem not found: {template}")
    shutil.copytree(template, destination, symlinks=True)
    workspace = destination / "workspace"
    if workspace.is_symlink() or workspace.is_file():
        workspace.unlink()
    elif workspace.exists():
        shutil.rmtree(workspace)
    home = destination / "home"
    if home.is_symlink() or home.is_file():
        home.unlink()
    home.mkdir(exist_ok=True)
    agent_home = home / "agent"
    if agent_home.is_symlink() or agent_home.is_file():
        agent_home.unlink()
    elif agent_home.exists():
        shutil.rmtree(agent_home)
    return destination


def start_file(task: str, arm: str) -> Path:
    ext = ARMS[arm]
    typed = TASKS / task / f"start.typed.{ext}"
    if arm in TYPED_ARMS and typed.exists():
        return typed
    return TASKS / task / f"start.{ext}"


def prepare(work: Path, task: str, arm: str) -> None:
    ext = ARMS[arm]
    work.mkdir(parents=True, exist_ok=True)
    shutil.copy(TASKS / task / "task.md", work / "task.md")
    start = start_file(task, arm)
    if start.exists():
        shutil.copy(start, work / f"start.{ext}")
    if ext == "agc":
        shutil.copytree(ROOT / "dist" / "runtime", work, dirs_exist_ok=True)
    if arm in SKILL_ARMS:
        (work / "skills").mkdir()
        shutil.copytree(SKILL, work / "skills" / "agentica-programming")
    if arm == "skill-nocli":
        strip_query_docs(work / "skills" / "agentica-programming")
        install_query_wrapper(work / "bin")
    if arm == "grammar":
        (work / "docs").mkdir()
        parts = sorted((ROOT / "docs" / "grammar").glob("*.md"))
        text = "\n".join(part.read_text(encoding="utf-8") for part in parts)
        # The grammar keeps the language rules and points to the library pages for every builtin, so the arm gets the
        # pages too, next to grammar.md; the other links out of the grammar lead nowhere in the work folder.
        text = re.sub(r"\]\((?:\.\./){2}site/content/library/", "](library/", text)
        text = re.sub(r"\[([^\]]*)\]\(\.\./[^)]*\)", r"\1", text)
        (work / "docs" / "grammar.md").write_text(text, encoding="utf-8")
        shutil.copytree(ROOT / "site" / "content" / "library", work / "docs" / "library")
        shutil.copytree(ROOT / "examples", work / "examples")


def strip_query_docs(skill: Path) -> None:
    """Remove the query commands from the copy of the skill the agent gets (never from the repository's skill).

    Drops queries.md and analysis.md, the lines of SKILL.md that point to them, the QUERY- codes of
    diagnostics.md and the `type-at` cache note of language-running.md. It stops the run when a
    mention is left, so a skill edit cannot leak the commands unnoticed.
    """
    for name in ("queries.md", "analysis.md"):
        (skill / "references" / name).unlink()
    core = skill / "SKILL.md"
    text = core.read_text(encoding="utf-8")
    text = re.sub(r"^\| `(?:queries|analysis)\.md` \|.*\n", "", text, flags=re.MULTILINE)
    core.write_text(text, encoding="utf-8")
    codes = skill / "references" / "diagnostics.md"
    text = codes.read_text(encoding="utf-8")
    text = re.sub(r"^- `QUERY-.*\n(?:  .*\n)*", "", text, flags=re.MULTILINE)
    text = re.sub(r"\s*`QUERY-` is a\s+bad\s+question\s+to.*?`refs`\.", "", text, flags=re.DOTALL)
    codes.write_text(text, encoding="utf-8")
    running = skill / "references" / "language-running.md"
    text = running.read_text(encoding="utf-8")
    text = text.replace("`check` and `type-at` keep", "`check` keeps").replace("rules and give the", "rules and gives the")
    running.write_text(text, encoding="utf-8")
    for path in sorted(skill.rglob("*.md")):
        found = QUERY_MENTION.search(path.read_text(encoding="utf-8"))
        if found:
            raise SystemExit(f"skill-nocli: {path.relative_to(skill)} still mentions the query commands ({found.group(0)!r}); "
                             "update strip_query_docs")


def install_query_wrapper(bin_dir: Path) -> None:
    """Put the refusing `agentica` in front of the real binary, which keeps its place under another name."""
    os.replace(bin_dir / "agentica", bin_dir / REAL_BINARY)
    wrapper = bin_dir / "agentica"
    wrapper.write_text(QUERY_WRAPPER, encoding="utf-8")
    wrapper.chmod(0o755)


def refused_queries(work: Path) -> int:
    log = work / "bin" / REFUSED_LOG
    return len(log.read_text(encoding="utf-8", errors="replace").splitlines()) if log.is_file() else 0


def prompt(work: Path, arm: str) -> str:
    ext = ARMS[arm]
    lines = ["Read task.md in the current directory and do what it asks."]
    if (work / f"start.{ext}").exists():
        lines.append(f"The starting program is start.{ext}.")
    if ext == "agc":
        lines.append("Write a complete Agentica program to solution.agc. Run programs with the `agentica` command, which is on your PATH.")
        if arm in SKILL_ARMS:
            lines.append("Use the agentica-programming skill.")
        elif arm == "binary":
            lines.append("The language is Agentica: Ruby-like syntax, statically typed, programs start with `def main() -> Void`. "
                         "`agentica file.agc` runs a program and `agentica check file.agc` checks it without running. "
                         "`agentica --help` lists the options.")
        else:
            lines.append("The language is described in docs/grammar.md, the builtin library in docs/library/, "
                         "and example programs are in examples/. Use `agentica help NAME` for builtin signatures.")
    elif arm in TYPED_ARMS:
        lines.append("Write a complete Python 3 program to solution.py, with type annotations on every function. "
                     "Run programs with `python3`. The type checker is `mypy --strict solution.py`, on your PATH: "
                     "the solution must pass it, so do not silence it with `# type: ignore` or by weakening its options.")
    else:
        lines.append("Write a complete Python 3 program to solution.py. Run programs with `python3`.")
    lines.append("Work only inside the current directory. Test your program before you finish, then reply with one sentence.")
    return " ".join(lines)


def agent_command(agent: str, work: Path, arm: str, model: str | None, *, in_chroot: bool) -> list[str]:
    text = prompt(work, arm)
    workspace = WORKSPACE if in_chroot else work
    if agent == "pi":
        cmd = ["pi", "-p", "--mode", "json", "--no-session", "--no-context-files", "--no-extensions"]
        cmd += ["--skill", str(workspace / "skills" / "agentica-programming")] if arm in SKILL_ARMS else ["--no-skills"]
        if model:
            cmd += ["--model", model]
        return cmd + [text]
    if agent == "claude":
        cmd = ["claude", "-p", "--output-format", "json", "--no-session-persistence", "--dangerously-skip-permissions", "--strict-mcp-config"]
        if arm not in SKILL_ARMS:
            cmd += ["--disable-slash-commands"]
        else:
            target = work / ".claude" / "skills"
            target.mkdir(parents=True, exist_ok=True)
            shutil.copytree(work / "skills" / "agentica-programming", target / "agentica-programming")
        if model:
            cmd += ["--model", model]
        return cmd + [text]
    raise SystemExit(f"unknown agent {agent}")


def jail_prefix(rootfs: Path, *, network: bool) -> list[str]:
    command = [
        shutil.which("firejail") or "firejail",
        "--quiet",
        "--noprofile",
        f"--chroot={rootfs}",
        "--private-tmp",
        "--nonewprivs",
        "--caps.drop=all",
        "--seccomp",
    ]
    if not network:
        command.append("--net=none")
    return command


def docker_prefix(work: Path, image: str, name: str, *, network: bool, pass_env: list[str]) -> list[str]:
    uid, gid = os.getuid(), os.getgid()
    command = [
        shutil.which("docker") or "docker", "run", "--rm", "--interactive",
        "--name", name, "--user", f"{uid}:{gid}",
        "--read-only", "--cap-drop=ALL", "--security-opt=no-new-privileges",
        "--pids-limit=256", "--memory=2g", "--cpus=2",
        "--tmpfs", "/tmp:rw,nosuid,nodev,size=128m",
        "--tmpfs", f"/home/agent:rw,nosuid,nodev,uid={uid},gid={gid},size=128m",
        "--mount", f"type=bind,src={work},dst=/workspace" + ("" if network else ",readonly"),
        "--workdir", "/workspace",
    ]
    if not network:
        command.append("--network=none")
    for key in [*grader_environment(), *pass_env]:
        command += ["--env", key]
    return command + [image]


def remove_container(name: str) -> None:
    subprocess.run([shutil.which("docker") or "docker", "rm", "--force", name],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)


def build_image(image: str) -> None:
    try:
        subprocess.run(["docker", "build", "--tag", image, "--file", str(EVAL / "Dockerfile"), str(EVAL)], check=True)
    except (OSError, subprocess.CalledProcessError) as exc:
        raise SystemExit(f"Building the Docker image {image} failed ({exc}); check that the Docker daemon is running") from exc


def require_docker() -> None:
    if not shutil.which("docker"):
        raise SystemExit("docker is required for evaluation; alternatively select --sandbox firejail")


def image_exists(image: str) -> bool:
    return subprocess.run(["docker", "image", "inspect", image], capture_output=True).returncode == 0


def image_id(image: str) -> str | None:
    done = subprocess.run(["docker", "image", "inspect", "--format", "{{.Id}}", image], capture_output=True, text=True)
    return done.stdout.strip() if done.returncode == 0 else None


def probe(image: str, command: list[str], work: Path, timeout: int) -> tuple[int | None, str, str]:
    name = f"agentica-probe-{uuid.uuid4().hex}"
    try:
        done = subprocess.run(docker_prefix(work, image, name, network=False, pass_env=[]) + command,
                              env=grader_environment(), capture_output=True, text=True, errors="replace",
                              timeout=timeout)
        return done.returncode, done.stdout, done.stderr
    except subprocess.TimeoutExpired:
        return None, "", "timeout"
    finally:
        remove_container(name)


def python_runs(image: str) -> str | None:
    with tempfile.TemporaryDirectory(prefix="agentica-docker-probe-") as directory:
        code, _, err = probe(image, ["python3", "-I", "-c", "pass"], Path(directory), 30)
    return None if code == 0 else err


def checker_probe(image: str) -> tuple[int | None, str, str]:
    with tempfile.TemporaryDirectory(prefix="agentica-checker-probe-") as directory:
        return probe(image, [CHECKER[0], "--version"], Path(directory), 60)


def checker_version(image: str) -> str | None:
    code, out, _ = checker_probe(image)
    return out.strip() if code == 0 else None


def runtime_probe(image: str) -> tuple[bool, str]:
    with tempfile.TemporaryDirectory(prefix="agentica-runtime-probe-") as directory:
        work = Path(directory)
        shutil.copytree(ROOT / "dist" / "runtime", work, dirs_exist_ok=True)
        (work / "hello.agc").write_text('def main() -> Void\n  puts("hello")\nend\n', encoding="utf-8")
        code, out, err = probe(image, [str(WORKSPACE / "bin" / "agentica"), "hello.agc"], work, 60)
    return code == 0 and out.strip() == "hello", err.strip() or out.strip()


def ensure_checker(image: str) -> str:
    code, out, err = checker_probe(image)
    if code in MISSING_COMMAND and image == DEFAULT_IMAGE:
        print(f"{CHECKER[0]} is missing from {image} (exit {code}): rebuilding the image from tests/eval/Dockerfile", flush=True)
        build_image(image)
        code, out, err = checker_probe(image)
    if code != 0:
        reason = "it timed out" if code is None else f"it exited {code}: {err.strip()}"
        hint = " Rebuild the image from tests/eval/Dockerfile." if code in MISSING_COMMAND else ""
        raise SystemExit(f"{CHECKER[0]} --version failed in the Docker image {image} ({reason}); the typed-python arm needs it.{hint}")
    return out.strip()


def ensure_runtime(image: str) -> None:
    works, details = runtime_probe(image)
    if not works and image == DEFAULT_IMAGE:
        print(f"{image} cannot run dist/runtime/bin/agentica ({details}): rebuilding the image from tests/eval/Dockerfile", flush=True)
        build_image(image)
        works, details = runtime_probe(image)
    if not works:
        raise SystemExit(f"The Docker image {image} cannot run dist/runtime/bin/agentica ({details}). "
                         "Rebuild it from tests/eval/Dockerfile (docker build --tag IMAGE tests/eval); "
                         "if it still fails, the VM needs a newer libc or other libraries than the image has.")


def dockerfile_pi_version() -> str | None:
    found = re.search(r"^ARG PI_VERSION=(\S+)", (EVAL / "Dockerfile").read_text(encoding="utf-8"), re.MULTILINE)
    return found.group(1) if found else None


def ensure_pi(image: str) -> str | None:
    """The Pi version of the image. The default image must match the Dockerfile, so an image built before a bump of
    PI_VERSION stops the round; an image given with --image is only recorded."""
    with tempfile.TemporaryDirectory(prefix="agentica-pi-probe-") as directory:
        code, out, err = probe(image, ["pi", "--version"], Path(directory), 60)
    found = re.search(r"\d+\.\d+\.\d+\S*", out + err) if code == 0 else None
    version = found.group(0) if found else None
    wanted = dockerfile_pi_version()
    if image == DEFAULT_IMAGE and version != wanted:
        raise SystemExit(f"{image} has Pi {version or 'that does not run (' + err.strip() + ')'}, but tests/eval/Dockerfile "
                         f"pins {wanted}. Remove the stale image (docker rmi {image}) and rerun to rebuild it.")
    return version


def validate_docker(image: str, typed: bool = False, agentica: bool = False,
                    pi: bool = False) -> dict[str, str | None]:
    require_docker()
    if not image_exists(image):
        if image != DEFAULT_IMAGE:
            raise SystemExit(f"Docker image not found: {image}")
        build_image(image)
    problem = python_runs(image)
    if problem is not None:
        raise SystemExit(f"Docker preflight failed: {problem}")
    checker = ensure_checker(image) if typed else None
    if agentica:
        ensure_runtime(image)
    return {"checker": checker, "image_id": image_id(image), "pi": ensure_pi(image) if pi else None}


def child_environment(pass_env: list[str], *, in_chroot: bool, workspace: Path) -> dict[str, str]:
    env = dict(SAFE_ENV)
    env["HOME"] = "/home/agent" if in_chroot else str(workspace.parent / "home" / "agent")
    env["PATH"] = ROOTFS_PATH if in_chroot else f"{workspace / 'bin'}:{os.environ['PATH']}"
    for name in pass_env:
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
            raise SystemExit(f"invalid environment variable name: {name}")
        if name in {"HOME", "PATH", *SAFE_ENV}:
            raise SystemExit(f"cannot pass reserved environment variable: {name}")
        if name not in os.environ:
            raise SystemExit(f"environment variable is not set: {name}")
        env[name] = os.environ[name]
    return env


def redact_secrets(output: str, pass_env: list[str]) -> str:
    for name in pass_env:
        value = os.environ[name]
        if value:
            output = output.replace(value, "[REDACTED]")
    return output


def grader_environment() -> dict[str, str]:
    return dict(SAFE_ENV, HOME="/home/agent", PATH=ROOTFS_PATH)


def rootfs_has_executable(rootfs: Path, name: str) -> bool:
    for directory in SYSTEM_PATH.split(":"):
        candidate = rootfs / directory.lstrip("/") / name
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return True
    return False


def validate_sandbox(rootfs: Path, agent: str, typed: bool = False) -> None:
    if not rootfs.is_dir():
        raise SystemExit(f"chroot root filesystem not found: {rootfs}")
    if not shutil.which("firejail"):
        raise SystemExit("firejail not found; it is required to isolate grading")
    version = subprocess.run(["firejail", "--version"], capture_output=True, text=True, check=True).stdout
    if "chroot support is enabled" not in version:
        raise SystemExit("installed firejail does not support --chroot")
    if "networking support is enabled" not in version:
        raise SystemExit("installed firejail does not support network namespaces")
    if agent != "reference" and not rootfs_has_executable(rootfs, agent):
        raise SystemExit(f"{agent} executable not found in chroot system PATH ({SYSTEM_PATH})")
    if not rootfs_has_executable(rootfs, "python3"):
        raise SystemExit(f"python3 executable not found in chroot system PATH ({SYSTEM_PATH})")
    if typed and not rootfs_has_executable(rootfs, CHECKER[0]):
        raise SystemExit(f"{CHECKER[0]} executable not found in chroot system PATH ({SYSTEM_PATH})")
    smoke = jail_prefix(rootfs, network=False) + ["python3", "-I", "-c", "pass"]
    try:
        result = subprocess.run(
            smoke,
            cwd=rootfs,
            env=dict(SAFE_ENV, HOME="/", PATH=ROOTFS_PATH),
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise SystemExit(f"Firejail chroot preflight failed: {exc}") from exc
    if result.returncode:
        details = result.stderr.strip() or result.stdout.strip()
        raise SystemExit(f"Firejail chroot preflight failed: {details}")


def copy_candidate(source: Path, destination: Path) -> bool:
    if source.is_symlink() or not source.is_file():
        return False
    shutil.copyfile(source, destination)
    return True


def run_agent(
    agent: str,
    work: Path,
    rootfs: Path,
    task: str,
    arm: str,
    model: str | None,
    timeout: int,
    sandbox: str,
    pass_env: list[str],
    image: str,
) -> tuple[str, str, bool]:
    ext = ARMS[arm]
    if agent == "reference":
        shutil.copy(TASKS / task / f"reference.{ext}", work / f"solution.{ext}")
        return "", "", False
    env = child_environment(pass_env, in_chroot=True, workspace=work)
    command = agent_command(agent, work, arm, model, in_chroot=True)
    container = f"agentica-agent-{uuid.uuid4().hex}"
    if sandbox == "docker":
        command = docker_prefix(work, image, container, network=AGENT_NETWORK, pass_env=pass_env) + command
    else:
        command = jail_prefix(rootfs, network=AGENT_NETWORK) + command
    proc = subprocess.Popen(command, cwd=work, env=env, text=True,
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            start_new_session=True)
    try:
        out, err = proc.communicate(timeout=timeout)
        return redact_secrets(out, pass_env), redact_secrets(err, pass_env), False
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        out, err = proc.communicate()
        return redact_secrets(out or "", pass_env), redact_secrets(err or "", pass_env), True
    finally:
        if sandbox == "docker":
            remove_container(container)


def command_parts(command: str, *, split_pipes: bool = True) -> list[str]:
    """Split a shell line into its commands. With split_pipes=False a pipeline stays whole, so a `| head` filter
    is not read as a command of its own."""
    parts: list[str] = []
    current: list[str] = []
    quote = ""
    index = 0
    while index < len(command):
        char = command[index]
        if quote:
            if char == "\\" and quote == '"' and index + 1 < len(command):
                current.append(command[index:index + 2])
                index += 2
                continue
            if char == quote:
                quote = ""
            current.append(char)
        elif char in "'\"":
            quote = char
            current.append(char)
        elif command.startswith(("&&", "||"), index):
            parts.append("".join(current))
            current = []
            index += 2
            continue
        elif char == "|" and not split_pipes:
            current.append(char)
        elif char in ";|\n":
            parts.append("".join(current))
            current = []
        else:
            current.append(char)
        index += 1
    parts.append("".join(current))
    return parts


def is_check_command(command: str) -> bool:
    return any(CHECK_COMMAND.match(part) for part in command_parts(command))


def is_query_command(command: str) -> bool:
    return any(QUERY_COMMAND.match(part) for part in command_parts(command))


def is_read_command(command: str) -> bool:
    return any(READ_COMMAND.match(part) for part in command_parts(command, split_pipes=False))


def runs_mypy(command: str) -> bool:
    return any(MYPY_COMMAND.match(part) for part in command_parts(command))


def is_net_command(command: str) -> bool:
    return any(NET_STRONG.search(part) or (NET_WEAK.search(part) and not LOOPBACK.search(part))
               for part in command_parts(command))


def command_failed(command: str, text: str) -> bool:
    if "error[" in text or "Traceback" in text or "SyntaxError" in text:
        return True
    return runs_mypy(command) and ": error:" in text


def pi_metrics(out: str) -> dict[str, int | float]:
    """Counters from the `message_end` events of the assistant in Pi's JSON stream.

    `tokens_in` is the uncached input only, `tokens_cached` the cache reads: the context an agent read is
    `tokens_in + tokens_cached + tokens_cache_write`. The cost is split in the same way as the usage events do:
    `cost_input`, `cost_cache` (reads and writes) and `cost_output`."""
    m = {"tokens_in": 0, "tokens_out": 0, "tokens_cached": 0, "tokens_cache_write": 0, "cost": 0.0,
         "cost_input": 0.0, "cost_cache": 0.0, "cost_output": 0.0, "turns": 0,
         "interpreter_runs": 0, "failing_runs": 0, "check_runs": 0, "check_failures": 0,
         "outside_reads": 0, "net_commands": 0, "query_runs": 0, "read_runs": 0}
    pending: dict[str, str] = {}
    for line in out.splitlines():
        if not line.startswith("{"):
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        kind = event.get("type")
        if kind == "message_end" and event.get("message", {}).get("role") == "assistant":
            usage = event["message"].get("usage", {})
            m["turns"] += 1
            m["tokens_in"] += usage.get("input", 0)
            m["tokens_out"] += usage.get("output", 0)
            m["tokens_cached"] += usage.get("cacheRead", 0)
            usage_cost = usage.get("cost", {})
            m["tokens_cache_write"] += usage.get("cacheWrite", 0)
            m["cost"] += usage_cost.get("total", 0.0)
            m["cost_input"] += usage_cost.get("input", 0.0)
            m["cost_cache"] += usage_cost.get("cacheRead", 0.0) + usage_cost.get("cacheWrite", 0.0)
            m["cost_output"] += usage_cost.get("output", 0.0)
        elif kind == "tool_execution_start":
            args = json.dumps(event.get("args", {}))
            if str(ROOT) in args:
                m["outside_reads"] += 1
            command = event.get("args", {}).get("command", "")
            if is_net_command(command):
                m["net_commands"] += 1
            if event.get("toolName") == "bash":
                m["query_runs"] += is_query_command(command)
                m["read_runs"] += is_read_command(command)
            elif event.get("toolName") == "read":
                m["read_runs"] += 1
            if event.get("toolName") == "bash" and ("agentica" in command or "python" in command or runs_mypy(command)):
                m["interpreter_runs"] += 1
                if is_check_command(command):
                    m["check_runs"] += 1
                pending[event["toolCallId"]] = command
        elif kind == "tool_execution_end" and event.get("toolCallId") in pending:
            command = pending.pop(event["toolCallId"])
            if command_failed(command, json.dumps(event.get("result", {}))):
                m["failing_runs"] += 1
                if is_check_command(command):
                    m["check_failures"] += 1
    return m


def claude_metrics(out: str) -> dict[str, int | float]:
    try:
        data = json.loads(out)
    except json.JSONDecodeError:
        return {}
    usage = data.get("usage", {})
    return {"tokens_in": usage.get("input_tokens", 0), "tokens_out": usage.get("output_tokens", 0),
            "tokens_cached": usage.get("cache_read_input_tokens", 0),
            "tokens_cache_write": usage.get("cache_creation_input_tokens", 0), "cost": data.get("total_cost_usd", 0.0),
            "turns": data.get("num_turns", 0), "check_runs": 0, "check_failures": 0,
            "query_runs": 0, "read_runs": 0}


def hidden_driver(task: str) -> str | None:
    driver = TASKS / task / "hidden" / "driver.py"
    return driver.read_text(encoding="utf-8") if driver.is_file() else None


def case_timeout(task: str) -> int:
    limit = TASKS / task / "hidden" / "timeout"
    return int(limit.read_text(encoding="utf-8").strip()) if limit.is_file() else CASE_TIMEOUT


def case_invocation(ext: str, driver: str | None, case: str) -> tuple[list[str], str]:
    if ext == "agc":
        command = ["/workspace/bin/agentica", "solution.agc"]
    else:
        command = ["python3", "-I", "solution.py"]
    if driver is None:
        return command, case
    return ["python3", "-I", "-", case, command[0], *command[1:-1], f"/workspace/{command[-1]}"], driver


def contained_run(args: argparse.Namespace, grade_root: Path, work: Path, command: list[str],
                  stdin: str, timeout: int) -> tuple[str | None, str, int | None]:
    container = f"agentica-grade-{uuid.uuid4().hex}"
    try:
        prefix = (docker_prefix(work, args.image, container, network=False, pass_env=[])
                  if args.sandbox == "docker" else jail_prefix(grade_root, network=False))
        done = subprocess.run(prefix + command, cwd=work, env=grader_environment(), input=stdin,
                              capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout)
        return done.stdout, done.stderr, done.returncode
    except subprocess.TimeoutExpired:
        return None, "timeout", None
    finally:
        if args.sandbox == "docker":
            remove_container(container)


def classify_check(output: str) -> tuple[str, str]:
    found = re.search(r"^.*: error: .*?(?:\s+\[([a-z0-9-]+)\])?$", output, re.MULTILINE)
    code = found.group(1) if found and found.group(1) else "mypy"
    if code == "syntax":
        return "syntax", "SyntaxError"
    return "check", code


Contained = Callable[[list[str], str, int], tuple[str | None, str, int | None]]


def type_escapes(text: str) -> dict[str, int]:
    return {"type_ignores": len(TYPE_SILENCE.findall(text)), "type_escapes": len(TYPE_ESCAPE.findall(text))}


def type_check(contained: Contained, total: int) -> dict | None:
    out, err, returncode = contained(CHECKER + ["solution.py"], "", CHECK_TIMEOUT)
    if returncode == 0:
        return None
    if out is None:
        return {"status": "fail", "passed": 0, "total": total, "failure": "check-timeout", "code": None, "check_errors": 0}
    kind, code = classify_check(out + err)
    return {"status": "fail", "passed": 0, "total": total, "failure": kind, "code": code,
            "check_errors": len(re.findall(r": error: ", out))}


def grade(solution: Path, task: str, arm: str, args: argparse.Namespace, scratch: Path, name: str) -> dict:
    ext = ARMS[arm]
    cases = sorted((TASKS / task / "hidden").glob("*.in"))
    if solution.is_symlink() or not solution.is_file():
        return {"status": "no-file", "passed": 0, "total": len(cases), "failure": None, "code": None}
    grade_root = (clone_rootfs(args.chroot_root, scratch / f"{name}-grader-root")
                  if args.sandbox == "firejail" else scratch / f"{name}-grader-root")
    work = grade_root / WORKSPACE.relative_to("/")
    work.mkdir(parents=True)
    shutil.copyfile(solution, work / solution.name)
    if ext == "agc":
        shutil.copytree(ROOT / "dist" / "runtime", work, dirs_exist_ok=True)

    def contained(command: list[str], stdin: str, timeout: int) -> tuple[str | None, str, int | None]:
        return contained_run(args, grade_root, work, command, stdin, timeout)

    extra: dict[str, int] = {}
    if arm in TYPED_ARMS:
        extra = type_escapes(solution.read_text(encoding="utf-8", errors="replace"))
        if extra["type_ignores"]:
            return {"status": "fail", "passed": 0, "total": len(cases), "failure": "check", "code": "ignore",
                    "check_errors": 0, **extra}
        found = type_check(contained, len(cases))
        if found is not None:
            return {**found, **extra}
        extra["check_errors"] = 0
    driver = hidden_driver(task)
    timeout = case_timeout(task)
    passed, failure, code = 0, None, None
    for case in cases:
        expected = case.with_suffix(".out").read_text(encoding="utf-8").rstrip("\n")
        command, stdin = case_invocation(ext, driver, case.read_bytes().decode("utf-8"))
        out, err, returncode = contained(command, stdin, timeout)
        actual = None if out is None else out.rstrip("\n")
        if actual == expected and returncode == 0:
            passed += 1
            continue
        if failure is None:
            failure, code = classify(err, ext)
    return {"status": "pass" if passed == len(cases) else "fail", "passed": passed, "total": len(cases),
            "failure": failure, "code": code, **extra}


def classify(err: str, ext: str) -> tuple[str, str | None]:
    if err == "timeout":
        return "timeout", None
    if ext == "agc":
        for stage, kind in (("LEX-", "syntax"), ("PARSE-", "syntax"), ("CHECK-", "check"), ("RUNTIME-", "runtime")):
            if f"error[{stage}" in err:
                start = err.index(f"error[{stage}") + 6
                return kind, err[start:err.index("]", start)]
        return "logic", None
    if "SyntaxError" in err:
        return "syntax", "SyntaxError"
    if "Traceback" in err:
        return "runtime", err.strip().splitlines()[-1].split(":")[0]
    return "logic", None


def one_run(args: argparse.Namespace, results: Path, scratch: Path, task: str, arm: str, rep: int) -> dict:
    name = f"{task}-{arm}-{rep}"
    agent_root = (clone_rootfs(args.chroot_root, scratch / f"{name}-agent-root")
                  if args.sandbox == "firejail" else scratch / f"{name}-agent-root")
    work = agent_root / WORKSPACE.relative_to("/")
    prepare(work, task, arm)
    (agent_root / "home" / "agent").mkdir(parents=True, exist_ok=True)
    began = time.time()
    out, err, timed_out = run_agent(
        args.agent, work, agent_root, task, arm, args.model, args.timeout, args.sandbox, args.pass_env, args.image
    )
    seconds = round(time.time() - began, 1)
    row = {"task": task, "arm": arm, "rep": rep, "agent": args.agent, "model": args.model or "default",
           "seconds": seconds, "agent_timeout": timed_out, "sandbox": args.sandbox, "image": args.image}
    if args.agent == "pi":
        row.update(pi_metrics(out))
    elif args.agent == "claude":
        row.update(claude_metrics(out))
    row["refused_queries"] = refused_queries(work)
    solution = work / f"solution.{ARMS[arm]}"
    row.update(grade(solution, task, arm, args, scratch, name))
    run_dir = results / name
    run_dir.mkdir(parents=True)
    (run_dir / "agent.jsonl").write_text(out, encoding="utf-8")
    (run_dir / "agent.stderr").write_text(err, encoding="utf-8")
    copy_candidate(solution, run_dir / solution.name)
    with WRITE_LOCK:
        with (results / "results.jsonl").open("a") as handle:
            handle.write(json.dumps(row) + "\n")
        print(f"{name}: {row['status']} {row['passed']}/{row['total']} {seconds}s", flush=True)
    return row


class Budget:
    """The `--max-cost` cap, a soft one. A run starts only when the cost so far, plus the estimate for this run and
    for every run in flight, stays under the cap; the first refusal is final, so the round stops starting runs and
    the ones in flight finish. Those runs, and a run dearer than the estimate, can still pass the cap: by up to
    `--jobs` times the costliest run.

    The estimate is the highest cost seen so far (which is never below the mean), and never below `floor`. A run
    that reports no cost (no usage at all, or a cost of 0: a timeout, a 429, an auth error) says nothing about what
    a run costs, so it is charged the estimate and kept out of that figure."""

    def __init__(self, cap: float | None, floor: float) -> None:
        self.cap, self.floor = cap, floor
        self.spent, self.finished, self.in_flight, self.skipped = 0.0, 0, 0, 0
        self.highest = 0.0
        self.stopped = False
        self.lock = threading.Lock()

    def estimate(self) -> float:
        return max(self.floor, self.highest)

    def begin(self) -> bool:
        with self.lock:
            if self.cap is not None and (self.stopped or self.spent + self.estimate() * (self.in_flight + 1) > self.cap):
                self.stopped = True
                self.skipped += 1
                return False
            self.in_flight += 1
            return True

    def end(self, cost: float | None) -> tuple[float, bool]:
        """Add the cost of a finished run. Returns the total and whether the run was charged the estimate because it
        reported no usable cost (None or not above 0)."""
        with self.lock:
            unknown = cost is None or cost <= 0
            charged = self.estimate() if unknown else cost
            if not unknown:
                self.highest = max(self.highest, charged)
            self.in_flight -= 1
            self.finished += 1
            self.spent += charged
            return self.spent, unknown


def budgeted_run(args: argparse.Namespace, budget: Budget, results: Path, scratch: Path,
                 task: str, arm: str, rep: int) -> None:
    if not budget.begin():
        return
    cost = None
    try:
        cost = one_run(args, results, scratch, task, arm, rep).get("cost")
    finally:
        total, unknown = budget.end(cost)
        if unknown and budget.cap is not None:
            print(f"warning: {task}-{arm}-{rep} reported no cost; charged the estimate "
                  f"${budget.estimate():.4f}", flush=True)
        cap = f" of the ${budget.cap:.2f} cap" if budget.cap is not None else ""
        print(f"cost so far: ${total:.4f}{cap}", flush=True)


def read_rows(results: Path) -> list[dict]:
    return [json.loads(line) for line in (results / "results.jsonl").read_text(encoding="utf-8").splitlines()]


def git_output(*command: str) -> str:
    try:
        return subprocess.run(["git", *command], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return ""


def run_info(args: argparse.Namespace, image_info: dict[str, str | None]) -> dict:
    return {"commit": git_output("rev-parse", "HEAD"), "dirty": bool(git_output("status", "--porcelain")),
            "skill_commit": git_output("log", "-1", "--format=%H", "--", ".agents/skills/agentica-programming"),
            "agent": args.agent, "model": args.model or "default", "arms": args.arms, "tasks": args.tasks,
            "reps": args.reps, "timeout": args.timeout, "sandbox": args.sandbox, "image": args.image,
            "image_id": image_info["image_id"], "checker": image_info["checker"], "pi_version": image_info.get("pi"), "pass_env": args.pass_env,
            "agent_network": AGENT_NETWORK and args.agent != "reference", "arm_tasks": args.arm_tasks,
            "max_cost": args.max_cost,
            "arm_notes": {arm: NOCLI_NOTE for arm in args.arms if arm == "skill-nocli"}}


def mean_known(rows: list[dict], keys: tuple[str, ...], places: int) -> str:
    """The mean over `rows` of the sum of `keys`, or `-` when any row lacks a key: results files from before a
    field existed have no value for it, which is unknown, not 0."""
    if any(key not in row for row in rows for key in keys):
        return "-"
    total = sum(row[key] for row in rows for key in keys) / len(rows)
    return f"{total:.{places}f}"


def summarize(results: Path) -> None:
    rows = read_rows(results)
    info_file = results / "run.json"
    info = json.loads(info_file.read_text(encoding="utf-8")) if info_file.is_file() else {}
    groups = {}
    for row in rows:
        groups.setdefault((row["task"], row["arm"]), []).append(row)
    out = ["| task | arm | runs | pass | cases | tokens | context | cost in $ | cost cache $ | cost out $ | seconds | failing runs | check runs | query runs | refused | read runs | type escapes | failures |",
           "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for (task, arm), rs in sorted(groups.items()):
        n = len(rs)
        mean = lambda key: round(sum(r.get(key, 0) for r in rs) / n, 1)
        tokens = round(sum(r.get("tokens_in", 0) + r.get("tokens_out", 0) for r in rs) / n)
        # The context is what the agent read: uncached input, cache reads and cache writes. Older rows have no
        # `tokens_cache_write`; it counts only when present.
        context = "-" if any("tokens_in" not in r or "tokens_cached" not in r for r in rs) else str(round(
            sum(r["tokens_in"] + r["tokens_cached"] + r.get("tokens_cache_write", 0) for r in rs) / n))
        passes = sum(r["status"] == "pass" for r in rs)
        cases = round(sum(r["passed"] / r["total"] for r in rs) / n * 100)
        kinds = ", ".join(sorted({f"{r['failure']}:{r['code']}" if r["code"] else str(r["failure"]) for r in rs if r["failure"]})) or "-"
        out.append(f"| {task} | {arm} | {n} | {passes}/{n} | {cases}% | {tokens} | {context} | {mean_known(rs, ('cost_input',), 4)} | {mean_known(rs, ('cost_cache',), 4)} | {mean_known(rs, ('cost_output',), 4)} | {mean('seconds')} | {mean('failing_runs')} | {mean('check_runs')} | {mean('query_runs')} | {mean('refused_queries')} | {mean('read_runs')} | {mean('type_escapes')} | {kinds} |")
    if info.get("cost") is not None:
        out += ["", f"cost: ${info['cost']:.4f}" + (f" (cap ${info['max_cost']:.2f})" if info.get("max_cost") is not None else "")]
    out += ["", f"stopped_for_budget: {str(bool(info.get('stopped_for_budget'))).lower()}"
            + (f" ({info['runs_skipped']} runs not started)" if info.get("stopped_for_budget") else "")]
    if info.get("stopped_for_budget"):
        out += reps_completed(rows, info)
    text = "\n".join(out) + "\n"
    (results / "summary.md").write_text(text, encoding="utf-8")
    print(text)


def run_order(tasks: list[str], arms: list[str], arm_tasks: dict[str, list[str]], reps: int) -> list[tuple[str, str, int]]:
    """The queue: rep by rep, and inside a rep task by task, then arm by arm. A budget stop then
    leaves every (task, arm) with the same number of reps, give or take one, instead of dropping a whole task or
    arm block. With --jobs above 1 the pool starts the runs in this order."""
    pairs = [(task, arm) for task in tasks for arm in arms if task in arm_tasks.get(arm, tasks)]
    return [(task, arm, rep) for rep in range(1, reps + 1) for task, arm in pairs]


def reps_completed(rows: list[dict], info: dict) -> list[str]:
    """Lines saying how many reps each (task, arm) of the round finished, grouped by that count, most reps first.
    Needs the planned grid in run.json; older files without it give no lines."""
    if not all(key in info for key in ("tasks", "arms", "reps")):
        return []
    done: dict[tuple[str, str], int] = {}
    for row in rows:
        done[(row["task"], row["arm"])] = done.get((row["task"], row["arm"]), 0) + 1
    planned = [(task, arm) for task, arm, _ in run_order(info["tasks"], info["arms"], info.get("arm_tasks") or {}, 1)]
    by_count: dict[int, list[str]] = {}
    for task, arm in planned:
        by_count.setdefault(done.get((task, arm), 0), []).append(f"{task}/{arm}")
    return [f"reps completed (of {info['reps']}): {count}: " + ", ".join(names)
            for count, names in sorted(by_count.items(), reverse=True)]


def parse_arm_tasks(specs: list[str], arms: list[str], tasks: list[str]) -> dict[str, list[str]]:
    """`ARM=TASK,TASK` options to {arm: [task, ...]}; an unknown arm, or a task outside --tasks, stops the run."""
    chosen: dict[str, list[str]] = {}
    for spec in specs:
        arm, _, names = spec.partition("=")
        if arm not in arms or not names:
            raise SystemExit(f"--arm-tasks {spec!r}: expected ARM=TASK,TASK with an ARM in --arms ({' '.join(arms)})")
        listed = names.split(",")
        unknown = [name for name in listed if name not in tasks]
        if unknown:
            raise SystemExit(f"--arm-tasks {spec!r}: not in --tasks (use full task names): {' '.join(unknown)}")
        chosen[arm] = listed
    return chosen


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--agent", choices=["pi", "claude", "reference"], default="pi")
    parser.add_argument("--model")
    parser.add_argument("--tasks", nargs="*", default=sorted(p.name for p in TASKS.iterdir() if p.is_dir()))
    parser.add_argument("--arms", nargs="*", help=f"default: {' '.join(DEFAULT_ARMS)}; opt-in: {' '.join(sorted(OPT_IN_ARMS))}")
    parser.add_argument("--arm-tasks", action="append", default=[], metavar="ARM=TASK,TASK",
                        help="run ARM only on these tasks (full names, all in --tasks); repeat for several arms")
    parser.add_argument("--max-cost", type=float, metavar="USD",
                        help="soft cap: stop starting new runs when the cost so far plus the estimate of the runs "
                             "in flight and of the next one would pass USD. Runs already going and outlier runs "
                             "can go past it by up to --jobs x the costliest run (default: no cap)")
    parser.add_argument("--run-cost-estimate", type=float, default=0.01, metavar="USD",
                        help="lowest estimate of one run for --max-cost; the highest cost seen so far replaces it "
                             "when higher (default: %(default)s)")
    parser.add_argument("--reps", type=int, default=1)
    parser.add_argument("--timeout", type=int, default=600)
    parser.add_argument("--jobs", type=int, default=1, help="runs in parallel")
    parser.add_argument("--no-build", action="store_true")
    parser.add_argument("--chroot-root", type=Path,
                        help="prepared minimal Firejail root filesystem; its glibc must run the host-built "
                             "dist/agentica (as new as the host's, or newer)")
    parser.add_argument("--pass-env", action="append", default=[], metavar="NAME",
                        help="pass one provider-auth environment variable to the agent; repeat as needed")
    parser.add_argument("--sandbox", choices=["docker", "firejail"], default="docker",
                        help="firejail runs the host-built agentica on the chroot's glibc")
    parser.add_argument("--image", default=DEFAULT_IMAGE, help="Docker image; the default is built when missing")
    parser.add_argument("--summarize", metavar="RESULTS_DIR")
    parser.add_argument("--check-references", action="store_true",
                        help="grade every reference solution (no model, no credentials) and exit 1 if one fails; "
                             f"arms default to {' '.join(REFERENCE_ARMS)}")
    args = parser.parse_args()
    if args.summarize:
        summarize(Path(args.summarize))
        return 0
    if args.check_references:
        args.agent = "reference"
        args.pass_env = []
    args.arms = args.arms or (REFERENCE_ARMS if args.check_references else DEFAULT_ARMS)
    args.arm_tasks = parse_arm_tasks(args.arm_tasks, args.arms, args.tasks)
    if args.max_cost is not None and args.max_cost <= 0:
        raise SystemExit("--max-cost must be more than 0")
    typed = any(arm in TYPED_ARMS for arm in args.arms)
    agentica = any(ARMS[arm] == "agc" for arm in args.arms)
    child_environment(args.pass_env, in_chroot=True, workspace=WORKSPACE)
    if args.sandbox == "docker":
        require_docker()
    else:
        if args.chroot_root is None:
            raise SystemExit("--sandbox firejail requires --chroot-root")
        args.chroot_root = args.chroot_root.resolve()
        validate_sandbox(args.chroot_root, args.agent, typed)
    if not args.no_build:
        build()
    if not (ROOT / "dist" / "runtime" / "bin" / "agentica").is_file():
        raise SystemExit("dist/runtime is missing; rerun without --no-build")
    image_info: dict[str, str | None] = {"checker": None, "image_id": None, "pi": None}
    if args.sandbox == "docker":
        image_info = validate_docker(args.image, typed, agentica, args.agent == "pi")
    stamp = time.strftime("%Y%m%d-%H%M%S")
    results = EVAL / "results" / f"{stamp}-{args.agent}"
    results.mkdir(parents=True)
    (results / "run.json").write_text(json.dumps(run_info(args, image_info), indent=2) + "\n", encoding="utf-8")
    jobs = run_order(args.tasks, args.arms, args.arm_tasks, args.reps)
    budget = Budget(args.max_cost, args.run_cost_estimate)
    with tempfile.TemporaryDirectory(prefix="agentica-eval-") as scratch_dir:
        scratch = Path(scratch_dir)
        with ThreadPoolExecutor(max_workers=args.jobs) as pool:
            for future in [pool.submit(budgeted_run, args, budget, results, scratch, *job) for job in jobs]:
                future.result()
    info = json.loads((results / "run.json").read_text(encoding="utf-8"))
    info.update(cost=round(budget.spent, 6), stopped_for_budget=budget.stopped, runs_skipped=budget.skipped)
    (results / "run.json").write_text(json.dumps(info, indent=2) + "\n", encoding="utf-8")
    summarize(results)
    print(f"results: {results}")
    failed = [row for row in read_rows(results) if row["status"] != "pass"]
    if args.agent == "reference" and failed:
        print("reference solutions that failed: " + ", ".join(f"{row['task']}/{row['arm']}" for row in failed))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
