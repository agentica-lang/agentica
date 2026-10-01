#!/usr/bin/env python3
import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EVAL = ROOT / "tests" / "eval"
TASKS = EVAL / "tasks"
SKILL = ROOT / ".agents" / "skills" / "agentica-programming"
ARMS = {"skill": "agc", "grammar": "agc", "python": "py"}
CASE_TIMEOUT = 10


def build():
    subprocess.run(["make", "exe"], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)


def prepare(work, task, arm):
    ext = ARMS[arm]
    work.mkdir(parents=True)
    shutil.copy(TASKS / task / "task.md", work / "task.md")
    start = TASKS / task / f"start.{ext}"
    if start.exists():
        shutil.copy(start, work / start.name)
    (work / "bin").mkdir()
    shutil.copy(ROOT / "dist" / "agentica", work / "bin" / "agentica")
    if arm == "skill":
        shutil.copytree(SKILL, work / "skills" / "agentica-programming")
    if arm == "grammar":
        (work / "docs").mkdir()
        shutil.copy(ROOT / "docs" / "grammar.md", work / "docs" / "grammar.md")
        shutil.copytree(ROOT / "examples", work / "examples")


def prompt(work, arm):
    ext = ARMS[arm]
    lines = ["Read task.md in the current directory and do what it asks."]
    if (work / f"start.{ext}").exists():
        lines.append(f"The starting program is start.{ext}.")
    if ext == "agc":
        lines.append("Write a complete Agentica program to solution.agc. Run programs with the `agentica` command, which is on your PATH.")
        if arm == "skill":
            lines.append("Use the agentica-programming skill.")
        else:
            lines.append("The language is described in docs/grammar.md, and example programs are in examples/.")
    else:
        lines.append("Write a complete Python 3 program to solution.py. Run programs with `python3`.")
    lines.append("Work only inside the current directory. Test your program before you finish, then reply with one sentence.")
    return " ".join(lines)


def agent_command(agent, work, arm, model):
    text = prompt(work, arm)
    if agent == "pi":
        cmd = ["pi", "-p", "--mode", "json", "--no-session", "--no-context-files", "--no-extensions"]
        cmd += ["--skill", str(work / "skills" / "agentica-programming")] if arm == "skill" else ["--no-skills"]
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


def run_agent(agent, work, task, arm, model, timeout):
    ext = ARMS[arm]
    if agent == "reference":
        shutil.copy(TASKS / task / f"reference.{ext}", work / f"solution.{ext}")
        return "", False
    env = dict(os.environ, PATH=f"{work / 'bin'}:{os.environ['PATH']}")
    proc = subprocess.Popen(agent_command(agent, work, arm, model), cwd=work, env=env, text=True,
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            start_new_session=True)
    try:
        out, _ = proc.communicate(timeout=timeout)
        return out, False
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        out, _ = proc.communicate()
        return out or "", True


def pi_metrics(out):
    m = {"tokens_in": 0, "tokens_out": 0, "tokens_cached": 0, "cost": 0.0, "turns": 0,
         "interpreter_runs": 0, "failing_runs": 0, "outside_reads": 0}
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
            if event.get("toolName") == "bash" and ("agentica" in command or "python" in command):
                m["interpreter_runs"] += 1
                pending[event["toolCallId"]] = True
        elif kind == "tool_execution_end" and pending.pop(event.get("toolCallId"), False):
            text = json.dumps(event.get("result", {}))
            if "error[" in text or "Traceback" in text or "SyntaxError" in text:
                m["failing_runs"] += 1
    return m


def claude_metrics(out):
    try:
        data = json.loads(out)
    except json.JSONDecodeError:
        return {}
    usage = data.get("usage", {})
    return {"tokens_in": usage.get("input_tokens", 0), "tokens_out": usage.get("output_tokens", 0),
            "tokens_cached": usage.get("cache_read_input_tokens", 0), "cost": data.get("total_cost_usd", 0.0),
            "turns": data.get("num_turns", 0)}


def grade(work, task, arm):
    ext = ARMS[arm]
    solution = work / f"solution.{ext}"
    cases = sorted((TASKS / task / "hidden").glob("*.in"))
    if not solution.exists():
        return {"status": "no-file", "passed": 0, "total": len(cases), "failure": None, "code": None}
    cmd = [str(work / "bin" / "agentica"), "solution.agc"] if ext == "agc" else ["python3", "solution.py"]
    passed, failure, code = 0, None, None
    for case in cases:
        expected = case.with_suffix(".out").read_text().rstrip("\n")
        try:
            done = subprocess.run(cmd, cwd=work, input=case.read_text(), capture_output=True, text=True, timeout=CASE_TIMEOUT)
            actual, err = done.stdout.rstrip("\n"), done.stderr
        except subprocess.TimeoutExpired:
            actual, err = None, "timeout"
        if actual == expected:
            passed += 1
            continue
        if failure is None:
            failure, code = classify(err, ext)
    return {"status": "pass" if passed == len(cases) else "fail", "passed": passed, "total": len(cases),
            "failure": failure, "code": code}


def classify(err, ext):
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


def one_run(args, results, scratch, task, arm, rep):
    name = f"{task}-{arm}-{rep}"
    work = scratch / name
    prepare(work, task, arm)
    began = time.time()
    out, timed_out = run_agent(args.agent, work, task, arm, args.model, args.timeout)
    seconds = round(time.time() - began, 1)
    row = {"task": task, "arm": arm, "rep": rep, "agent": args.agent, "model": args.model or "default",
           "seconds": seconds, "agent_timeout": timed_out}
    if args.agent == "pi":
        row.update(pi_metrics(out))
    elif args.agent == "claude":
        row.update(claude_metrics(out))
    row.update(grade(work, task, arm))
    run_dir = results / name
    run_dir.mkdir(parents=True)
    (run_dir / "agent.jsonl").write_text(out)
    for path in work.glob("solution.*"):
        shutil.copy(path, run_dir / path.name)
    with (results / "results.jsonl").open("a") as handle:
        handle.write(json.dumps(row) + "\n")
    print(f"{name}: {row['status']} {row['passed']}/{row['total']} {seconds}s", flush=True)


def summarize(results):
    rows = [json.loads(line) for line in (results / "results.jsonl").read_text().splitlines()]
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
    (results / "summary.md").write_text(text)
    print(text)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--agent", choices=["pi", "claude", "reference"], default="pi")
    parser.add_argument("--model")
    parser.add_argument("--tasks", nargs="*", default=sorted(p.name for p in TASKS.iterdir() if p.is_dir()))
    parser.add_argument("--arms", nargs="*", default=list(ARMS))
    parser.add_argument("--reps", type=int, default=1)
    parser.add_argument("--timeout", type=int, default=600)
    parser.add_argument("--no-build", action="store_true")
    parser.add_argument("--summarize", metavar="RESULTS_DIR")
    args = parser.parse_args()
    if args.summarize:
        summarize(Path(args.summarize))
        return
    if not args.no_build:
        build()
    stamp = time.strftime("%Y%m%d-%H%M%S")
    results = EVAL / "results" / f"{stamp}-{args.agent}"
    results.mkdir(parents=True)
    scratch = Path(tempfile.mkdtemp(prefix="agentica-eval-"))
    for task in args.tasks:
        for arm in args.arms:
            for rep in range(1, args.reps + 1):
                one_run(args, results, scratch, task, arm, rep)
    summarize(results)
    print(f"results: {results}")


if __name__ == "__main__":
    sys.exit(main())
