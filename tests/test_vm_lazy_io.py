"""The I/O of Lazy: File.foreach and write_lines close their file on every exit path, and they round-trip.

The VM's io trace has a file_open and a file_close line for each file handle, on every platform, so the check needs
no /proc and runs on Windows too. tests/fixtures/vm/lazy-file.agc (also a VM golden) goes through each exit path of a
terminal in turn: the end, first and find stopping early, an error from the block, a failed try, a read error, a
crash and a cancel of the task. Each path opens one file at most, so no handle may still be open when the next one
opens. --max-steps ends the run with the file of the pipeline still open, and the end of the run closes it.

tests/fixtures/vm/lazy-write.agc (also a VM golden) does the same for write_lines, and a round trip checks that
File.foreach reads back exactly the lines write_lines wrote, with the bytes Python writes for the same lines.
--max-steps in the middle of write_lines leaves lines in its buffer: the end of the run writes them and closes the file.

Two cases park the terminal itself on a file read, with a FIFO that tests/fixtures/lines-peer.py holds open: a cancel
(Task.map's timeout) and a read timeout. A third parks write_lines on a write to such a FIFO and cancels it. They need mkfifo and the peer's FIONREAD; on Windows they are skipped as
"known-issue:" (#433).
"""
import os
import random
import re

import pytest

from tests.agentica_test import (FIXTURES, WAIT_SECONDS, WINDOWS, compile_agc, compile_text, known_issue, run_vm,
                                 vm_environment)
from tests.test_vm_file_lines import start_fifo_peer

EVENT = re.compile(r" io file_(open|close) handle=([0-9]+)$")

STEP_LIMITED = """\
def main() -> Void
  r = File.foreach(System.args()[0], 1024, 60000).map do |line| line.length end.each do |n|
    ok()
  end
  puts(r)
end
"""


PARKED = """\
def read_all(path: String) -> Result[List[String]]
  return File.foreach(path, 1024, 60000).map do |line| line end.to_a
end

def main() -> Void
  path = System.args()[0]
  if System.args()[1] == "cancel"
    items = Task.map([path], 1, 300) do |p|
      read_all(p)
    end
    puts(items[0])
  else
    puts(File.foreach(path, 1024, 300).map do |line| line end.to_a)
  end
end
"""

ROUND_TRIP = """\
def main() -> Void
  dir = System.args()[0]
  lines = File.foreach(Path.join([dir, "in.txt"]).unwrap!, 1048576, 60000).to_a.unwrap!
  out = Path.join([dir, "out.txt"]).unwrap!
  copy = Path.join([dir, "copy.txt"]).unwrap!
  puts(lines.lazy.write_lines(out, 60000))
  back = File.foreach(out, 1048576, 60000).to_a.unwrap!
  puts(back.inspect == lines.inspect)
  puts(File.foreach(out, 1048576, 60000).map do |line| line end.write_lines(copy, 60000))
end
"""

WRITE_LIMITED = """\
def main() -> Void
  puts((1..100000).lazy.map do |n| "line #{n}" end.write_lines(System.args()[0], 60000))
end
"""

WRITE_PARKED = """\
def write_all(path: String) -> Result[Void]
  return (1..30000).lazy.map do |n| "line #{n}" end.write_lines(path, 60000)
end

def main() -> Void
  items = Task.map([System.args()[0]], 1, 300) do |p|
    write_all(p)
  end
  puts(items[0])
end
"""

FIFO = known_issue(WINDOWS, 433, "the FIFO cases need a named-pipe peer on Windows")


def file_events(trace):
    events = []
    for line in trace.read_text(encoding="utf-8").splitlines():
        found = EVENT.search(line)
        if found:
            events.append((found.group(1), found.group(2)))
    return events


def traced(tmp_path, bytecode, *flags, args=()):
    trace = tmp_path / "trace.txt"
    env = vm_environment({"AGENTICA_VM_TRACE": "io", "AGENTICA_VM_TRACE_FILE": str(trace)})
    result = run_vm(bytecode, *flags, args=args, env=env, cwd=tmp_path, timeout=WAIT_SECONDS)
    return result, file_events(trace)


def run_fixture(tmp_path, name, last_line):
    """Run a fixture of tests/fixtures/vm/ on a fresh work folder under the io trace; return its file events."""
    bytecode = compile_agc(FIXTURES / "vm" / (name + ".agc"), tmp_path / (name + ".agcb"))
    work = tmp_path / "work"
    work.mkdir()
    result, events = traced(tmp_path, bytecode, args=[str(work)])
    assert result.code == 0, result.stderr
    assert result.stdout.rstrip("\n").endswith(last_line), result.stdout
    return events


def assert_closed_in_order(events, most_open):
    """No more than most_open files are open when one opens, and none is open at the end."""
    open_handles = set()
    for kind, handle in events:
        if kind == "open":
            assert len(open_handles) < most_open, "handle %s opened while %s open: %s" % (handle, open_handles, events)
            open_handles.add(handle)
        else:
            open_handles.discard(handle)
    assert not open_handles, events


