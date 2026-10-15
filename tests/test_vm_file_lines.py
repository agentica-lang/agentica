"""File.each_line on the VM (ported from vm-file-lines-test.rkt).

A 10 MB file streams in order with bounded memory and about size/buffer reads;
FIFOs fed by fixtures/lines-peer.py check partial reads, stalls, early closes
and a crash that frees the descriptor of a parked task.
"""
import re

from tests.agentica_test import (FIXTURES, PYTHON, WAIT_SECONDS, Child, TestCase, run, run_vm, vm_binary,
                                 vm_environment)

PEER = FIXTURES / "lines-peer.py"
BUFFER_BYTES = 4096
LINE_COUNT = 1400000

STREAM_PROGRAM = """\
def main() -> Void
  r = File.each_line(System.args()[0], 4096, 10000) do |line|
    puts(line)
    ok()
  end
  puts(r)
  status = Result.unwrap!(File.read_text("/proc/self/status", 10000))
  for entry in status.split("\\n")
    if entry.starts_with?("VmHWM")
      puts(entry)
    end
  end
end
"""

BASELINE_PROGRAM = """\
def main() -> Void
  status = Result.unwrap!(File.read_text("/proc/self/status", 10000))
  for entry in status.split("\\n")
    if entry.starts_with?("VmHWM")
      puts(entry)
    end
  end
end
"""

FIFO_PROGRAM = """\
def open_files() -> Int
  return Result.unwrap!(Dir.list("/proc/self/fd", 10000)).length
end

def wait_for(before: Int, want: Int) -> Bool
  tries = 0
  while tries < 500
    if open_files() - before == want
      return true
    end
    Task.sleep(10)
    tries = tries + 1
  end
  return false
end

def main() -> Void
  before = open_files()
  r = File.each_line(System.args()[0], 1024, Result.unwrap!(String.to_int(System.args()[1]))) do |line|
    IO.inspect(line)
    ok()
  end
  IO.inspect(r)
  IO.inspect(wait_for(before, 0))
end
"""

CRASH_PROGRAM = """\
def open_files() -> Int
  return Result.unwrap!(Dir.list("/proc/self/fd", 10000)).length
end

def reader(path: String) -> Result[Void]
  return File.each_line(path, 1024, 60000) do |line|
    puts("never #{line}")
    ok()
  end
end

def wait_for(before: Int, want: Int) -> Bool
  tries = 0
  while tries < 500
    if open_files() - before == want
      return true
    end
    Task.sleep(10)
    tries = tries + 1
  end
  return false
end

def parent(go: Channel[Int]) -> Int
  Task.spawn(&reader, System.args()[0])
  Result.unwrap!(go.recv(5000))
  zero = String.length("")
  return 1 / zero
end

def main() -> Void
  before = open_files()
  go: Channel[Int] = Channel.new(1)
  Task.spawn(&parent, go)
  IO.inspect(wait_for(before, 1))
  Result.unwrap!(go.send(1, 1000))
  IO.inspect(wait_for(before, 0))
end
"""

CLOSE_PROGRAM = """\
def open_files() -> Int
  return Result.unwrap!(Dir.list("/proc/self/fd", 10000)).length
end

def wait_for(before: Int, want: Int) -> Bool
  tries = 0
  while tries < 500
    if open_files() - before == want
      return true
    end
    Task.sleep(10)
    tries = tries + 1
  end
  return false
end

def main() -> Void
  path = System.args()[0]
  before = open_files()
  r = File.each_line(path, 1024, 5000) do |line|
    IO.inspect(line)
    return error("stop at #{line}")
  end
  IO.inspect(r)
  IO.inspect(wait_for(before, 0))
  h = Result.unwrap!(File.open(path, "read", 5000))
  IO.inspect(File.read_line(h, 5000))
  IO.inspect(File.close(h, 5000))
  IO.inspect(wait_for(before, 0))
end
"""


def hwm_kib(text):
    return int(re.search(r"VmHWM:\s+([0-9]+) kB", text).group(1))


