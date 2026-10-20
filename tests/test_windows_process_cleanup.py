"""The cleanup and hand-off promises of the processes, checked with Windows means.

The POSIX cases of tests/test_vm_diff_8.py, tests/test_bdd_integration.py and tests/test_bdd_posix.py start /bin/sh,
use SIGTERM and SIGKILL, read /proc, make a folder unwritable with chmod or use a shell script as the binary; they are
host-only on Windows and name the case here that keeps the same promise. A Python child (fixtures/process-peer.py or
`python -c`) takes the place of the shell, `process_alive` and the PowerShell process list take the place of kill -0 and
/proc, an access list takes the place of chmod, and a copy of node.exe with a preloaded script takes the place of the
script that is the binary (the VM starts only .exe and .com files on Windows, docs/vm/10-io-processes.md, 10.4).

Windows has no SIGTERM: libuv ends a child with TerminateProcess at once, and the job object of the VM ends the
children of a child that is a VM. So the cases of "SIGTERM first, SIGKILL after a second" check what Windows promises
instead: close ends the child and its children, never waits, and a child that ignores the console signals is stopped.
"""
import json
import os
import shutil
import time

import pytest

from tests.agentica_test import (FIXTURES, PYTHON, Child, agc_literal, binary, cli, compile_agc, kill_process,
                                 process_alive, run, run_vm, scaled, start_vm, tool, vm_binary, vm_command,
                                 vm_environment, wait_until)
from tests.test_bdd import bdd, file_error  # noqa: F401  (bdd is a fixture of that module)
from tests.test_bdd_integration import cleanup, codes, json_test, ms, suite  # noqa: F401  (cleanup is a fixture)
from tests.windows_support import current_user_sid, icacls, processes_mentioning

pytestmark = pytest.mark.skipif(os.name != "nt", reason="host-only: TerminateProcess, job objects and access lists exist on Windows only")

PEER = FIXTURES / "process-peer.py"
WAIT = scaled(20)

# The VM that is the child of the test prints its own pid and the pid of the Python peer that it starts.
INNER_PROGRAM = """\
def main() -> Void
  args = System.args()
  p = Result.unwrap!(Process.spawn(args[0], [args[1], "hold"], 60000))
  puts("#{System.pid()} #{Result.unwrap!(Process.read_line(p, 60000))}")
  IO.flush()
  Task.sleep(60000)
end
"""

# The parent starts that VM as a captured child, reports the two pids, then closes it (or lets a read time out) and
# stays alive, so that the test sees what the close alone did.
OUTER_PROGRAM = """\
def main() -> Void
  args = System.args()
  words = ["run", "--allow-run", "--", args[1], args[3], args[4]]
  child = Result.unwrap!(Process.spawn_captured(args[0], words, ".", 60000))
  puts(Result.unwrap!(Process.read_line(child, 60000)))
  IO.flush()
  if args[2] == "close"
    Process.close(child)
  else
    IO.inspect(Process.read_line(child, 200))
  end
  puts("released")
  IO.flush()
  Task.sleep(60000)
end
"""

# A captured Python child that prints its pid. The stubborn one also ignores Ctrl+Break and Ctrl+C, the only polite
# stops Windows has, and does not look at its input: close must end it all the same.
PLAIN_CHILD = "import os,sys,time;sys.stdout.reconfigure(newline='\\n');print(os.getpid(),flush=True);time.sleep(120)"
STUBBORN_CHILD = ("import os,signal,sys,time;signal.signal(signal.SIGBREAK,signal.SIG_IGN);"
                  "signal.signal(signal.SIGINT,signal.SIG_IGN);" + PLAIN_CHILD.split(";", 1)[1])

CLOSE_PROGRAM = """\
def main() -> Void
  args = System.args()
  p = Result.unwrap!(Process.spawn_captured(args[0], ["-c", args[1]], ".", 60000))
  puts(Result.unwrap!(Process.read_line(p, 60000)))
  IO.flush()
  start = Time.monotonic_ms()
  Process.close(p)
  puts(Time.monotonic_ms() - start)
  IO.flush()
  if args[2] == "stay"
    Task.sleep(60000)
  end
end
"""

