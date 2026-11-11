"""Process.spawn and friends through the CLI, against a Node child and a Python one.

fixtures/process-peer.js is the child (modes echo, exit, hold, stubborn, ...); fixtures/process-peer.py (standard
library) reports argv, the environment and the working directory.
Each case writes an Agentica program, runs it with `--json` and
compares its output, or its diagnostic code taken from the last line of stderr.
"""
import json
import os
import re
import shutil

import pytest

from tests.agentica_test import (FIXTURES, PYTHON, TARGET_OS, agc_literal, cli, host_only, kill_process, process_alive,
                                 run, tool, vm_environment, wait_until)

PEER = FIXTURES / "process-peer.js"
PY_PEER = FIXTURES / "process-peer.py"


def spawn(node, mode, extra=""):
    return '  p = Result.unwrap!(Process.spawn(%s, [%s, "%s"%s], Process.Options(timeout_ms: 5000)))\n' % (agc_literal(node), agc_literal(PEER), mode, extra)


def captured(node, mode, body, prefix=""):
    return ('%sdef main() -> Void\n  p = Result.unwrap!(Process.spawn_captured(%s, [%s, "%s"], Process.Options(timeout_ms: 5000)))\n%s\nend\n\n'
            % (prefix, agc_literal(node), agc_literal(PEER), mode, body))


def probe(node, pid):
    return ('Process.wait(Result.unwrap!(Process.spawn(%s, [%s, "probe", %s], Process.Options(timeout_ms: 5000))), 5000)'
            % (agc_literal(node), agc_literal(PEER), pid))


def program(node, mode, body, prefix="", extra=""):
    return prefix + "def main() -> Void\n" + spawn(node, mode, extra) + body + "\nend\n\n"


def cli_run(*args, env=None, cwd=None):
    return run(cli() + list(args), env=vm_environment(env), cwd=cwd)


def write(tmp_path, name, text):
    path = tmp_path / name
    path.write_text(text, encoding="utf-8")
    return path


def run_program(tmp_path, text, denied=False, limit=None, env=None):
    """Returns (result, stdout, stderr): result is None for a clean run, the diagnostic code for a failure
    that printed one (stderr then loses that last line), else the exit status."""
    args = (["--deny-run"] if denied else []) + ["--json"] + (["--max-steps", str(limit)] if limit else [])
    result = cli_run(*args, write(tmp_path, "program.agc", text), env=env)
    lines = result.stderr.strip("\n").split("\n") if result.stderr.strip("\n") else []
    problem = None
    if lines:
        try:
            problem = json.loads(lines[-1])
        except ValueError:
            pass
    if result.code == 0:
        return None, result.stdout, result.stderr
    if isinstance(problem, dict):
        return problem["code"], result.stdout, "\n".join(lines[:-1])
    return result.code, result.stdout, result.stderr


def output(tmp_path, text, expected="", env=None):
    result, out, err = run_program(tmp_path, text, env=env)
    assert result is None, err
    assert err == expected
    return out


def alive(node, pid):
    return run([node, PEER, "probe", pid.strip()]).code == 0


def test_cli_capability_guards_execution_while_check_and_help_work_without_it(tmp_path):
    node = tool("node")
    # The first node start of a test run can be slow on a cold Windows runner (virus scan), so this one waits longer.
    body = ("  puts(Result.unwrap!(Process.read_line(p, 30000)))\n  IO.inspect(System.args())\n"
            "  Result.unwrap!(Process.wait(p, 30000))")
    file = write(tmp_path, "program.agc", program(node, "args", body))
    assert tuple(cli_run("check", file)) == (0, "check ok\n", "")
    denied = cli_run("--json", "--deny-run", file, "--deny-run")
    assert denied.code == 1
    assert json.loads(denied.stderr)["code"] == "RUNTIME-UNWRAP-ERROR"
    assert tuple(cli_run(file, "--deny-run")) == (0, '[]\n["--deny-run"]\n', "")
    help_result = cli_run("help", "Process.send", "--json")
    assert help_result.code == 0
    assert json.loads(help_result.stdout)["result"] == "Result[Void]"


