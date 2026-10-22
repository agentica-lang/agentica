"""Shard 8 of the VM golden tests: `agentica run`, the product CLI and the cases that need more than a fixture.

The programs are compiled with the product CLI and run with `agentica
run` directly, or through the CLI where the test is about the CLI. The runs have the scratch folder of the test as
working directory.
"""
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time

import pytest

from tests.agentica_test import (FIFO_FILE_REASON, RUN_TIMEOUT, TESTS, UNDER_WINE, WINDOWS, Child, cli, compile_agc,
                                 host_only, kill_process, process_alive, scaled, vm_binary, vm_command, vm_environment,
                                 wait_until)
from tests.vm_diff_support import (
    EXTRAS_SHARD, FIXTURE_DIR, HEAVY_FIXTURES, LIGHT_SHARD_ROTATION, RUNAWAY_LIMIT, SHARD_COUNT, Fixture,
    check_limited, check_runaway, check_steps, check_sweep, check_text_format, decode, exit_status, execute,
    fixture_programs,
    json_crash_free, last_limit, outcome, read_expected, read_expected_steps, run_fixture_vm, run_vm,
    run_vm_process, runaway_programs, step_allowance, step_limited, style_options, text_code, text_crash_free,
    total_steps, shard_assignment)


def posix_only(why):
    """A case about a capability that Windows lacks (POSIX signals, descriptor numbers, shell scripts); the reason names
    what the Windows counterpart checks."""
    return pytest.mark.skipif(os.name != "posix", reason="host-only: " + why)


def windows_gap(number, why):
    """A case whose behavior exists on Windows but whose test needs /bin/sh, a POSIX signal or a FIFO: an open issue."""
    return pytest.mark.skipif(os.name != "posix", reason="known-issue: #%d %s" % (number, why))


PLAIN = Fixture()


@pytest.fixture(scope="module", autouse=True)
def _warmup():
    vm_binary()




def words(text):
    """The non-empty lines of a text, without the newlines at the ends."""
    return text.strip("\n").split("\n") if text.strip("\n") else []


def gone(pid):
    return wait_until(lambda: not process_alive(pid), scaled(5))


def kill_alive(pids):
    for pid in pids:
        kill_process(pid)


def compile_program(work, name, text):
    """Write a program into the scratch folder and compile it; returns the bytecode path."""
    source = work / (name + ".agc")
    source.write_text(text, encoding="utf-8")
    return compile_agc(source, work / (name + ".agcb"))


def fixture_bytecode(work, name):
    return compile_agc(FIXTURE_DIR / (name + ".agc"), work / (name + ".agcb"))


def vm(work, *argv, timeout=RUN_TIMEOUT):
    """`agentica run` with the given words (options, "--", file, arguments) and nothing else."""
    return execute([*vm_command(), *argv], cwd=work, env=vm_environment(), timeout=timeout)


def test_shard_tables_name_real_fixtures_and_shards():
    names = [program.name for program, _shard in shard_assignment(fixture_programs())]
    for heavy, shard in HEAVY_FIXTURES.items():
        assert heavy in names
        assert 1 <= shard <= SHARD_COUNT, heavy
    for shard in LIGHT_SHARD_ROTATION:
        assert 1 <= shard <= SHARD_COUNT, "light shard %d" % shard
    for shard in range(1, SHARD_COUNT + 1):
        module = TESTS / ("test_vm_diff_%d.py" % shard)
        assert module.is_file(), str(module)
        if shard != EXTRAS_SHARD:
            assert ("SHARD = %d" % shard) in module.read_text(encoding="utf-8"), str(module)


@pytest.mark.parametrize("name", ["imports", "io-gets", "enums-case"])
def test_compile_gives_the_same_bytes_every_time(tmp_path, name):
    program = FIXTURE_DIR / (name + ".agc")
    first = compile_agc(program, tmp_path / (name + "-one.agcb"))
    second = compile_agc(program, tmp_path / (name + "-two.agcb"))
    assert first.read_bytes() == second.read_bytes()


@pytest.mark.parametrize("name", ["io-read", "io-rest"])
def test_the_vm_reads_piped_stdin_like_the_file_redirect(tmp_path, name):
    program = FIXTURE_DIR / (name + ".agc")
    fixture = Fixture(input=(FIXTURE_DIR / (name + ".stdin")).read_bytes())
    bytecode = compile_agc(program, tmp_path / (name + "-pipe.agcb"))
    assert outcome(run_vm(fixture, bytecode, None, cwd=tmp_path)) == read_expected(program)


@pytest.mark.parametrize("program", runaway_programs(), ids=lambda program: program.stem)
def test_runaway_loops_stop_at_max_steps_with_a_prefix_of_their_expected_output(tmp_path, program):
    check_runaway(program, tmp_path)