# stderr gets the byte 0xFF at once, stdout gets "hi" after a second; the bytes are written without a translation.
OUTPUT_CHILD = ("import sys,time;sys.stderr.buffer.write(bytes([255]));sys.stderr.flush();time.sleep(1);"
                "sys.stdout.buffer.write(b'hi\\n');sys.stdout.flush()")

OUTPUT_PROGRAM = """\
def main() -> Void
  args = System.args()
  p = Result.unwrap!(Process.spawn_captured(args[0], ["-c", args[1]], ".", 60000))
  IO.inspect(Process.output(p, 50))
  out = Result.unwrap!(Process.output(p, 60000))
  puts("#{out.stdout.inspect} #{out.stderr.length} #{String.code(out.stderr)} #{out.truncated}")
  Process.close(p)
end
"""

HELLO_PROGRAM = 'def main() -> Void\n  puts("hi")\nend\n'

# Makes the file at args[1] with create_private, which gives it the access list only the owner has, and copies args[0].
COPY_PROGRAM = """\
def main() -> Void
  args = System.args()
  input = Result.unwrap!(File.open(args[0], "read", 5000))
  out = Result.unwrap!(File.open(args[1], "create_private", 5000))
  bytes = Result.unwrap!(File.read_bytes(input, 1048576, 5000))
  Result.unwrap!(File.write_bytes(out, bytes, 5000))
  Result.unwrap!(File.close(input, 5000))
  Result.unwrap!(File.close(out, 5000))
end
"""


def program(tmp_path, name, text):
    source = tmp_path / (name + ".agc")
    source.write_text(text, encoding="utf-8")
    return compile_agc(source, tmp_path / (name + ".agcb"))


def gone(pid):
    return wait_until(lambda: not process_alive(pid), WAIT, 0.1)


def pids_of(line, request):
    """The pids in a line of the program; each is killed when the test ends if it is still there."""
    pids = line.split()
    assert len(pids) >= 1 and all(word.isdigit() for word in pids), line
    for pid in pids:
        request.addfinalizer(lambda found=pid: kill_process(found))
    return pids


# The POSIX case closes the child with SIGTERM, so that a VM child stops its own children before it ends. Windows has
# no such signal: the VM child is ended with TerminateProcess, and the job object that it made for its own children
# ends them when it dies. The promise is the same, no process of the tree stays, and it is checked while the parent
# is alive, so the end of the run does not do the work of the close.
@pytest.mark.parametrize("mode", ["close", "timeout"])
def test_closing_a_captured_vm_child_ends_the_child_and_its_own_child(adopt, request, tmp_path, mode):
    inner = program(tmp_path, "captured-inner", INNER_PROGRAM)
    outer = program(tmp_path, "captured-outer", OUTER_PROGRAM)
    parent = adopt(start_vm(outer, vm_binary(), inner, mode, PYTHON, PEER, flags=["--allow-run"]))
    pids = pids_of(parent.next_line(WAIT), request)
    assert len(pids) == 2
    if mode == "timeout":
        assert parent.next_line(WAIT) == 'error("network: operation timed out")'
    assert parent.next_line(WAIT) == "released"
    for pid in pids:
        assert gone(pid), "%s: %s" % (mode, pid)
    assert parent.process.poll() is None  # the parent is still running: the close did it


# The POSIX case sends SIGTERM and then SIGKILL to a child that traps SIGTERM. Windows has only TerminateProcess, which
# a child cannot trap, so the child here ignores the console signals and the close must still be quick and final.
@pytest.mark.parametrize("child_code", [PLAIN_CHILD, STUBBORN_CHILD], ids=["plain", "stubborn"])
@pytest.mark.parametrize("then", ["stay", "exit"])
def test_close_never_waits_for_a_captured_child_and_one_that_ignores_the_console_signals_is_killed(
        adopt, request, tmp_path, child_code, then):
    bytecode = program(tmp_path, "captured-grace", CLOSE_PROGRAM)
    vm = adopt(start_vm(bytecode, PYTHON, child_code, then, flags=["--allow-run"]))
    pid = pids_of(vm.next_line(WAIT), request)[0]
    assert int(vm.next_line(WAIT)) < 500
    if then == "stay":
        assert gone(pid)
        assert vm.process.poll() is None
    else:
        assert vm.wait(WAIT) == 0
        assert gone(pid)


