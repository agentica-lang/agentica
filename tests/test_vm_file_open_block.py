"""File.open with a block against Python's own file reads and writes.

The golden tests/fixtures/vm/file-open-block.agc covers the outcomes of the block
(ok, error, early return, failed try, nested opens, a handle that leaves the
block). Here Python is the independent peer: it reads a file the block wrote
while the VM still runs (so the close happened at the end of the block, not at
the end of the run), writes a file the block reads, and checks the close error
of a write to /dev/full (Linux).
"""
import os
import random
import sys

from tests.agentica_test import compile_text, host_only, run_vm, start_vm

LINUX = sys.platform.startswith("linux")

# Writes the lines of its arguments in a block, says so, then waits for stdin to end before it exits.
WRITER = """\
def main() -> Void
  args = System.args()
  r = File.open(args[0], "write", 30000) do |f|
    for line in args.drop(1)
      try File.write(f, line + "\\n")
    end
    ok(args.size - 1)
  end
  puts("written #{r}")
  gets
  puts("done")
end
"""

# Counts the lines of a file and their characters in a block.
READER = """\
def main() -> Void
  r = File.open(System.args()[0]) do |f|
    lines = 0
    chars = 0
    line = File.read_line(f)
    while line.ok?
      lines += 1
      chars += line.unwrap!.size
      line = File.read_line(f)
    end
    ok([lines, chars])
  end
  puts(r)
end
"""

# An ok block whose close fails gives the close error; an error block keeps its own error.
FULL = """\
def main() -> Void
  closing = File.open("/dev/full", "write") do |f|
    try File.write(f, "x")
    ok(1)
  end
  puts(closing.ok?)
  failed: Result[Int] = File.open("/dev/full", "write") do |f|
    try File.write(f, "x")
    error("the block failed")
  end
  case failed
    error(message) -> puts(message)
    ok(value) -> puts(value)
  end
end
"""


def lines_of(seed, count):
    chooser = random.Random(seed)
    return ["".join(chooser.choice("abcxyz λ日") for _ in range(chooser.randrange(0, 40))) for _ in range(count)]


def open_descriptors_to(pid, path):
    """The descriptors of process pid that point at path (Linux /proc)."""
    folder = "/proc/%d/fd" % pid
    found = []
    for name in os.listdir(folder):
        try:
            if os.readlink(os.path.join(folder, name)) == str(path):
                found.append(name)
        except OSError:
            continue
    return found


def test_the_writes_are_on_disk_and_the_handle_closed_when_the_block_ends(tmp_path):
    bytecode = compile_text(WRITER, "writer", tmp_path)
    target = (tmp_path / "out.txt").resolve()
    lines = lines_of(7, 50)
    child = start_vm(bytecode, target, *lines, stdin=True)
    try:
        assert child.next_line() == "written ok(50)"
        # The VM waits on stdin: only the close at the end of the block can have written the buffered lines.
        with open(target, encoding="utf-8", newline="") as stream:
            assert stream.read() == "".join(line + "\n" for line in lines)
        if LINUX:
            assert open_descriptors_to(child.process.pid, target) == []
        child.close_stdin()
        assert child.next_line() == "done"
        assert child.wait() == 0
    finally:
        child.stop()


def test_the_block_reads_what_python_wrote(tmp_path):
    bytecode = compile_text(READER, "reader", tmp_path)
    lines = lines_of(11, 300)
    target = tmp_path / "in.txt"
    with open(target, "w", encoding="utf-8", newline="") as stream:
        stream.write("".join(line + "\n" for line in lines))
    result = run_vm(bytecode, args=[target])
    assert result.code == 0, result.stderr
    assert result.stdout == "ok([%d, %d])\n" % (len(lines), sum(len(line) for line in lines))


@host_only(not LINUX, "/dev/full, which fails every flush, is a Linux device")
def test_a_close_error_replaces_an_ok_result_and_is_dropped_after_an_error(tmp_path):
    bytecode = compile_text(FULL, "full", tmp_path)
    result = run_vm(bytecode)
    assert result.code == 0, result.stderr
    assert result.stdout == "false\nthe block failed\n"