@pytest.mark.parametrize("options", [["--max-steps", "0"], ["--bogus"], ["--ai", "--ai"],
                                       ["--max-steps", "5", "--max-steps", "5"],
                                       ["--seed", "1", "--seed", "1"]])
def test_the_vm_command_line_rejects_bad_options(tmp_path, options):
    bytecode = str(fixture_bytecode(tmp_path, "calls"))
    assert vm(tmp_path, *options, "--", bytecode)[0] == 2


@pytest.mark.parametrize("seed", ["-1", "2147483648", "1x", "", "99999999999999999999"])
def test_the_vm_command_line_rejects_a_bad_seed(tmp_path, seed):
    bytecode = str(fixture_bytecode(tmp_path, "calls"))
    rejected = vm(tmp_path, "--seed", seed, "--", bytecode)
    assert rejected[0] == 2
    assert rejected[2] == "agentica run: --seed needs an integer from 0 to 2147483647\n"


def test_the_vm_command_line_checks_options_and_stops_parsing_at_the_file(tmp_path):
    bytecode = str(fixture_bytecode(tmp_path, "calls"))
    assert run_vm(PLAIN, bytecode, None, extra=["--max-steps", "1"], cwd=tmp_path)[0] == 0
    draws = compile_program(
        tmp_path, "random-draws", "def main() -> Void\n  puts(Random.int(0, 1000000000))\n  puts(Random.float)\nend\n")

    def seeded(seed):
        return vm(tmp_path, "--seed", seed, "--", str(draws))

    assert seeded("0002147483647")[0] == 0
    assert seeded("7") == seeded("7")
    assert seeded("7")[1] != seeded("8")[1]


@pytest.mark.skipif(UNDER_WINE, reason="Wine runs the Windows binary, which a Linux peer cannot give two pipes")
def test_tests_draw_the_same_values_alone_or_with_others(tmp_path):
    tests = compile_program(
        tmp_path, "seeded-tests",
        "def main() -> Void\n  Test.run([\n"
        "    Test.test(\"a\") do\n      puts(Random.int(0, 1000000000))\n      ok()\n    end,\n"
        "    Test.test(\"b\") do\n      puts(Random.int(0, 1000000000))\n      ok()\n    end\n"
        "  ])\nend\n")

    def test_draws(seed, order, label):
        feed = tmp_path / ("seeded-%s.channel" % label)
        feed.write_bytes(order)
        run = run_vm_process(Fixture(channel=feed), ["--seed", seed], tests, ["--agentica-test", "run"],
                             cwd=tmp_path)
        assert run[0] == 0, run[2]
        return [line for line in words(run[1]) if not line.startswith("channel> ")]

    alone = test_draws("7", b"1\n", "alone")
    mixed = test_draws("7", b"0\n1\n1\n", "mixed")
    assert [mixed[1], mixed[2]] == [alone[0], alone[0]]
    assert mixed[0] != mixed[1]
    assert test_draws("8", b"1\n", "other") != alone


def test_a_duplicate_test_name_is_reported_at_its_source(tmp_path):
    duplicate = fixture_bytecode(tmp_path, "test-name-duplicate")
    named = vm(tmp_path, "--json", "--", str(duplicate), "--agentica-test", "run")
    start = json.loads(named[2])["range"]["start"]
    assert (named[0], start["line"], start["column"]) == (1, 9, 5)


def test_the_vm_options_after_the_file_belong_to_the_program(tmp_path):
    bytecode = str(fixture_bytecode(tmp_path, "calls"))
    limited = vm(tmp_path, "--max-steps", "1", "--ai", "--json", "--", bytecode)
    assert limited[0] == 1
    assert json.loads(limited[2])["code"] == "RUNTIME-STEP-LIMIT"
    assert vm(tmp_path, "--json", "--", bytecode, "--ai")[2] == ""


def test_a_bytecode_file_may_have_a_non_ascii_name_and_a_bad_one_is_rejected(tmp_path):
    bytecode = fixture_bytecode(tmp_path, "calls")
    unicode_name = tmp_path / "cálculo-λ-日本-𝔸.agcb"
    shutil.copy(bytecode, unicode_name)
    assert run_vm(PLAIN, unicode_name, None, cwd=tmp_path) == run_vm(PLAIN, bytecode, None, cwd=tmp_path)
    assert vm(tmp_path, "--", str(tmp_path))[0] == 2
    bad = tmp_path / "bad.agcb"
    bad.write_bytes(b"AGCB")
    rejected = vm(tmp_path, "--", str(bad))
    assert rejected[0] == 2
    assert rejected[2].startswith("agentica run: invalid bytecode: "), rejected[2]


