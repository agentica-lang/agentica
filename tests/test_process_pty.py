"""Process.spawn with pty: true and Process.resize through the CLI, against the Python peer (fixtures/process-peer.py).

The child runs on a pseudo-terminal: its stdin, stdout and stderr and its controlling terminal. A terminal echoes what
the program sends and ends lines with CRLF, which read_line strips.
"""
import json

import pytest

from tests.agentica_test import (FIXTURES, PYTHON, TARGET_OS, Pid, agc_literal, cli, host_only, kill_process,
                                 process_alive, run, vm_environment, wait_until)

PEER = FIXTURES / "process-peer.py"
NO_PTY = TARGET_OS not in ("linux", "darwin")


def run_program(tmp_path, body, *flags):
    path = tmp_path / "program.agc"
    path.write_text("def main() -> Void\n%s\nend\n" % body, encoding="utf-8")
    result = run(cli() + list(flags) + [str(path)], env=vm_environment(None))
    assert (result.code, result.stderr) == (0, "")
    return result.stdout.splitlines()


def pty_child(mode, timeout_ms=5000):
    return ('  p = Process.spawn(%s, [%s, "%s"], Process.Options(timeout_ms: %d, pty: true)).unwrap!\n'
            % (agc_literal(PYTHON), agc_literal(PEER), mode, timeout_ms))


@host_only(NO_PTY, "a pty is Linux and macOS only")
@pytest.mark.parametrize("schedulers", ["1", "4"])
def test_a_pty_child_has_a_controlling_terminal_of_24_by_80_and_no_other_descriptor(tmp_path, schedulers):
    # A child spawned beside it does not get the master either.
    lines = run_program(tmp_path, pty_child("tty") +
                        '  other = Process.spawn_captured(%s, [%s, "fds"]).unwrap!\n'
                        '  puts(Process.read_line(p, 5000).unwrap!)\n'
                        '  puts(Process.read_line(other, 5000).unwrap!)\n'
                        '  IO.inspect(Process.read_line(p, 5000))\n'
                        '  IO.inspect(Process.wait(p, 5000))' % (agc_literal(PYTHON), agc_literal(PEER)),
                        "--schedulers", schedulers)
    assert json.loads(lines[0]) == {"tty": [True, True, True], "size": [24, 80], "ctty": True, "fds": []}
    assert lines[1:] == ["[]", 'error("process: end of input", kind: "process.eof")', "ok(0)"]


@host_only(NO_PTY, "a pty is Linux and macOS only")
def test_a_resize_sends_sigwinch_and_stty_sees_the_new_size(tmp_path):
    lines = run_program(tmp_path, pty_child("winch") +
                        '  puts(Process.read_line(p, 5000).unwrap!)\n'
                        '  Process.resize(p, 40, 100).unwrap!\n'
                        '  Process.send(p, "go\\n", 5000).unwrap!\n'
                        '  3.times do |_|\n'
                        '    puts(Process.read_line(p, 5000).unwrap!)\n'
                        '  end')
    assert lines == ["ready", "go", "winch True", "40 100"]


@host_only(NO_PTY, "a pty is Linux and macOS only")
def test_a_password_read_with_echo_off_does_not_echo_it(tmp_path):
    lines = run_program(tmp_path, pty_child("password") +
                        '  IO.inspect(String.from_bytes(Process.read_bytes(p, 10, 5000).unwrap!).unwrap!)\n'
                        '  Process.send(p, "s3cret\\n", 5000).unwrap!\n'
                        '  IO.inspect(Process.read_line(p, 5000))\n'
                        '  IO.inspect(Process.read_line(p, 5000))\n'
                        '  IO.inspect(Process.read_line(p, 5000))')
    assert lines == ['"password: "', 'ok("")', 'ok("got s3cret")',
                     'error("process: end of input", kind: "process.eof")']


@host_only(NO_PTY, "a pty is Linux and macOS only")
def test_a_read_of_a_silent_pty_times_out_and_close_stops_the_whole_group(tmp_path):
    lines = run_program(tmp_path, '  p = Process.spawn(%s, [%s, "family"], Process.Options(pty: true)).unwrap!\n'
                                  '  puts(Process.read_line(p, 5000).unwrap!)\n'
                                  '  IO.inspect(Process.read_line(p, 200))' % (agc_literal(PYTHON), agc_literal(PEER)))
    assert lines[1] == 'error("process: operation timed out", kind: "process.timeout")'
    pid = Pid(lines[0])
    try:
        assert wait_until(lambda: not process_alive(pid))
    finally:
        kill_process(pid)


def test_pty_errors(tmp_path):
    body = ('  IO.inspect(Process.spawn_captured(%s, ["-c", ""], Process.Options(pty: true)))\n'
            '  IO.inspect(Process.spawn(%s, ["-c", ""], Process.Options(pty: true, out: "x.txt")))\n'
            '  q = Process.spawn_captured(%s, ["-c", "input()"]).unwrap!\n'
            '  IO.inspect(Process.resize(q, 10, 10))\n'
            '  IO.inspect(Process.resize(q, 0, 10))\n'
            '  Process.close(q)\n'
            '  IO.inspect(Process.resize(q, 10, 10))' % ((agc_literal(PYTHON),) * 3))
    lines = run_program(tmp_path, body)
    refused = 'error("process: pty needs Process.spawn without out and err", kind: "argument")'
    assert lines == [refused, refused, 'error("process: the child has no pty", kind: "process.failed")',
                     'error("process: rows and cols must be 1..65535", kind: "argument")',
                     'error("process: process is closed", kind: "process.closed")']
    if NO_PTY:
        lines = run_program(tmp_path, '  IO.inspect(Process.spawn(%s, [], Process.Options(pty: true)))'
                            % agc_literal(PYTHON))
        assert lines == ['error("process: pty is not supported on this system", kind: "process.failed")']