def test_an_output_timeout_keeps_the_captured_child_and_output_decodes_invalid_utf8_as_ufffd(tmp_path):
    bytecode = program(tmp_path, "captured-output", OUTPUT_PROGRAM)
    result = run_vm(bytecode, "--allow-run", args=[PYTHON, OUTPUT_CHILD], env=vm_environment(), cwd=tmp_path)
    assert (result.code, result.stdout, result.stderr) == (
        0, 'error("network: operation timed out")\n"hi\\n" 1 65533 false\n', "")


# The POSIX case makes the input private with chmod 600, and refuses mode 644 and a symbolic link. Windows has an
# access list for the owner only (create_private), refuses one that names anyone else, a link and a second name.
def test_the_hidden_driver_pid_flag_loads_only_a_private_input_and_then_deletes_it(tmp_path):
    hello = program(tmp_path, "hello", HELLO_PROGRAM)
    copier = program(tmp_path, "copy-private", COPY_PROGRAM)
    copy = tmp_path / "driver-copy.agcb"
    environment = vm_environment()

    def make_private(path=copy):
        made = run_vm(copier, args=[hello, path], env=environment, cwd=tmp_path)
        assert (made.code, made.stderr) == (0, ""), made

    def driven(pid, path=copy):
        result = run(vm_command() + ["--driver-pid", str(pid), "--", path], env=environment, cwd=tmp_path)
        return result.code, result.stdout, result.stderr

    def refused(pid, why, path=copy):
        code, output, errors = driven(pid, path)
        assert (code, output) == (2, ""), errors
        assert why in errors, errors

    make_private()
    assert driven(os.getpid()) == (0, "hi\n", "")
    assert not copy.exists()
    # Anyone else on the access list makes it public, like mode 644.
    make_private()
    icacls(copy, "/grant", "*S-1-1-0:R")
    refused(os.getpid(), "cannot read")
    assert copy.exists()
    copy.unlink()
    # The pid must be the one of the parent.
    make_private()
    refused(os.getpid() + 1, "does not match the parent process")
    assert copy.exists()
    link = tmp_path / "driver-link.agcb"
    os.symlink(copy, link)
    refused(os.getpid(), "cannot read", link)
    assert copy.exists()
    link.unlink()
    other_name = tmp_path / "driver-other-name.agcb"
    os.link(copy, other_name)
    refused(os.getpid(), "cannot read")
    assert copy.exists() and other_name.exists()


def holder_program(pid_file):
    """The program under test: it starts a Python child, writes the child's pid to a file, says ready and waits."""
    return f"""\
def main() -> Void
  p = Process.spawn({agc_literal(PYTHON)}, [{agc_literal(PEER)}, "hold"], {ms(5000)}).unwrap!
  pid = Process.read_line(p, {ms(5000)}).unwrap!
  File.write_text({agc_literal(pid_file)}, pid, {ms(5000)}).unwrap!
  puts("ready")
  IO.flush()
  line = IO.gets()
end
"""


def pid_from(pid_file):
    return pid_file.read_text().strip() if pid_file.exists() and pid_file.read_text().strip().isdigit() else None


def kill_tree_at_end(cleanup, find):
    """Kill what a failing test would leave running; `find` is called at the end, when the pids are known."""
    cleanup(lambda: [kill_process(pid) for pid in find()])