@host_only(WINDOWS, "chmod 600 and 644 and a symbolic link decide what is private; Windows has an access list for the owner only (test_the_hidden_driver_pid_flag_loads_only_a_private_input_and_then_deletes_it in test_windows_process_cleanup.py checks it)")
def test_the_hidden_driver_pid_flag_loads_only_a_private_input_and_then_deletes_it(tmp_path):
    bytecode = fixture_bytecode(tmp_path, "calls")
    copy = tmp_path / "driver-copy.agcb"

    def driven(pid, path=copy):
        return vm(tmp_path, "--driver-pid", str(pid), "--", str(path))

    shutil.copy(bytecode, copy)
    copy.chmod(0o600)
    assert driven(os.getpid()) == run_vm(PLAIN, bytecode, None, cwd=tmp_path)
    assert not copy.exists()
    shutil.copy(bytecode, copy)
    copy.chmod(0o644)
    assert driven(os.getpid())[0] == 2
    assert copy.exists()
    copy.chmod(0o600)
    assert driven(os.getpid() + 1)[0] == 2
    assert copy.exists()
    link = tmp_path / "driver-link.agcb"
    os.symlink(copy, link)
    assert driven(os.getpid(), link)[0] == 2
    assert copy.exists()


@posix_only("a read of a FIFO that times out; " + FIFO_FILE_REASON)
def test_a_read_stuck_on_a_fifo_times_out_closes_the_handle_and_does_not_hold_the_vm_at_exit(tmp_path):
    bytecode = compile_program(
        tmp_path, "fifo-stuck",
        "def main() -> Void\n  input = Result.unwrap!(File.open(System.args()[0], \"read\", 60000))\n"
        "  IO.inspect(File.read_bytes(input, 4, 300))\n  IO.inspect(File.read_line(input, 300))\n"
        "  IO.inspect(File.close(input, 300))\n  puts(\"done\")\nend\n")
    fifo = tmp_path / "stuck-fifo"
    os.mkfifo(fifo)
    # Held open for reading and writing, so the VM's read blocks instead of ending at once.
    held = os.open(fifo, os.O_RDWR)
    try:
        started = time.monotonic()
        result = run_vm(Fixture(args=(str(fifo),)), bytecode, None, cwd=tmp_path)
        assert outcome(result)[:3] == (
            0, "error(\"filesystem: operation timed out\")\nerror(\"filesystem: file handle is closed\")\nok()\n"
            "done\n", "")
        assert time.monotonic() - started < scaled(20)
    finally:
        os.close(held)


@posix_only("#!/bin/sh scripts found through a colon separated PATH; Windows has no #! scripts (test_process.py searches PATH with a copy of node.exe)")
def test_process_spawn_searches_path_only_and_resolves_a_name_with_a_slash_against_the_working_directory(tmp_path):
    bytecode = compile_program(
        tmp_path, "path-lookup",
        "def show(name: String) -> Void\n  case Process.spawn(name, [\"x\"], 60000)\n"
        "    ok(p) ->\n"
        "      puts(\"#{name}: #{Process.read_line(p, 60000)} #{Process.wait(p, 60000)}\")\n"
        "      Process.close(p)\n    error(message) -> puts(\"#{name}: #{message}\")\n  end\nend\n\n"
        "def main() -> Void\n  show(\"agc-tool\")\n  show(\"./agc-tool\")\n  show(\"bin/agc-tool\")\n"
        "  show(\"bin\")\nend\n")
    folder = tmp_path / "lookup"
    (folder / "bin").mkdir(parents=True)
    for tool in [folder / "agc-tool", folder / "bin" / "agc-tool"]:
        tool.write_text("#!/bin/sh\necho \"ran $1\"\n", encoding="utf-8")
        tool.chmod(0o755)

    def expected(found):
        return (0, "agc-tool: " + ("ok(\"ran x\") ok(0)" if found else "process: executable is unavailable")
                + "\n./agc-tool: ok(\"ran x\") ok(0)\nbin/agc-tool: ok(\"ran x\") ok(0)\n"
                + "bin: process: executable is unavailable\n", "")

    none = str(folder / "none")
    for search in [none, ":" + none, "bin:" + none, ".:" + none]:
        want = expected(search.startswith("bin:") or search.startswith(".:"))
        assert run_vm(PLAIN, bytecode, None, cwd=folder, env={"PATH": search}) == want, search


@posix_only("SIGTERM; Windows has Ctrl+Break, which test_windows_console_stop.py sends to end the VM, its child and the buffered file")
def test_a_program_that_is_stopped_by_sigterm_kills_the_vms_running_children(adopt, request, tmp_path):
    program = tmp_path / "signal-children.agc"
    program.write_text(
        "def main() -> Void\n  p = Result.unwrap!(Process.spawn(\"/bin/sh\", [\"-c\", \"echo $$; exec sleep 30\"], "
        "60000))\n  puts(Result.unwrap!(Process.read_line(p, 60000)))\n  IO.flush()\n  Task.sleep(20000)\nend\n",
        encoding="utf-8")
    driver = adopt(Child(
        cli() + [program], env=vm_environment({"TMPDIR": tmp_path}),
        cwd=tmp_path, capture_stderr=True))
    pid = driver.next_line(RUN_TIMEOUT)
    request.addfinalizer(lambda: kill_alive([pid]))
    assert process_alive(pid)
    os.kill(driver.process.pid, signal.SIGTERM)
    driver.wait(RUN_TIMEOUT)
    assert gone(pid), pid