def test_unavailable_and_malformed_commands_return_errors_without_a_child(tmp_path):
    assert output(
        tmp_path,
        'def main() -> Void\n  IO.inspect(Result.ok?(Process.spawn("agentica-nonexistent-command-5l", [], Process.Options(timeout_ms: 1000))))\n'
        '  IO.inspect(Result.ok?(Process.spawn("", [], Process.Options(timeout_ms: 1000))))\n  nul = String.from_code(0)\n'
        '  IO.inspect(Result.ok?(Process.spawn("node", [nul], Process.Options(timeout_ms: 1000))))\nend\n\n') == "false\nfalse\nfalse\n"


def test_a_bare_command_is_searched_in_path(tmp_path):
    node = tool("node")
    name = os.path.splitext(os.path.basename(node))[0]
    text = ('def main() -> Void\n  p = Result.unwrap!(Process.spawn(%s, [%s, "args", "x"], Process.Options(timeout_ms: 5000)))\n'
            '  puts(Result.unwrap!(Process.read_line(p, 5000)))\n  Result.unwrap!(Process.wait(p, 5000))\nend\n\n'
            % (agc_literal(name), agc_literal(PEER)))
    result = cli_run(write(tmp_path, "program.agc", text))
    assert tuple(result) == (0, '["x"]\n', "")


def test_a_bare_command_is_not_looked_for_in_the_working_directory_or_an_empty_path_entry(tmp_path):
    # A runnable `tool` is in the working directory of the run: a shell script, or on Windows a copy of node.exe, which
    # needs nothing beside it (a Homebrew node needs its libnode, so it is not copied elsewhere).
    here = tmp_path / "here"
    here.mkdir()
    if os.name == "nt":
        shutil.copy(tool("node"), here / "tool.exe")
    else:
        (here / "tool").write_text("#!/bin/sh\necho 7\n")
        (here / "tool").chmod(0o755)
    text = ('def main() -> Void\n  started = Process.spawn("tool", ["-e", "console.log(7)"], Process.Options(timeout_ms: 5000))\n'
            '  puts(started.ok?)\n  if started.ok?\n    puts(Result.unwrap!(Process.read_line(started.unwrap!, 5000)))\n'
            '  end\nend\n\n')
    program_file = write(tmp_path, "program.agc", text)
    sep = os.pathsep
    # Windows spells the variable "Path"; the copy that the VM gets must replace it, not sit beside it.
    name = next((key for key in os.environ if key.upper() == "PATH"), "PATH")
    elsewhere = tmp_path / "elsewhere"  # a fixed, empty folder: nothing in the ambient PATH can answer for `tool`
    elsewhere.mkdir()
    old = str(elsewhere)

    def spawned(path):
        result = cli_run(program_file, env={name: path}, cwd=here)
        assert result.code == 0, result.stderr
        return result.stdout

    assert spawned(old) == "false\n"  # the VM adds no implicit search of the working directory
    assert spawned(sep + old) == "false\n"  # an empty PATH entry is skipped, not read as "."
    assert spawned(old + sep + sep) == "false\n"
    assert spawned(str(here) + sep + old) == "true\n7\n"  # the same file is found through PATH
    assert spawned("." + sep + old) == "true\n7\n"  # a relative entry resolves against the working directory


