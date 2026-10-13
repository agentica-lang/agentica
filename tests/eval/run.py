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
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EVAL = ROOT / "tests" / "eval"
TASKS = EVAL / "tasks"
SKILL = ROOT / ".agents" / "skills" / "agentica-programming"
ARMS = {"skill": "agc", "grammar": "agc", "binary": "agc", "python": "py"}
NET_WORDS = ("curl", "wget", "git clone", "github.com")
CASE_TIMEOUT = 10
WRITE_LOCK = threading.Lock()
WORKSPACE = Path("/workspace")
SYSTEM_PATH = "/usr/local/bin:/usr/bin:/bin"
ROOTFS_PATH = f"/workspace/bin:{SYSTEM_PATH}"
SAFE_ENV = {"LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "PYTHONUTF8": "1"}
DEFAULT_IMAGE = "agentica-eval:local"


def build() -> None:
    subprocess.run(["make", "exe"], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    runtime = ROOT / "dist" / "runtime"
    shutil.rmtree(runtime, ignore_errors=True)
    subprocess.run(["raco", "distribute", str(runtime), str(ROOT / "dist" / "agentica")], check=True)
    shutil.copy2(ROOT / "dist" / "agentica-vm", runtime / "bin" / "agentica-vm")


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


def prepare(work: Path, task: str, arm: str) -> None:
    ext = ARMS[arm]
    work.mkdir(parents=True, exist_ok=True)
    shutil.copy(TASKS / task / "task.md", work / "task.md")
    start = TASKS / task / f"start.{ext}"
    if start.exists():
        shutil.copy(start, work / start.name)
    shutil.copytree(ROOT / "dist" / "runtime", work, dirs_exist_ok=True)
    if arm == "skill":
        (work / "skills").mkdir()
        shutil.copytree(SKILL, work / "skills" / "agentica-programming")
    if arm == "grammar":
        (work / "docs").mkdir()
        parts = sorted((ROOT / "docs" / "grammar").glob("*.md"))
        (work / "docs" / "grammar.md").write_text("\n".join(part.read_text(encoding="utf-8") for part in parts), encoding="utf-8")
        shutil.copytree(ROOT / "examples", work / "examples")


def prompt(work: Path, arm: str) -> str:
    ext = ARMS[arm]
    lines = ["Read task.md in the current directory and do what it asks."]
    if (work / f"start.{ext}").exists():
        lines.append(f"The starting program is start.{ext}.")
    if ext == "agc":
        lines.append("Write a complete Agentica program to solution.agc. Run programs with the `agentica` command, which is on your PATH.")
        if arm == "skill":
            lines.append("Use the agentica-programming skill.")
        elif arm == "binary":
            lines.append("The language is Agentica: Ruby-like syntax, statically typed, programs start with `def main() -> Void`. "
                         "`agentica file.agc` runs a program and `agentica check file.agc` checks it without running. "
                         "`agentica --help` lists the options.")
        else:
            lines.append("The language is described in docs/grammar.md, and example programs are in examples/.")
    else:
        lines.append("Write a complete Python 3 program to solution.py. Run programs with `python3`.")
    lines.append("Work only inside the current directory. Test your program before you finish, then reply with one sentence.")
    return " ".join(lines)


def agent_command(agent: str, work: Path, arm: str, model: str | None, *, in_chroot: bool) -> list[str]:
    text = prompt(work, arm)
    workspace = WORKSPACE if in_chroot else work
    if agent == "pi":
        cmd = ["pi", "-p", "--mode", "json", "--no-session", "--no-context-files", "--no-extensions"]
        cmd += ["--skill", str(workspace / "skills" / "agentica-programming")] if arm == "skill" else ["--no-skills"]
        if model:
            cmd += ["--model", model]
        return cmd + [text]
    if agent == "claude":
        cmd = ["claude", "-p", "--output-format", "json", "--no-session-persistence", "--dangerously-skip-permissions", "--strict-mcp-config"]
        if arm != "skill":
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


def validate_docker(image: str) -> None:
    if not shutil.which("docker"):
        raise SystemExit("docker is required for evaluation; alternatively select --sandbox firejail")
    found = subprocess.run(["docker", "image", "inspect", image], capture_output=True)
    if found.returncode:
        if image != DEFAULT_IMAGE:
            raise SystemExit(f"Docker image not found: {image}")
        subprocess.run(["docker", "build", "--tag", image, "--file", str(EVAL / "Dockerfile"), str(EVAL)], check=True)
    with tempfile.TemporaryDirectory(prefix="agentica-docker-probe-") as directory:
        name = f"agentica-probe-{uuid.uuid4().hex}"
        command = docker_prefix(Path(directory), image, name, network=False, pass_env=[])
        try:
            subprocess.run(command + ["python3", "-I", "-c", "pass"],
                           env=grader_environment(), capture_output=True, text=True, timeout=30, check=True)
        except subprocess.CalledProcessError as exc:
            raise SystemExit(f"Docker preflight failed: {exc.stderr}") from exc
        finally:
            remove_container(name)


def child_environment(pass_env: list[str], *, in_chroot: bool, workspace: Path) -> dict[str, str]:
    env = dict(SAFE_ENV)
    env["HOME"] = "/home/agent" if in_chroot else str(workspace.parent / "home" / "agent")
    env["PATH"] = ROOTFS_PATH if in_chroot else f"{workspace / 'bin'}:{os.environ['PATH']}"
    for name in pass_env:
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
            raise SystemExit(f"invalid environment variable name: {name}")
        if name in {"HOME", "PATH", "LANG", "LC_ALL", "PYTHONUTF8"}:
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


def validate_sandbox(rootfs: Path, agent: str) -> None:
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
        command = docker_prefix(work, image, container, network=True, pass_env=pass_env) + command
    else:
        command = jail_prefix(rootfs, network=True) + command
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


def pi_metrics(out: str) -> dict[str, int | float]:
    m = {"tokens_in": 0, "tokens_out": 0, "tokens_cached": 0, "cost": 0.0, "turns": 0,
         "interpreter_runs": 0, "failing_runs": 0, "outside_reads": 0, "net_commands": 0}
    pending = {}
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
            m["cost"] += usage.get("cost", {}).get("total", 0.0)
        elif kind == "tool_execution_start":
            args = json.dumps(event.get("args", {}))
            if str(ROOT) in args:
                m["outside_reads"] += 1
            command = event.get("args", {}).get("command", "")
            if any(word in command for word in NET_WORDS):
                m["net_commands"] += 1
            if event.get("toolName") == "bash" and ("agentica" in command or "python" in command):
                m["interpreter_runs"] += 1
                pending[event["toolCallId"]] = True
        elif kind == "tool_execution_end" and pending.pop(event.get("toolCallId"), False):
            text = json.dumps(event.get("result", {}))
            if "error[" in text or "Traceback" in text or "SyntaxError" in text:
                m["failing_runs"] += 1
    return m


def claude_metrics(out: str) -> dict[str, int | float]:
    try:
        data = json.loads(out)
    except json.JSONDecodeError:
        return {}
    usage = data.get("usage", {})
    return {"tokens_in": usage.get("input_tokens", 0), "tokens_out": usage.get("output_tokens", 0),
            "tokens_cached": usage.get("cache_read_input_tokens", 0), "cost": data.get("total_cost_usd", 0.0),
            "turns": data.get("num_turns", 0)}


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
        cmd = ["/workspace/bin/agentica", "solution.agc"]
    else:
        cmd = ["python3", "-I", "solution.py"]
    env = grader_environment()
    passed, failure, code = 0, None, None
    for case in cases:
        container = f"agentica-grade-{uuid.uuid4().hex}"
        expected = case.with_suffix(".out").read_text(encoding="utf-8").rstrip("\n")
        try:
            jailed = (docker_prefix(work, args.image, container, network=False, pass_env=[])
                      if args.sandbox == "docker" else jail_prefix(grade_root, network=False)) + cmd
            done = subprocess.run(jailed, cwd=work, env=env, input=case.read_text(encoding="utf-8"), capture_output=True, text=True, timeout=CASE_TIMEOUT)
            actual, err, returncode = done.stdout.rstrip("\n"), done.stderr, done.returncode
        except subprocess.TimeoutExpired:
            actual, err, returncode = None, "timeout", None
        finally:
            if args.sandbox == "docker":
                remove_container(container)
        if actual == expected and returncode == 0:
            passed += 1
            continue
        if failure is None:
            failure, code = classify(err, ext)
    return {"status": "pass" if passed == len(cases) else "fail", "passed": passed, "total": len(cases),
            "failure": failure, "code": code}


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


def one_run(args: argparse.Namespace, results: Path, scratch: Path, task: str, arm: str, rep: int) -> None:
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


def summarize(results: Path) -> None:
    rows = [json.loads(line) for line in (results / "results.jsonl").read_text(encoding="utf-8").splitlines()]
    groups = {}
    for row in rows:
        groups.setdefault((row["task"], row["arm"]), []).append(row)
    out = ["| task | arm | runs | pass | cases | tokens | seconds | failing runs | failures |", "|---|---|---|---|---|---|---|---|---|"]
    for (task, arm), rs in sorted(groups.items()):
        n = len(rs)
        mean = lambda key: round(sum(r.get(key, 0) for r in rs) / n, 1)
        tokens = round(sum(r.get("tokens_in", 0) + r.get("tokens_out", 0) for r in rs) / n)
        passes = sum(r["status"] == "pass" for r in rs)
        cases = round(sum(r["passed"] / r["total"] for r in rs) / n * 100)
        kinds = ", ".join(sorted({f"{r['failure']}:{r['code']}" if r["code"] else str(r["failure"]) for r in rs if r["failure"]})) or "-"
        out.append(f"| {task} | {arm} | {n} | {passes}/{n} | {cases}% | {tokens} | {mean('seconds')} | {mean('failing_runs')} | {kinds} |")
    text = "\n".join(out) + "\n"
    (results / "summary.md").write_text(text, encoding="utf-8")
    print(text)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--agent", choices=["pi", "claude", "reference"], default="pi")
    parser.add_argument("--model")
    parser.add_argument("--tasks", nargs="*", default=sorted(p.name for p in TASKS.iterdir() if p.is_dir()))
    parser.add_argument("--arms", nargs="*", default=list(ARMS))
    parser.add_argument("--reps", type=int, default=1)
    parser.add_argument("--timeout", type=int, default=600)
    parser.add_argument("--jobs", type=int, default=1, help="runs in parallel")
    parser.add_argument("--no-build", action="store_true")
    parser.add_argument("--chroot-root", type=Path,
                        help="prepared minimal Firejail root filesystem; its glibc must run the host-built "
                             "dist/agentica-vm (as new as the host's, or newer)")
    parser.add_argument("--pass-env", action="append", default=[], metavar="NAME",
                        help="pass one provider-auth environment variable to the agent; repeat as needed")
    parser.add_argument("--sandbox", choices=["docker", "firejail"], default="docker",
                        help="firejail runs the host-built agentica-vm on the chroot's glibc")
    parser.add_argument("--image", default=DEFAULT_IMAGE, help="Docker image; the default is built when missing")
    parser.add_argument("--summarize", metavar="RESULTS_DIR")
    args = parser.parse_args()
    if args.summarize:
        summarize(Path(args.summarize))
        return
    child_environment(args.pass_env, in_chroot=True, workspace=WORKSPACE)
    if args.sandbox == "docker":
        validate_docker(args.image)
    else:
        if args.chroot_root is None:
            raise SystemExit("--sandbox firejail requires --chroot-root")
        args.chroot_root = args.chroot_root.resolve()
        validate_sandbox(args.chroot_root, args.agent)
    if not args.no_build:
        build()
    if not all((ROOT / "dist" / "runtime" / "bin" / name).is_file() for name in ("agentica", "agentica-vm")):
        raise SystemExit("dist/runtime is missing; rerun without --no-build")
    stamp = time.strftime("%Y%m%d-%H%M%S")
    results = EVAL / "results" / f"{stamp}-{args.agent}"
    results.mkdir(parents=True)
    jobs = [(task, arm, rep) for task in args.tasks for arm in args.arms for rep in range(1, args.reps + 1)]
    with tempfile.TemporaryDirectory(prefix="agentica-eval-") as scratch_dir:
        scratch = Path(scratch_dir)
        with ThreadPoolExecutor(max_workers=args.jobs) as pool:
            for future in [pool.submit(one_run, args, results, scratch, *job) for job in jobs]:
                future.result()
    summarize(results)
    print(f"results: {results}")


if __name__ == "__main__":
    sys.exit(main())