@host_only(WINDOWS, "/bin/sh and SIGTERM, which lets a VM child stop its own children; Windows ends the child with TerminateProcess and its job object ends the rest (test_closing_a_captured_vm_child_ends_the_child_and_its_own_child in test_windows_process_cleanup.py checks the tree)")
def test_closing_a_captured_vm_child_sends_sigterm_first_so_the_child_stops_its_own_children(request, tmp_path):
    inner = compile_program(
        tmp_path, "captured-inner",
        "def main() -> Void\n"
        "  p = Result.unwrap!(Process.spawn(\"/bin/sh\", [\"-c\", \"echo $PPID $$; exec sleep 30\"], 60000))\n"
        "  puts(Result.unwrap!(Process.read_line(p, 60000)))\n  IO.flush()\n  Task.sleep(5000)\nend\n")
    outer = compile_program(
        tmp_path, "captured-outer",
        "def main() -> Void\n  args = System.args()\n"
        "  child = Result.unwrap!(Process.spawn_captured(args[0], [\"run\", \"--\", args[1]], \".\", "
        "60000))\n  puts(Result.unwrap!(Process.read_line(child, 60000)))\n"
        "  if args[2] == \"close\"\n    Process.close(child)\n  else\n    IO.inspect(Process.read_line(child, 200))\n"
        "  end\nend\n")
    for mode in ["close", "timeout"]:
        pids = []
        request.addfinalizer(lambda found=pids: kill_alive(found))
        result = run_vm(PLAIN, outer, None, extra=[str(vm_binary()), str(inner), mode], cwd=tmp_path)
        lines = words(result[1])
        pids.extend(word for word in (lines[0].split() if lines else []) if word.isdigit())
        assert result[0] == 0, mode
        assert lines[1:] == ([] if mode == "close" else ['error("network: operation timed out")']), mode
        assert len(pids) == 2, mode
        for pid in pids:
            assert gone(pid), "%s: %s" % (mode, pid)


@host_only(WINDOWS, "a shell that traps SIGTERM and the SIGKILL a second later; Windows has only TerminateProcess (test_close_never_waits_for_a_captured_child_and_one_that_ignores_the_console_signals_is_killed in test_windows_process_cleanup.py checks the close)")
def test_close_never_waits_for_a_captured_child_and_one_that_ignores_sigterm_gets_sigkill_a_second_later(
        request, tmp_path):
    bytecode = compile_program(
        tmp_path, "captured-grace",
        "def main() -> Void\n  mode = System.args()[0]\n"
        "  script = \"trap '' TERM; echo $$; exec sleep 30\"\n  if mode == \"quick\"\n"
        "    script = \"echo $$; exec sleep 30\"\n  end\n"
        "  p = Result.unwrap!(Process.spawn_captured(\"/bin/sh\", [\"-c\", script], \".\", 60000))\n"
        "  pid = Result.unwrap!(Process.read_line(p, 60000))\n  puts(pid)\n  IO.flush()\n"
        "  start = Time.monotonic_ms()\n  Process.close(p)\n  puts(Time.monotonic_ms() - start)\n"
        "  if mode == \"wait\"\n    Task.sleep(1500)\n"
        "    probe = Result.unwrap!(Process.spawn(\"/bin/sh\", [\"-c\", \"kill -0 #{pid} 2>/dev/null\"], 60000))\n"
        "    puts(Result.unwrap!(Process.wait(probe, 60000)) == 0)\n    Process.close(probe)\n  end\nend\n")
    traced = "trace off" not in vm(tmp_path, "--version")[1]
    for mode in ["wait", "exit", "quick"]:
        pids = []
        request.addfinalizer(lambda found=pids: kill_alive(found))
        result = run_vm(PLAIN, bytecode, None, extra=[mode], cwd=tmp_path, env={"AGENTICA_VM_TRACE": "io"})
        lines = words(result[1])
        if lines and lines[0].isdigit():
            pids.append(lines[0])
        assert result[0] == 0, mode
        assert len(pids) == 1, mode
        assert len(lines) >= 2 and int(lines[1]) < 500, "%s: %s" % (mode, lines)
        assert lines[2:] == (["false"] if mode == "wait" else []), mode
        assert gone(pids[0]), mode
        if traced:
            assert re.search(r" io end code=0 signal=0", result[2]), mode