def test_a_name_with_a_slash_resolves_against_the_working_directory_and_a_directory_does_not_run(tmp_path):
    here = tmp_path / "here"
    (here / "bin").mkdir(parents=True)
    for runnable in [here / "tool", here / "bin" / "tool"]:
        if os.name == "nt":
            shutil.copy(tool("node"), runnable.with_name("tool.exe"))
        else:
            runnable.write_text("#!/bin/sh\necho 7\n")
            runnable.chmod(0o755)
    text = ('def show(name: String) -> Void\n'
            '  case Process.spawn(name, ["-e", "console.log(7)"], Process.Options(timeout_ms: 5000))\n'
            '    ok(p) -> puts("#{name}: #{Process.read_line(p, 5000)} #{Process.wait(p, 5000)}")\n'
            '    error(message) -> puts("#{name}: #{message}")\n  end\nend\n\n'
            'def main() -> Void\n  show("tool")\n  show("./tool")\n  show("bin/tool")\n  show("bin")\nend\n\n')
    program_file = write(tmp_path, "program.agc", text)
    name = next((key for key in os.environ if key.upper() == "PATH"), "PATH")
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    for entries in [[str(elsewhere)], ["bin", str(elsewhere)], [".", str(elsewhere)]]:
        result = cli_run(program_file, env={name: os.pathsep.join(entries)}, cwd=here)
        found = entries[0] != str(elsewhere)
        assert tuple(result) == (0, "tool: " + ('ok("7") ok(0)' if found else "process: executable is unavailable")
                                 + '\n./tool: ok("7") ok(0)\nbin/tool: ok("7") ok(0)\n'
                                 + "bin: process: executable is unavailable\n", ""), entries


def test_permission_literal_argv_and_inherited_task_capability(tmp_path):
    node = tool("node")
    text = program(node, "args", "  puts(Result.unwrap!(Process.read_line(p, 5000)))\n  IO.inspect(Process.wait(p, 5000))",
                   "", ', "a b;$x", "--deny-run"')
    denied, out, _ = run_program(tmp_path, text, denied=True)
    assert denied == "RUNTIME-UNWRAP-ERROR"
    assert out == ""
    assert output(tmp_path, text) == '["a b;$x","--deny-run"]\nok(0)\n'


def test_arguments_with_backslashes_quotes_and_interpolation_marks_reach_the_child_unchanged(tmp_path):
    node = tool("node")
    words = ['back\\slash\\', 'say "hi"', "#{x}", "tail\\\\", "", "ñ 🙂 ^&|<>%PATH%"]
    extra = "".join(", " + agc_literal(word) for word in words)
    out = output(tmp_path, program(node, "args", "  puts(Result.unwrap!(Process.read_line(p, 5000)))\n"
                                   "  Result.unwrap!(Process.wait(p, 5000))", "", extra))
    assert json.loads(out) == words


def test_flushed_text_and_bytes_reply_before_stdin_eof_stderr_stays_separate(tmp_path):
    node = tool("node")
    body = ('  Result.unwrap!(Process.send(p, "ñ\\n", 5000))\n'
            "  puts(Result.unwrap!(Process.read_line(p, 5000)))\n"
            "  Result.unwrap!(Process.send_bytes(p, Bytes.from_list([0, 255, 10]).unwrap!, 5000))\n"
            "  IO.inspect(Process.read_bytes(p, 0, 5000))\n"
            "  IO.inspect(Process.read_bytes(p, 3, 5000))\n"
            "  IO.inspect(Process.close_stdin(p, 5000))\n"
            "  IO.inspect(Process.close_stdin(p, 5000))\n"
            '  IO.inspect(Result.ok?(Process.send(p, "x", 5000)))\n'
            "  IO.inspect(Process.read_bytes(p, 3, 5000))\n"
            "  IO.inspect(Process.wait(p, 5000))\n"
            "  Process.close(p)\n  Process.close(p)\n"
            "  IO.inspect(Result.ok?(Process.wait(p, 5000)))")
    assert output(tmp_path, program(node, "echo", body), "peer stderr\n") == \
        "ñ\nok(<Bytes 0>)\nok(<Bytes 3 00ff0a>)\nok()\nok()\nfalse\nok(<Bytes 0>)\nok(0)\nfalse\n"


def test_eof_nonzero_and_repeated_exit_waits_preserve_unread_output(tmp_path):
    node = tool("node")
    body = ("  IO.inspect(Process.wait(p, 5000))\n  IO.inspect(Process.wait(p, 5000))\n"
            "  puts(Result.unwrap!(Process.read_line(p, 5000)))\n  puts(Result.unwrap!(Process.read_line(p, 5000)))\n"
            "  IO.inspect(Result.ok?(Process.read_line(p, 5000)))")
    assert output(tmp_path, program(node, "exit", body)) == "ok(7)\nok(7)\ndone\nlast\nfalse\n"