class VmFileLines(TestCase):
    def run_program(self, name, text, *args, env=None, flags=()):
        bytecode = self.compile_text(text, name)
        return run_vm(bytecode, *flags, args=args, env=vm_environment(env), timeout=WAIT_SECONDS)

    def write_lines(self):
        data = self.make_temp_dir() / "lines.txt"
        data.write_text("".join("l%d\n" % k for k in range(LINE_COUNT)))
        return data

    def collected(self):
        """False for a VM built without libgc (its memory use is not bounded by a collector)."""
        return "no libgc" not in run([vm_binary(), "--version"]).stdout

    def test_a_10_mb_file_of_short_lines_streams_in_order_with_size_over_buffer_reads_and_bounded_memory(self):
        data = self.write_lines()
        size = data.stat().st_size
        self.assertGreater(size, 10000000)
        trace = self.make_temp_dir() / "trace.txt"
        result = self.run_program("stream", STREAM_PROGRAM, data,
                                  env={"AGENTICA_VM_TRACE": "io", "AGENTICA_VM_TRACE_FILE": trace})
        self.assertEqual(result.code, 0, result.stderr)
        expected = data.read_text()
        self.assertTrue(result.stdout.startswith(expected), "every line, in order, once")
        rest = result.stdout[len(expected):]
        self.assertRegex(rest, r"\Aok\(\)\nVmHWM:\s+[0-9]+ kB\n\Z")
        if self.collected():
            baseline = self.run_program("baseline", BASELINE_PROGRAM)
            self.assertEqual(baseline.code, 0, baseline.stderr)
            growth = hwm_kib(rest) - hwm_kib(baseline.stdout)
            self.assertLess(growth, size // 4096, "peak memory grew by %d kB while streaming %d bytes" % (growth, size))
        jobs = len(re.findall(r" io start job=[0-9]+ kind=file ", trace.read_text()))
        self.assertGreaterEqual(jobs, size // (BUFFER_BYTES + 1), "%d jobs" % jobs)
        self.assertLessEqual(jobs, 8 + size // (BUFFER_BYTES - 16), "%d jobs" % jobs)

    def test_max_steps_ends_a_long_file_with_runtime_step_limit(self):
        data = self.write_lines()
        result = self.run_program("stream", STREAM_PROGRAM, data, flags=["--max-steps", "50000"])
        self.assertEqual(result.code, 1)
        self.assertIn("RUNTIME-STEP-LIMIT", result.stderr)

    def start_fifo_peer(self, mode):
        fifo = self.make_temp_dir() / (mode + ".fifo")
        peer = self.adopt(Child([PYTHON, PEER, fifo, mode]))
        self.assertEqual(peer.next_line(), "ready", mode)
        return peer, fifo

    def test_a_fifo_fed_in_pieces_lines_and_a_crlf_split_across_reads_a_last_line_without_a_newline(self):
        peer, fifo = self.start_fifo_peer("pieces")
        result = self.run_program("fifo", FIFO_PROGRAM, fifo, "5000")
        self.assertEqual(result.code, 0, result.stderr)
        self.assertEqual(result.stdout, '"alpha"\n"beta"\n"gamma"\n""\n"delta"\nok()\ntrue\n')
        self.assertEqual(peer.next_line(), "closed")

    def test_a_fifo_that_stalls_times_out_one_read_with_a_line_half_read_and_the_descriptor_is_closed(self):
        _, fifo = self.start_fifo_peer("stall")
        result = self.run_program("fifo", FIFO_PROGRAM, fifo, "1200")
        self.assertEqual(result.code, 0, result.stderr)
        self.assertEqual(result.stdout, '"first"\nerror("filesystem: operation timed out")\ntrue\n')

    def test_closing_a_read_fifo_that_still_holds_buffered_lines_is_ok_after_an_early_stop_and_after_read_line(self):
        _, fifo = self.start_fifo_peer("burst")
        result = self.run_program("close", CLOSE_PROGRAM, fifo)
        self.assertEqual(result.code, 0, result.stderr)
        self.assertEqual(result.stdout, '"one"\nerror("stop at one")\ntrue\nok("four")\nok()\ntrue\n')

    def test_a_crash_cancels_a_task_parked_in_file_each_line_on_a_fifo_and_frees_its_descriptor(self):
        _, fifo = self.start_fifo_peer("idle")
        result = self.run_program("crash", CRASH_PROGRAM, fifo, env={"UV_THREADPOOL_SIZE": "1"})
        self.assertEqual(result.code, 1)
        self.assertEqual(result.stdout, "true\ntrue\n")