# The child writes the byte 0xFF to stderr at once and "hi\n" to stdout a second later. Windows has no /bin/sh: a Python
# child writes the same bytes (without the newline translation of its text streams).
SHELL_OUTPUT_CHILD = ["/bin/sh", "-c", "printf '\\377' >&2; sleep 1; echo hi"]
PYTHON_OUTPUT_CHILD = [sys.executable, "-c", "import sys,time;sys.stderr.buffer.write(bytes([255]));sys.stderr.flush();"
                       "time.sleep(1);sys.stdout.buffer.write(b'hi\\n');sys.stdout.flush()"]


@pytest.mark.skipif(UNDER_WINE, reason="Wine runs the Windows binary, which starts neither /bin/sh nor a Linux Python")
def test_an_output_timeout_keeps_the_captured_child_and_output_decodes_invalid_utf8_as_ufffd(tmp_path):
    bytecode = compile_program(
        tmp_path, "captured-output",
        "def main() -> Void\n  args = System.args()\n"
        "  p = Result.unwrap!(Process.spawn_captured(args[0], [args[1], args[2]], \".\", 60000))\n"
        "  IO.inspect(Process.output(p, 50))\n  out = Result.unwrap!(Process.output(p, 60000))\n"
        "  puts(\"#{out.stdout.inspect} #{out.stderr.length} #{String.code(out.stderr)} #{out.truncated}\")\n"
        "  Process.close(p)\nend\n")
    child = PYTHON_OUTPUT_CHILD if os.name == "nt" else SHELL_OUTPUT_CHILD
    assert run_vm(PLAIN, bytecode, None, extra=child, cwd=tmp_path) == \
        (0, "error(\"network: operation timed out\")\n\"hi\\n\" 1 65533 false\n", "")


@pytest.mark.skipif(UNDER_WINE, reason="Wine runs the Windows binary: no /bin/sh child, no console to break")
def test_a_signal_caught_while_the_vm_is_blocked_is_not_lost_when_the_last_child_exits_first(adopt, request, tmp_path):
    # The child prints its pid and sleeps. Windows has no /bin/sh, so a Python child (an argument of the program) does
    # the same, and the stop is the Ctrl+Break of the stop tests of Windows, which only a new process group can take.
    windows = os.name == "nt"
    spawn = ('Process.spawn(System.args()[0], ["-c", System.args()[1]], 60000)' if windows else
             'Process.spawn("/bin/sh", ["-c", "echo $$; exec sleep 30"], 60000)')
    bytecode = compile_program(
        tmp_path, "signal-pending",
        "def main() -> Void\n  p = Result.unwrap!(" + spawn + ")\n"
        "  puts(Result.unwrap!(Process.read_line(p, 60000)))\n  IO.flush()\n"
        "  puts(String.join(List.repeat(\"x\", 1048576), \"\"))\n  puts(\"survived\")\nend\n")
    arguments = [sys.executable, "import os,time;print(os.getpid(),flush=True);time.sleep(30)"] if windows else []
    # Nothing reads the VM's stdout after the first line, so its 1 MiB write blocks: the state under test.
    child = adopt(Child([*vm_command(), "--", bytecode, *arguments], env=vm_environment(),
                        cwd=tmp_path, read_stdout=False,
                        creationflags=subprocess.CREATE_NEW_PROCESS_GROUP if windows else 0))
    pid = child.process.stdout.readline().decode().strip()
    assert pid.isdigit(), pid
    request.addfinalizer(lambda: kill_alive([pid]))
    time.sleep(0.5)
    kill_process(pid)
    time.sleep(0.3)
    if windows:
        child.process.send_signal(signal.CTRL_BREAK_EVENT)
    else:
        os.kill(child.process.pid, signal.SIGTERM)
    threading.Thread(target=child.process.stdout.read, daemon=True).start()
    assert exit_status(child.wait(RUN_TIMEOUT)) == 128 + (signal.SIGBREAK if windows else signal.SIGTERM)


@posix_only("descriptors inherited by number; Windows inherits handles, which vm/tests/process_test.c checks (a child does not get an inheritable handle of the parent)")
def test_a_child_does_not_inherit_descriptors_the_vm_inherited(tmp_path):
    bytecode = compile_program(
        tmp_path, "private-fds",
        "def main() -> Void\n  p = Result.unwrap!(Process.spawn(\"/bin/sh\", [\"-c\", "
        "\"if [ -e /dev/fd/7 ]; then echo leaked; else echo private; fi\"], 60000))\n"
        "  puts(Result.unwrap!(Process.read_line(p, 60000)))\n  Process.close(p)\nend\n")
    result = execute(["/bin/sh", "-c", "exec 7</dev/null; exec \"$0\" run -- \"$1\"", vm_binary(), bytecode],
                     cwd=tmp_path, env=vm_environment())
    assert result == (0, "private\n", "")