def test_invalid_input_preserves_bytes_strict_decoding_consumes_a_complete_bad_line(tmp_path):
    node = tool("node")
    body = ("  IO.inspect(Result.ok?(Process.read_bytes(p, -1, 1000)))\n"
            "  IO.inspect(Result.ok?(Process.read_bytes(p, 1048577, 1000)))\n"
            "  IO.inspect(Result.ok?(Process.read_line(p, 0)))\n  IO.inspect(Result.ok?(Process.read_line(p, 5000)))\n"
            "  puts(Result.unwrap!(Process.read_line(p, 5000)))")
    assert output(tmp_path, program(node, "invalid", body)) == "false\nfalse\nfalse\nfalse\nvalid\n"
    body = ("  IO.inspect(Result.ok?(Process.send_bytes(p, (Bytes.from_list(List.repeat(65, 1048576)).unwrap! + \"A\".bytes), 1000)))\n"
            '  Result.unwrap!(Process.send(p, "valid\\n", 5000))\n  puts(Result.unwrap!(Process.read_line(p, 5000)))')
    assert output(tmp_path, program(node, "echo", body), "peer stderr\n") == "false\nvalid\n"


def test_streaming_exceeds_1_mib_with_concurrent_reads_and_independently_drained_stderr(tmp_path):
    node = tool("node")
    drain = ("def drain(p: Process) -> Int\n  first = Result.unwrap!(Process.read_bytes(p, 1048576, 5000))\n"
             "  second = Result.unwrap!(Process.read_bytes(p, 1048576, 5000))\n"
             "  return first.size + second.size\nend\n\n")
    assert output(tmp_path, program(
        node, "flood", "  reader = Task.spawn(&drain, p)\n  IO.inspect(Process.wait(p, 5000))\n  IO.inspect(Task.await(reader))",
        drain)) == "ok(0)\n2097152\n"
    result, out, err = run_program(tmp_path, program(node, "stderr", "  IO.inspect(Process.wait(p, 5000))"))
    assert result is None
    assert out == "ok(0)\n"
    assert len(err) == 2097152


def test_wait_retries_preserve_children_active_stream_deadlines_abort_them(tmp_path):
    node = tool("node")
    body = ("  _pid = Result.unwrap!(Process.read_line(p, 5000))\n  reader = Task.spawn(&read, p)\n  Task.sleep(100)\n"
            "  IO.inspect(Result.ok?(Process.read_line(p, 20)))\n"
            '  Result.unwrap!(Process.send(p, "exit\\n", 5000))\n'
            "  IO.inspect(Result.ok?(Task.await(reader)))\n  IO.inspect(Process.wait(p, 5000))")
    read = "def read(p: Process) -> Result[String]\n  return Process.read_line(p, 5000)\nend\n\n"
    assert output(tmp_path, program(node, "release", body, read)) == "false\nfalse\nok(3)\n"
    body = ("  _pid = Result.unwrap!(Process.read_line(p, 5000))\n  IO.inspect(Result.ok?(Process.wait(p, 20)))\n"
            '  Result.unwrap!(Process.send(p, "exit\\n", 5000))\n  IO.inspect(Process.wait(p, 5000))')
    assert output(tmp_path, program(node, "release", body)) == "false\nok(3)\n"
    assert output(tmp_path, program(
        node, "oversized", "  IO.inspect(Result.ok?(Process.read_line(p, 5000)))\n  IO.inspect(Result.ok?(Process.wait(p, 1000)))")) == \
        "false\nfalse\n"


@pytest.mark.parametrize("operation", (
    "Process.read_line(p, 20)",
    "Process.send_bytes(p, Bytes.from_list(List.repeat(65, 1048576)).unwrap!, 20)",
))
def test_hold_operations_abort_when_the_stream_deadline_passes(tmp_path, operation):
    node = tool("node")
    body = ("  puts(Result.unwrap!(Process.read_line(p, 5000)))\n  IO.inspect(Result.ok?(%s))\n"
            "  IO.inspect(Result.ok?(Process.wait(p, 20)))" % operation)
    result, out, _ = run_program(tmp_path, program(node, "hold", body))
    assert result is None
    lines = out.split("\n")
    lines = lines[:-1] if lines[-1] == "" else lines
    assert lines[1:] == ["false", "false"]
    assert not alive(node, lines[0])