def test_a_failed_scenario_leaves_no_process_of_its_program_behind(tmp_path, cleanup):
    pid_file = tmp_path / "pid.txt"
    directory = suite(tmp_path, {
        "holder.agc": holder_program(pid_file),
        "holder.feature": ('Feature: Cleanup\nScenario: held\nGiven the Agentica program "holder.agc"\n'
                           'Then I receive the line "ready" within ' + ms(5000) + ' milliseconds\n'
                           "And the program exits with code 0 within 200 milliseconds\n")})
    kill_tree_at_end(cleanup, lambda: [pid_from(pid_file)] if pid_from(pid_file) else [])
    report = json_test("--allow-run", directory / "holder.feature")
    assert codes(report) == ["RUNTIME-BDD-TIMEOUT"]
    pid = pid_from(pid_file)
    assert pid, "the program started its child"
    assert gone(pid), pid


@pytest.mark.slow
def test_killing_the_driver_stops_the_runner_the_scenario_vm_and_the_program_and_a_later_run_removes_its_folder(
        tmp_path, cleanup):
    pid_file = tmp_path / "pid.txt"
    directory = suite(tmp_path, {
        "holder.agc": holder_program(pid_file),
        "holder.feature": ('Feature: Killed\nScenario: held\nGiven the Agentica program "holder.agc"\n'
                           'Then I receive the line "ready" within ' + ms(5000) + ' milliseconds\n'
                           "And the program exits with code 0 within " + ms(20000) + " milliseconds\n")})
    temporary = directory / "tmp"
    temporary.mkdir()
    env = vm_environment({"TMPDIR": temporary})
    # The runner, the VM and the program are not children of the test: kill them if the cleanup under test fails.
    kill_tree_at_end(cleanup, lambda: processes_mentioning(temporary))
    driver = Child(cli() + ["test", "--allow-run", directory / "holder.feature"], env=env)
    cleanup(driver.stop)
    assert wait_until(lambda: pid_from(pid_file) is not None, scaled(20))
    # The runner has the run folder in its command line: the list sees the runner and the VM of the scenario.
    assert wait_until(lambda: processes_mentioning(temporary), scaled(20), 0.5)
    # Only the driver dies, not its tree: the runner, the VM and the program must follow it.
    driver.process.kill()
    driver.process.wait()
    pid = pid_from(pid_file)
    assert gone(pid), pid
    assert wait_until(lambda: not processes_mentioning(temporary), scaled(20), 0.5)
    folders = os.listdir(temporary)
    assert len(folders) == 1 and folders[0].startswith("agentica-bdd-"), folders
    # A later run removes the folder of the dead driver and keeps live, linked and malformed ones. Windows sweeps only
    # folders that are a minute old (a run that is still starting must not lose its folder), so they are made old.
    old = time.time() - 3600
    dead = temporary / folders[0]
    os.utime(dead, (old, old))
    live = temporary / "agentica-bdd-0123456789abcdef"
    live.mkdir()
    outside = directory / "outside"
    outside.mkdir()
    (outside / "lock").write_text("keep")
    os.symlink(outside, temporary / "agentica-bdd-fedcba9876543210", target_is_directory=True)
    (temporary / "agentica-bdd-00ff").mkdir()
    import msvcrt
    with open(live / "lock", "w+b") as held:
        msvcrt.locking(held.fileno(), msvcrt.LK_NBLCK, 1)
        os.utime(live, (old, old))
        try:
            run(cli() + ["test", directory / "missing.feature"], env=env)
        finally:
            held.seek(0)
            msvcrt.locking(held.fileno(), msvcrt.LK_UNLCK, 1)
    assert sorted(os.listdir(temporary)) == [
        "agentica-bdd-00ff", "agentica-bdd-0123456789abcdef", "agentica-bdd-fedcba9876543210"]
    assert (outside / "lock").read_text() == "keep"