def test_file_foreach_closes_its_file_before_the_next_opens_on_every_exit_path(tmp_path):
    events = run_fixture(tmp_path, "lazy-file", 'and the file opens again: ok(["1"])')
    assert_closed_in_order(events, 1)
    # The fixture's own write, then one file per path that opens one (twice for the recipe run twice).
    assert sum(1 for kind, _ in events if kind == "open") == 14, events


def test_max_steps_ends_a_pipeline_over_a_file_and_the_end_of_the_run_closes_it(tmp_path):
    data = tmp_path / "lines.txt"
    data.write_text("".join("l%d\n" % k for k in range(5000)), encoding="utf-8")
    bytecode = compile_text(STEP_LIMITED, "limited", tmp_path)
    result, events = traced(tmp_path, bytecode, "--max-steps", "2000", args=[str(data)])
    assert result.code == 1 and "RUNTIME-STEP-LIMIT" in result.stderr, result.stderr
    assert [kind for kind, _ in events] == ["open", "close"], events


@FIFO
@pytest.mark.parametrize("mode,peer_mode,expected", (
    ("cancel", "idle", 'error("task: timed out")'),
    ("timeout", "stall", 'error("filesystem: operation timed out")'),
), ids=("cancel-while-parked-on-a-read", "read-timeout"))
def test_a_terminal_parked_on_a_file_read_ends_and_releases_the_file(tmp_path, request, mode, peer_mode, expected):
    _, fifo = start_fifo_peer(tmp_path, peer_mode, request)
    bytecode = compile_text(PARKED, "parked", tmp_path)
    result, events = traced(tmp_path, bytecode, args=[str(fifo), mode])
    assert (result.code, result.stdout) == (0, expected + "\n"), result.stderr
    opened = [handle for kind, handle in events if kind == "open"]
    assert len(opened) == 1, events
    assert ("close", opened[0]) in events, events


def lines_upto(count):
    return "".join("line %d\n" % n for n in range(1, count + 1))


def test_max_steps_in_the_middle_of_write_lines_flushes_the_buffered_lines_and_closes_the_file(tmp_path):
    out = tmp_path / "out.txt"
    bytecode = compile_text(WRITE_LIMITED, "write_limited", tmp_path)
    result, events = traced(tmp_path, bytecode, "--max-steps", "2000", args=[str(out)])
    assert result.code == 1 and "RUNTIME-STEP-LIMIT" in result.stderr, result.stderr
    assert [kind for kind, _ in events] == ["open", "close"], events
    # Fewer lines than fill the 64 KiB buffer, so each one written is still buffered when the limit hits: the end of
    # the run writes them all, whole lines in order.
    text = out.read_text(encoding="utf-8")
    count = text.count("\n")
    assert 0 < count < 100000 and len(text) < 65536, len(text)
    assert text == lines_upto(count)


@FIFO
def test_a_cancel_while_write_lines_is_parked_on_a_write_closes_the_file(tmp_path, request):
    # The peer holds the FIFO open and never reads, so the first 64 KiB write job fills the pipe and parks.
    _, fifo = start_fifo_peer(tmp_path, "idle", request)
    bytecode = compile_text(WRITE_PARKED, "write_parked", tmp_path)
    result, events = traced(tmp_path, bytecode, args=[str(fifo)])
    assert (result.code, result.stdout) == (0, 'error("task: timed out")\n'), result.stderr
    opened = [handle for kind, handle in events if kind == "open"]
    assert len(opened) == 1, events
    assert ("close", opened[0]) in events, events
    # What reached the pipe is still queued there (the peer holds it open): the first lines, in order, and not all.
    reader = os.open(fifo, os.O_RDONLY | os.O_NONBLOCK)
    try:
        queued = b""
        while True:
            try:
                piece = os.read(reader, 65536)
            except BlockingIOError:
                break
            if not piece:
                break
            queued += piece
    finally:
        os.close(reader)
    expected = lines_upto(30000).encode("utf-8")
    assert 0 < len(queued) < len(expected) and expected.startswith(queued), len(queued)


def test_write_lines_closes_its_file_before_the_next_opens_on_every_exit_path(tmp_path):
    events = run_fixture(tmp_path, "lazy-write", "a failed open pulls nothing: false")
    # The copy reads one file while it writes another; every other case has one file open at a time.
    assert_closed_in_order(events, 2)


def test_file_foreach_reads_back_what_write_lines_wrote(tmp_path):
    random.seed(4407)
    alphabet = ["a", "Z", " ", "\t", "\u00e9", "\u65e5\u672c", "\U0001f600", ",", "\"", "\r"]
    lines = ["", "plain", "x" * 70000, "\u00e9t\u00e9"]
    lines += ["".join(random.choices(alphabet, k=random.randint(0, 40))).rstrip("\r") for _ in range(300)]
    expected = "".join(line + "\n" for line in lines).encode("utf-8")
    (tmp_path / "in.txt").write_bytes(expected)
    bytecode = compile_text(ROUND_TRIP, "round_trip", tmp_path)
    result = run_vm(bytecode, args=[str(tmp_path)], cwd=tmp_path, timeout=WAIT_SECONDS)
    assert (result.code, result.stdout) == (0, "ok()\ntrue\nok()\n"), result.stderr
    assert (tmp_path / "out.txt").read_bytes() == expected
    assert (tmp_path / "copy.txt").read_bytes() == expected