@pytest.mark.parametrize("ending", (
    "",
    "  System.exit(4)",
    "  _ = 1 / 0",
    "  while true\n  end",
    "  task = Task.spawn(&crash, 0)\n  _n = Task.await(task)",
), ids=("clean-exit", "exit-4", "divide-by-zero", "infinite-loop", "task-crash"))
def test_every_way_a_run_ends_kills_and_reaps_its_children(tmp_path, ending):
    node = tool("node")
    result, out, _ = run_program(
        tmp_path,
        program(node, "hold", "  puts(Result.unwrap!(Process.read_line(p, 5000)))\n" + ending,
                "def crash(n: Int) -> Int\n  return 1 / 0\nend\n\n"),
        limit=100 if "while" in ending else None)
    assert re.search(r"\A[0-9]+\n\Z", out)
    if "crash" in ending:
        assert result == "RUNTIME-TASK-CRASHED"
    assert not alive(node, out)


def test_a_stubborn_hold_is_reaped_after_close(tmp_path):
    node = tool("node")
    result, out, _ = run_program(tmp_path, captured(node, "stubborn", "  puts(Result.unwrap!(Process.read_line(p, 5000)))"))
    assert result is None
    assert re.search(r"\A[0-9]+\n\Z", out)
    assert not alive(node, out)


def test_closing_a_plain_child_returns_only_after_it_is_gone_even_when_it_ignores_sigterm(tmp_path):
    node = tool("node")
    body = ("  pid = Result.unwrap!(Process.read_line(p, 5000))\n  Process.close(p)\n  IO.inspect(%s)" % probe(node, "pid"))
    assert output(tmp_path, program(node, "stubborn", body)) == "ok(1)\n"


def python_child(mode, words=(), dir=None, timeout=5000, kind="spawn_captured"):
    """Program text that starts the Python peer in `mode` (with `kind` in `dir`, else plain) and prints its first
    line."""
    arguments = ", ".join([agc_literal(PY_PEER), '"%s"' % mode] + [agc_literal(word) for word in words])
    chdir = ", chdir: %s" % agc_literal(dir) if dir else ""
    start = "Process.%s(%s, [%s], Process.Options(timeout_ms: %d%s))" % (
        kind if dir else "spawn", agc_literal(PYTHON), arguments, timeout, chdir)
    return ('def main() -> Void\n  started = %s\n  if !started.ok?\n    puts("not started")\n    return\n  end\n'
            '  p = Result.unwrap!(started)\n  puts(Result.unwrap!(Process.read_line(p, 5000)))\n'
            '  Process.close(p)\nend\n\n' % start)


WORDS = ["back\\slash\\", 'say "hi"', "#{x}", "tail\\\\", "", "ñ 🙂 ^&|<>%PATH%", "two  spaces", "-", "--deny-run"]


def test_arguments_reach_an_independent_python_child_unchanged(tmp_path):
    out = output(tmp_path, python_child("args", WORDS))
    assert json.loads(out) == WORDS


@pytest.mark.parametrize("kind", ["spawn", "spawn_captured", "spawn_channel"])
def test_the_child_starts_in_the_chdir_folder_and_a_bad_one_is_an_error(tmp_path, kind):
    directory = tmp_path / "dir ñ 🙂"
    directory.mkdir()
    out = output(tmp_path, python_child("cwd", dir=str(directory), kind=kind))
    assert os.path.samefile(out.strip("\n"), directory)
    (tmp_path / "file").write_text("x")
    for bad in (tmp_path / "file", tmp_path / "missing"):
        assert output(tmp_path, python_child("cwd", dir=str(bad), kind=kind)) == "not started\n"


