"""The I/O sources of Lazy: File.foreach closes its file on every exit path.

The VM's io trace has a file_open and a file_close line for each file handle, on every platform, so the check needs
no /proc and runs on Windows too. tests/fixtures/vm/lazy-file.agc (also a VM golden) goes through each exit path of a
terminal in turn: the end, first and find stopping early, an error from the block, a failed try, a read error, a
crash and a cancel of the task. Each path opens one file at most, so no handle may still be open when the next one
opens. --max-steps ends the run with the file of the pipeline still open, and the end of the run closes it.
"""
import re

from tests.agentica_test import FIXTURES, WAIT_SECONDS, compile_agc, compile_text, run_vm, vm_environment

EVENT = re.compile(r" io file_(open|close) handle=([0-9]+)$")

STEP_LIMITED = """\
def main() -> Void
  r = File.foreach(System.args()[0], 1024, 60000).map do |line| line.length end.each do |n|
    ok()
  end
  puts(r)
end
"""


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


def test_file_foreach_closes_its_file_before_the_next_opens_on_every_exit_path(tmp_path):
    bytecode = compile_agc(FIXTURES / "vm" / "lazy-file.agc", tmp_path / "lazy-file.agcb")
    work = tmp_path / "work"
    work.mkdir()
    result, events = traced(tmp_path, bytecode, args=[str(work)])
    assert result.code == 0, result.stderr
    assert result.stdout.rstrip("\n").endswith('and the file opens again: ok(["1"])'), result.stdout
    open_handles = set()
    for kind, handle in events:
        if kind == "open":
            assert not open_handles, "handle %s opened while %s still open: %s" % (handle, open_handles, events)
            open_handles.add(handle)
        else:
            open_handles.discard(handle)
    assert not open_handles, events
    # The fixture's own write, then one file per path that opens one (twice for the recipe run twice).
    assert sum(1 for kind, _ in events if kind == "open") == 14, events


def test_max_steps_ends_a_pipeline_over_a_file_and_the_end_of_the_run_closes_it(tmp_path):
    data = tmp_path / "lines.txt"
    data.write_text("".join("l%d\n" % k for k in range(5000)), encoding="utf-8")
    bytecode = compile_text(STEP_LIMITED, "limited", tmp_path)
    result, events = traced(tmp_path, bytecode, "--max-steps", "2000", args=[str(data)])
    assert result.code == 1 and "RUNTIME-STEP-LIMIT" in result.stderr, result.stderr
    assert [kind for kind, _ in events] == ["open", "close"], events