@pytest.mark.skipif(
    not sys.platform.startswith("linux"),
    reason="host-only: needs a file system that accepts a folder name that is not valid UTF-8 (APFS and NTFS refuse it)")
def test_relative_file_paths_use_the_raw_bytes_of_a_non_utf8_working_directory(tmp_path):
    bytecode = compile_program(
        tmp_path, "raw-cwd",
        "def main() -> Void\n  IO.inspect(File.write_text(\"a.txt\", \"hi\", 60000))\n"
        "  IO.inspect(File.read_text(\"a.txt\", 60000))\nend\n")
    folder = tmp_path / os.fsdecode(b"raw-\xff")
    folder.mkdir()
    assert run_vm(PLAIN, bytecode, None, cwd=folder) == (0, "ok()\nok(\"hi\")\n", "")
    assert (folder / "a.txt").read_text(encoding="utf-8") == "hi"


@posix_only("passes arguments that are not valid UTF-8, which a Windows command line (UTF-16) cannot carry")
def test_the_vm_decodes_invalid_utf8_arguments_like_the_original_in_a_utf8_locale(tmp_path):
    program = FIXTURE_DIR / "system-args.agc"
    bytecode = compile_agc(program, tmp_path / "system-args.agcb")
    arguments = [b"\xff\xfeZ", b"\xe2\x82A", b"\xed\xa0\x80z", b"a\xe2\x82", b"\xf0\x9f\x98", b"\xe0\x80",
                 b"\xf0\x80\x80", b"\xed\xa0", b"\xf4\x90", b"\xc0\xaf", b"\xe2\x82\xe2\x82", b"\xe2\x82\xac"]
    environment = vm_environment({"LC_ALL": "C.UTF-8"})
    on_vm = execute([*vm_command(), "--", bytecode, *arguments], cwd=tmp_path, env=environment)
    on_cli = execute(cli() + [program, *arguments], cwd=tmp_path, env=environment)
    assert outcome(on_vm) == outcome(on_cli)


def test_deep_tail_calls_run_on_the_vm(tmp_path):
    bytecode = compile_program(
        tmp_path, "deep-tail",
        "def loop(n: Int, acc: Int) -> Int\n  if n == 0\n    return acc\n  end\n  return loop(n - 1, acc + 1)\nend\n\n"
        "def even(n: Int) -> Bool\n  if n == 0\n    return true\n  end\n  return odd(n - 1)\nend\n\n"
        "def odd(n: Int) -> Bool\n  if n == 0\n    return false\n  end\n  return even(n - 1)\nend\n\n"
        "def main() -> Void\n  puts(loop(1000000, 0))\n  puts(even(1000001))\nend\n")
    assert run_vm(PLAIN, bytecode, None, cwd=tmp_path) == (0, "1000000\nfalse\n", "")


def test_a_due_timer_fires_while_another_task_keeps_the_run_queue_busy(tmp_path):
    # main yields until the sleeper sets the flag, so the run queue is never empty and the idle step never runs: only
    # the timer check at the turn boundary wakes the sleeper. Without it the run hangs until the time limit.
    bytecode = compile_program(
        tmp_path, "busy-sleeper",
        "def flagger(flag: Channel[Int]) -> Int\n  Task.sleep(20)\n  flag.send(1, 0).unwrap!\n  return 7\nend\n\n"
        "def main() -> Void\n  flag: Channel[Int] = Channel.new(1)\n  t = Task.spawn(&flagger, flag)\n"
        "  while !flag.recv(0).ok?\n    Task.sleep(0)\n  end\n  puts(Task.await(t))\nend\n")
    assert run_vm(PLAIN, bytecode, None, cwd=tmp_path, timeout=scaled(20)) == (0, "7\n", "")


def test_string_at_and_slice_over_a_long_non_ascii_string_on_the_vm(tmp_path):
    bytecode = compile_program(
        tmp_path, "string-cursor",
        "def main() -> Void\n  s = \"é😀\"\n  i = 0\n  while i < 15\n    s = s + s\n    i += 1\n  end\n"
        "  n = s.length\n  total = 0\n  j = 0\n  while j < n\n    total += s.at(j).code\n    j += 1\n  end\n"
        "  j = n - 1\n  while j >= 0\n    total += s.slice(j, 1).code\n    j -= 1\n  end\n"
        "  puts(\"#{n} #{total}\")\nend\n")
    assert run_vm(PLAIN, bytecode, None, cwd=tmp_path) == (0, "65536 %d\n" % (2 * 32768 * (233 + 128512)), "")