def test_the_spawns_leave_out_the_timeout_and_the_directory(tmp_path):
    peer = "%s, [%s, " % (agc_literal(PYTHON), agc_literal(PY_PEER))
    body = ('def main() -> Void\n  a = Result.unwrap!(Process.spawn(%s"args", "x"]))\n'
            '  puts(Result.unwrap!(Process.read_line(a, 5000)))\n  Process.close(a)\n'
            '  c = Result.unwrap!(Process.spawn_captured(%s"cwd"]))\n'
            '  puts(Result.unwrap!(Process.read_line(c, 5000)))\n  Process.close(c)\n'
            '  d = Result.unwrap!(Process.spawn_channel(%s"cwd"]))\n'
            '  puts(Result.unwrap!(Process.read_line(d, 5000)))\n  Process.close(d)\nend\n\n' % (peer, peer, peer))
    lines = output(tmp_path, body).split("\n")
    assert json.loads(lines[0]) == ["x"]
    assert os.path.samefile(lines[1], os.getcwd()) and os.path.samefile(lines[2], os.getcwd())


def test_the_child_environment_is_inherited_without_the_vm_private_entries(tmp_path):
    # Windows names are case-insensitive, so a differently cased private name must go too; elsewhere it is another variable.
    channel = "Agentica_Channel" if TARGET_OS == "windows" else "AGENTICA_CHANNEL"
    # Only "3,4" (and on POSIX the one-socket "3") would be adopted as a channel (vm/duplex.c,
    # agc_parent_take); the child must not see the name at all. The metrics values are ones that would start nothing if a child did see them.
    env = {"PROBE_TEXT": "ñ 🙂 = x", channel: "7", "AGENTICA_VM_METRICS": "0",
           "AGENTICA_VM_METRICS_FILE": "/nonexistent/agentica-metrics-must-not-open"}
    shown = json.loads(output(tmp_path, python_child("env"), env=env))
    assert shown["PROBE_TEXT"] == "ñ 🙂 = x"
    private = {"AGENTICA_CHANNEL", "AGENTICA_VM_METRICS", "AGENTICA_VM_METRICS_FILE"}
    assert not private.intersection(name.upper() for name in shown)


def test_a_very_long_argument_is_an_error_where_the_system_limits_the_command_line_else_it_arrives(tmp_path):
    word = "x" * 40000
    text = ('def main() -> Void\n  p = Process.spawn(%s, [%s, "args", %s], Process.Options(timeout_ms: 5000))\n  puts(p.ok?)\n'
            '  if p.ok?\n    puts(String.length(Result.unwrap!(Process.read_line(p.unwrap!, 5000))))\n'
            '    Process.close(p.unwrap!)\n  end\nend\n\n' % (agc_literal(PYTHON), agc_literal(PY_PEER), agc_literal(word)))
    out = output(tmp_path, text)
    # CreateProcess takes at most 32767 characters of command line; Linux and macOS take a word this size.
    assert out == ("false\n" if TARGET_OS == "windows" else "true\n%d\n" % (len(word) + 4))


def test_a_file_that_cannot_run_is_an_error_and_the_next_spawn_still_works(tmp_path):
    bad = tmp_path / "bad.exe"
    bad.write_text("#!/nonexistent/interpreter\n")
    bad.chmod(0o755)
    text = ('def main() -> Void\n  IO.inspect(Result.ok?(Process.spawn(%s, [], Process.Options(timeout_ms: 5000))))\n%s'
            % (agc_literal(bad), "  puts(Result.unwrap!(Process.read_line(Result.unwrap!(Process.spawn(%s, [%s, \"args\"], Process.Options(timeout_ms: 5000))), 5000)))\nend\n\n"
               % (agc_literal(PYTHON), agc_literal(PY_PEER))))
    assert output(tmp_path, text) == "false\n[]\n"