# The POSIX cases put a #!/bin/sh script in place of the binary that the driver starts again. The VM starts only .exe
# and .com files on Windows, so the stand-in is a copy of node.exe (which needs nothing beside it) and a preloaded
# script: it prints the given stderr lines and ends with status 3 when it is asked to run the runner, and starts the
# real binary for anything else.
FAKE_BINARY_SCRIPT = """\
const fs = require('fs');
const {{ spawnSync }} = require('child_process');
// node makes the first word a path (the script it would run); only its last part is the word that was given.
const words = [require('path').basename(process.argv[1])].concat(process.argv.slice(2));
if (words.join(' ').includes('runner.agcb')) {{
  fs.writeSync(2, {lines}.join('\\n') + '\\n');
  process.exit(3);
}}
const real = spawnSync({real}, words, {{ stdio: 'inherit' }});
process.exit(real.status === null ? 1 : real.status);
"""


def fake_binary(directory, lines):
    """The path of the stand-in binary and the environment that makes it one."""
    fake = directory / "agentica-fake.exe"
    shutil.copy(tool("node"), fake)
    script = directory / "fake-runner.js"
    script.write_text(FAKE_BINARY_SCRIPT.format(lines=json.dumps(lines), real=json.dumps(str(binary()))),
                      encoding="utf-8")
    return fake, {"NODE_OPTIONS": '--require "%s"' % script.as_posix()}


def test_a_crashed_runner_is_reported_with_the_error_not_the_last_stack_frame(bdd):
    directory = bdd.suite({"a.feature": "Feature: A\nScenario: a\nThen 1 is fine\n"})
    fake, env = fake_binary(directory, [
        "runner.agc:2:13 error[RUNTIME-INDEX-OUT-OF-RANGE]",
        "index 5 is outside a list of length 3",
        "  = stack, innermost first:",
        "    main at runner.agc:11:8"])
    result = bdd.agentica_test("--json", directory / "a.feature", binary_path=fake, env=env)
    assert result.code == 2
    error = json.loads(result.stdout)["files"][0]["error"]
    assert error["code"] == "RUNTIME-BDD-INFRA"
    assert "RUNTIME-INDEX-OUT-OF-RANGE" in error["message"]


def test_the_infrastructure_message_names_the_runners_final_diagnostic_not_an_earlier_task_crash(bdd):
    directory = bdd.suite({"a.feature": "Feature: A\nScenario: a\nThen 1 is fine\n"})
    fake, env = fake_binary(directory, [
        "runner.agc:5:9 error[RUNTIME-DIVISION-BY-ZERO] in a task",
        "division by zero",
        "runner.agc:2:13 error[RUNTIME-INDEX-OUT-OF-RANGE]",
        "index 5 is outside a list of length 3",
        "  = stack, innermost first:"])
    result = bdd.agentica_test("--json", directory / "a.feature", binary_path=fake, env=env)
    assert result.code == 2
    message = file_error(json.loads(result.stdout))["message"]
    assert "RUNTIME-INDEX-OUT-OF-RANGE" in message
    assert "DIVISION-BY-ZERO" not in message


# The POSIX case makes the temporary folder read-only with chmod 0500. Windows has no mode bits: an entry that denies
# the user the right to add files and folders does the same, and holds for an owner and an administrator too.
def test_a_temporary_directory_that_cannot_be_written_is_an_infrastructure_error_that_names_it(bdd, request):
    scratch = bdd.make_suite({"nothing.txt": ""}, "agentica-bdd-readonly-")
    temporary = scratch / "tmp"
    temporary.mkdir()
    sid = "*" + current_user_sid()
    request.addfinalizer(lambda: icacls(temporary, "/remove:d", sid))
    icacls(temporary, "/deny", sid + ":(WD,AD)")
    result = bdd.agentica_test("--json", scratch / "missing.feature", env={"TMPDIR": temporary}, cwd=scratch)
    assert (result.code, result.stderr) == (2, "")
    problem = file_error(json.loads(result.stdout))
    assert problem["code"] == "RUNTIME-BDD-INFRA"
    assert ("cannot make a private directory in %s" % temporary) in problem["message"]
    # libuv maps ERROR_ACCESS_DENIED to EPERM, so the text is not "Permission denied" as it is for chmod.
    assert "Operation not permitted" in problem["message"]
    assert os.listdir(temporary) == []