def test_large_generated_input_splits_and_decodes_lines_across_buffer_boundaries(tmp_path):
    bytecode = compile_program(
        tmp_path, "large-input",
        "def main() -> Void\n  count = 0\n  running = true\n  while running\n    case gets()\n"
        "      ok(line) -> puts(\"#{count}: #{line.inspect}\")\n"
        "      error(message) ->\n        puts(message)\n        running = false\n    end\n"
        "    count = count + 1\n  end\n  puts(count)\nend\n")
    data = (b"a" * 65535 + b"\xe2\x82\xac\n" + b"b" * 65535 + b"\r\n" + b"c" * 65535 + b"\rnext\n"
            + b"d" * 65534 + b"\xf0\x9f\x98\x80\xff\xe2\x82\n"
            + b"".join(b"line %d\r\n" % k for k in range(20000)) + b"tail \xe2\x82")
    lines = re.split(rb"\r\n|\r|\n", data)
    stdout = "".join('%d: "%s"\n' % (k, decode(line)) for k, line in enumerate(lines))
    stdout += "IO.gets reached the end of input\n%d\n" % (len(lines) + 1)
    fixture = Fixture(input=data)
    full = (0, stdout, "", None)
    assert outcome(run_vm(fixture, bytecode, None, cwd=tmp_path)) == full, "large input"
    for limit in [1, 50, 100000, 400000]:
        check_limited(run_vm(fixture, bytecode, limit, cwd=tmp_path), full, "large input", limit)


def test_a_crlf_program_under_a_non_ascii_path_gives_the_expected_outcome(tmp_path):
    folder = tmp_path / "dír-λ-𝔸"
    folder.mkdir()
    program = folder / "división-日本.agc"
    original = FIXTURE_DIR / "division-by-zero.agc"
    program.write_bytes(original.read_text(encoding="utf-8").replace("\n", "\r\n").encode("utf-8"))
    bytecode = compile_agc(program, tmp_path / "division-by-zero.agcb")
    full = read_expected(original)
    assert full[3] == "RUNTIME-DIVISION-BY-ZERO"
    for style in ["plain", "ai", "json"]:
        on_vm = run_vm(PLAIN, bytecode, None, style=style, cwd=tmp_path)
        if style == "json":
            assert outcome(on_vm) == full, style
        else:
            check_text_format(on_vm, full, style)
    total = total_steps(lambda limit: step_limited(run_fixture_vm(PLAIN, bytecode, limit, tmp_path)))
    expected_steps = read_expected_steps(original)
    check_steps(total, expected_steps, "CRLF program")
    limits = [1, total - 1, total, last_limit(expected_steps)]
    check_sweep([run_vm(PLAIN, bytecode, limit, cwd=tmp_path) for limit in limits], limits, full, "CRLF program")


# Helpers to run the product CLI with a folder that must stay empty as its temporary directory.


def cli_temp(tmp_path):
    temp = tmp_path / "agentica-cli-temp"
    temp.mkdir()
    return temp.resolve()


def agentica(temp, work, *argv, stdin=b"", env=None):
    """The CLI with TMPDIR set to the folder that must stay empty."""
    environment = vm_environment({"TMPDIR": temp, **(env or {})})
    return execute(cli() + list(argv), stdin=stdin, cwd=work, env=environment)


def cli_fixture(name):
    return str(FIXTURE_DIR / name)


def cli_expected(name):
    return read_expected(FIXTURE_DIR / name)


def no_bytecode(temp, arguments):
    assert [path.name for path in temp.glob("*.agcb")] == [], "%s leaves no bytecode" % arguments


# The product CLI runs programs on the VM with their expected exit code, stdout and diagnostic code.


def test_the_formats_exit_codes_and_diagnostics_of_a_run(tmp_path):
    temp = cli_temp(tmp_path)
    for name in ["calls.agc", "division-by-zero.agc", "linked.agc"]:
        for style in ["plain", "ai", "json"]:
            arguments = style_options(style) + [cli_fixture(name)]
            result = agentica(temp, tmp_path, *arguments)
            if style == "json":
                assert outcome(result) == cli_expected(name), str(arguments)
            else:
                check_text_format(result, cli_expected(name), str(arguments))
            no_bytecode(temp, arguments)
            if name == "linked.agc":
                assert result[0] == 1