def streams_to(count, out, err, command=None, read="Process.read_line(p, 5000)"):
    """Program text that starts the Python peer in streams mode with `out` and `err` (Agentica expressions) as the
    files, then prints `read` and the exit code, or the error of the spawn."""
    start = 'Process.spawn(%s, [%s, "streams", "%d"], Process.Options(timeout_ms: 5000, out: %s, err: %s))' % (
        command or agc_literal(PYTHON), agc_literal(PY_PEER), count, out, err)
    return ('def main() -> Void\n  started = %s\n  if !started.ok?\n    puts(started.message)\n    return\n  end\n'
            '  p = started.unwrap!\n  IO.inspect(%s)\n  IO.inspect(Process.wait(p, 5000))\n'
            '  Process.close(p)\nend\n\n' % (start, read))


def test_out_and_err_send_the_streams_to_files_created_or_truncated(tmp_path):
    out, err = tmp_path / "out.txt", tmp_path / "err.txt"
    err.write_bytes(b"older and longer content\n")
    count = 3 * 1048576  # past the 1 MiB that a pipe read or a captured stream keeps
    text = streams_to(count, agc_literal(out), agc_literal(err))
    assert output(tmp_path, text) == 'error("process: end of input")\nok(0)\n'
    assert out.read_bytes() == b"o" * count
    assert err.read_bytes() == b"err\n"
    if TARGET_OS != "windows":
        mask = os.umask(0)
        os.umask(mask)
        assert out.stat().st_mode & 0o777 == 0o666 & ~mask
    # One file named twice, in two spellings, is one descriptor: the streams follow each other as with `> f 2>&1`.
    both = tmp_path / "both.txt"
    output(tmp_path, streams_to(4, agc_literal(both), agc_literal(os.path.join(str(tmp_path), ".", "both.txt"))))
    assert both.read_bytes() == b"oooo" + b"err\n"
    # Only err: stdout stays the pipe that the program reads.
    err.unlink()
    text = streams_to(4, '""', agc_literal(err), read="Process.read_bytes(p, 8, 5000)")
    assert output(tmp_path, text) == "ok(<Bytes 4 6f6f6f6f>)\nok(0)\n"
    assert err.read_bytes() == b"err\n"


@pytest.mark.parametrize("kind", ["spawn_captured", "spawn_channel"])
def test_out_and_err_are_only_for_process_spawn(tmp_path, kind):
    target = tmp_path / "out.txt"
    for field in ("out", "err"):
        text = ('def main() -> Void\n  started = Process.%s(%s, [%s, "args"], Process.Options(%s: %s))\n'
                '  puts(started.message)\nend\n\n' % (kind, agc_literal(PYTHON), agc_literal(PY_PEER), field,
                                                       agc_literal(target)))
        assert output(tmp_path, text) == "process: out and err need Process.spawn\n"
    assert not target.exists()


def test_options_layout_matches_the_vm_reader():
    """vm/process.c reads Process.Options by position (OPTION_*): the catalog's field order must be the same."""
    root = FIXTURES.parent.parent
    catalog = (root / "compiler/catalog/builtins_data.agc").read_text(encoding="utf-8")
    record = re.search(r'name: "Process\.Options",\n    fields: \[(.*?)\n    \],', catalog, re.S).group(1)
    fields = re.findall(r'name: "([a-z_]+)"', record)
    reader = (root / "vm/process.c").read_text(encoding="utf-8")
    names = re.search(r"enum \{ (OPTION_[A-Z_, ]+) \};", reader).group(1).split(", ")
    assert names[-1] == "OPTION_FIELDS"
    assert [name.removeprefix("OPTION_").lower() for name in names[:-1]] == fields


def test_an_out_or_err_file_that_cannot_be_opened_is_an_error_and_no_child_runs(tmp_path):
    late = tmp_path / "late.txt"
    for out, err, expected in [
        (agc_literal(tmp_path), '""', "process: out does not refer to a regular file"),
        ('""', agc_literal(tmp_path / "no-such-dir" / "err.txt"), "process: cannot open the err file"),
        ('"a" + String.from_code(0)', '""', "process: out and err cannot contain NUL"),
    ] + ([(agc_literal(r"\\.\NUL"), '""', "process: out does not refer to a regular file"),
          ('""', agc_literal("//?/" + str(tmp_path / "err.txt")), "process: err does not refer to a regular file")]
         if TARGET_OS == "windows" else []):
        assert output(tmp_path, streams_to(1, out, err)).startswith(expected + "\n")
    # A spawn refused for its command opens no file.
    text = streams_to(1, agc_literal(late), '""', command='"agentica-no-such-command-7h"')
    assert output(tmp_path, text) == "process: executable is unavailable\n"
    assert not late.exists()
    result = cli_run("--deny-fs", write(tmp_path, "program.agc", streams_to(1, agc_literal(late), '""')))
    assert result.stdout == "denied: --deny-fs turns off file access\n" and not late.exists()