def test_options_arguments_and_removed_flags(tmp_path):
    temp = cli_temp(tmp_path)
    calls = cli_fixture("calls.agc")
    limited = agentica(temp, tmp_path, "--json", "--max-steps", "3", calls)
    assert (limited[0], outcome(limited)[3]) == (1, "RUNTIME-STEP-LIMIT")
    no_bytecode(temp, "--max-steps 3")
    with_args = agentica(temp, tmp_path, "--json", calls, "first", "--deny-run", "--json")
    assert with_args[:2] == cli_expected("calls.agc")[:2]
    deep = tmp_path / "deep.agc"
    deep.write_text(
        "def loop(n: Int, acc: Int) -> Int\n  if n == 0\n    return acc\n  end\n  return loop(n - 1, acc + 1)\nend\n\n"
        "def main() -> Void\n  puts(loop(100000, 0))\nend\n", encoding="utf-8")
    assert agentica(temp, tmp_path, str(deep)) == (0, "100000\n", "")
    for removed in ["--vm", "--legacy-eval"]:
        assert agentica(temp, tmp_path, removed, str(deep))[:2] == (1, ""), removed
    denied = cli_fixture("spawn-denied.agc")
    assert outcome(agentica(temp, tmp_path, "--deny-run", "--json", denied)) == cli_expected("spawn-denied.agc")
    assert agentica(temp, tmp_path, "--json", denied)[0] == 0
    random = cli_fixture("random.agc")
    seeded = agentica(temp, tmp_path, "--seed", "77", random)
    assert seeded[0] == 0
    assert agentica(temp, tmp_path, "--seed", "77", random) == seeded
    assert agentica(temp, tmp_path, "--seed", "2147483648", random)[0] == 2
    assert agentica(temp, tmp_path, "--max-steps", "0", calls)[0] == 2


def test_standard_input_exit_codes_and_arguments_reach_the_program(tmp_path):
    temp = cli_temp(tmp_path)
    gets = cli_fixture("io-gets.agc")
    data = (FIXTURE_DIR / "io-gets.stdin").read_bytes()
    assert outcome(agentica(temp, tmp_path, "--json", gets, stdin=data)) == cli_expected("io-gets.agc")
    assert agentica(temp, tmp_path, cli_fixture("system-exit.agc"))[0] == 3
    assert agentica(temp, tmp_path, "--json", cli_fixture("system-args.agc"), "a", "", "λ 𝔸", "--json", "--vm") == \
        (0, "0 \"a\"\n1 \"\"\n2 \"λ 𝔸\"\n3 \"--json\"\n4 \"--vm\"\n[\"a\", \"\", \"λ 𝔸\", \"--json\", \"--vm\"]\n", "")
    assert list(temp.iterdir()) == []


def test_compile_exits_1_on_a_diagnostic_and_2_on_an_unwritable_output(tmp_path):
    temp = cli_temp(tmp_path)
    work = tmp_path
    rejected_file = work / "file.agc"
    rejected_file.write_text("def main() -> Void\n  c = HTTP.client_options()\nend\n", encoding="utf-8")
    rejected = agentica(temp, work, "compile", rejected_file, "-o", work / "out.agcb")
    assert rejected[0] == 1
    assert "error[CHECK-UNKNOWN-NAME]" in rejected[2]
    assert not (work / "out.agcb").exists()
    supported = work / "hello.agc"
    supported.write_text("def main() -> Void\n  puts(\"hi\")\nend\n", encoding="utf-8")
    assert agentica(temp, work, "compile", supported, "-o", work / "missing" / "out.agcb")[0] == 2


# What the binary does with its own standard input and its environment.


@host_only(WINDOWS, "opens a directory as a descriptor to use as standard input, which Windows refuses")
def test_a_standard_input_that_cannot_be_read_is_an_internal_error(tmp_path):
    temp = cli_temp(tmp_path)
    gets = cli_fixture("io-gets.agc")
    # A directory opens for reading and fails on the first read.
    descriptor = os.open(tmp_path, os.O_RDONLY)
    try:
        process = subprocess.run(cli() + ["--json", gets], stdin=descriptor, capture_output=True,
                                 env=vm_environment({"TMPDIR": temp}), cwd=tmp_path,
                                 timeout=RUN_TIMEOUT)
    finally:
        os.close(descriptor)
    assert process.returncode == 1
    last = decode(process.stderr).strip().split("\n")[-1]
    assert json.loads(last)["code"] == "RUNTIME-INTERNAL"
    assert json.loads(last)["message"] == "cannot read standard input"


def test_agentica_vm_names_nothing_any_more(tmp_path):
    """The variable that named the VM is gone: a value that names no file changes nothing, for a run and for
    `agentica run`. (`agentica test` starts its runner as `agentica run` on itself, and tests/test_bdd.py runs it.)"""
    temp = cli_temp(tmp_path)
    calls = cli_fixture("calls.agc")
    compiled = tmp_path / "calls.agcb"
    assert agentica(temp, tmp_path, "compile", calls, "-o", str(compiled))[0] == 0
    for value in (str(temp / "no-vm"), "", "/bin/false"):
        assert agentica(temp, tmp_path, calls, env={"AGENTICA_VM": value}) == \
            agentica(temp, tmp_path, calls), value
        assert agentica(temp, tmp_path, "--json", cli_fixture("division-by-zero.agc"), env={"AGENTICA_VM": value}) == \
            agentica(temp, tmp_path, "--json", cli_fixture("division-by-zero.agc")), value
        assert agentica(temp, tmp_path, "run", "--", str(compiled), env={"AGENTICA_VM": value}) == \
            agentica(temp, tmp_path, "run", "--", str(compiled)), value