@host_only(TARGET_OS == "windows", "Windows has no process groups that a stop signals; pgroup stops the child alone")
@pytest.mark.parametrize("start", ['Process.spawn(%s, [%s, "family"], Process.Options(timeout_ms: 5000, pgroup: %s))',
                                   'Process.spawn_captured(%s, [%s, "family"], Process.Options(timeout_ms: 5000, pgroup: %s))'],
                         ids=["spawn", "captured"])
def test_closing_a_child_started_with_pgroup_stops_its_own_children(tmp_path, start):
    """The Python peer starts a grandchild and waits. With pgroup, close signals the child's whole process group
    (SIGKILL for spawn, SIGTERM for spawn_captured), so the grandchild ends too; without it the grandchild outlives
    the close."""
    def grandchild(group):
        text = ('def main() -> Void\n  p = Result.unwrap!(%s)\n  puts(Result.unwrap!(Process.read_line(p, 5000)))\n'
                '  Process.close(p)\nend\n\n' % (start % (agc_literal(PYTHON), agc_literal(PY_PEER), group)))
        return output(tmp_path, text).strip()

    left = grandchild("false")
    try:
        assert process_alive(left)
    finally:
        kill_process(left)
    pid = grandchild("true")
    try:
        assert wait_until(lambda: not process_alive(pid))
    finally:
        kill_process(pid)


def stopped_family(tmp_path, ending, *mode):
    """Starts the Python peer in family mode as a captured pgroup child, prints its grandchild's pid, then closes it
    and returns at once, or just returns: either way the end of the run comes inside the child's 1 s grace."""
    stop = "  Process.close(p)\n" if ending == "close" else ""
    words = ", ".join(agc_literal(word) for word in ("family",) + mode)
    text = ('def main() -> Void\n  p = Result.unwrap!(Process.spawn_captured(%s, [%s, %s], Process.Options(timeout_ms: 5000, pgroup: true)))\n'
            '  puts(Result.unwrap!(Process.read_line(p, 5000)))\n%send\n\n' % (agc_literal(PYTHON), agc_literal(PY_PEER),
                                                                               words, stop))
    return output(tmp_path, text).strip()


@host_only(TARGET_OS == "windows", "Windows has no process groups that a stop signals; pgroup stops the child alone")
@pytest.mark.parametrize("ending", ["close", "end of run"])
def test_a_pgroup_descendant_that_ignores_sigterm_gets_sigkill_after_the_grace(tmp_path, ending):
    """The captured child dies of the SIGTERM at once, but its grandchild ignores it: when the grace is over, the group
    gets SIGKILL although its leader was already reaped."""
    pid = stopped_family(tmp_path, ending, "stubborn")
    try:
        assert wait_until(lambda: not process_alive(pid))
    finally:
        kill_process(pid)


@host_only(TARGET_OS == "windows", "Windows has no process groups that a stop signals; pgroup stops the child alone")
@pytest.mark.parametrize("ending", ["close", "end of run"])
def test_a_pgroup_descendant_gets_the_whole_grace_after_its_leader_is_reaped(tmp_path, ending):
    """The grandchild takes 300 ms on SIGTERM, then writes a marker: the end of the run waits for it within the grace
    instead of sending SIGKILL once the leader is reaped."""
    marker = tmp_path / "marker"
    pid = stopped_family(tmp_path, ending, "slow", str(marker))
    try:
        assert marker.read_text() == "done"
    finally:
        kill_process(pid)
