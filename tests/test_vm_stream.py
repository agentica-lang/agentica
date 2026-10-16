"""Lazy Stream sources, transformations and terminal operations on the VM."""
import json

from tests.agentica_test import TestCase, compile_agc, run_vm


PIPELINE_PROGRAM = """\
def next(n: Int) -> Int
  return n + 1
end

def even(n: Int) -> Bool
  return n % 2 == 0
end

def plus(acc: Int, n: Int) -> Int
  return acc + n
end

def main() -> Void
  stream: Stream[Int] = Stream.iterate(1, &next).filter(&even).map(&next).take_while do |n|
    n < 8
  end
  puts(stream.to_list(10))
  puts(stream.reduce(0, &plus))
  puts(Stream.iterate(4, &next).take(0).to_list(0))
  puts(Stream.iterate(1, &next).to_list(3))
end
"""


LINES_PROGRAM = """\
def identity(line: String) -> String
  return line
end

def stop_on_one(line: String) -> Result[Void]
  puts(line)
  if line == "one"
    return error("stop")
  end
  return ok()
end

def main() -> Void
  invalid = Stream.lines("", 1024, 5000).to_list(2)
  puts(invalid)
  stream = Stream.lines(System.args()[0], 1024, 5000).map(&identity).take(2)
  puts(stream.to_list(2))
  puts(stream.each do |line|
    puts(line)
    ok()
  end)
  stopped = Stream.lines(System.args()[0], 1024, 5000).each(&stop_on_one)
  puts(stopped)
end
"""


class StreamVmTest(TestCase):
    def compile_and_run(self, source, *args):
        work = self.make_temp_dir("agentica-stream-")
        path = work / "program.agc"
        bytecode = work / "program.agcb"
        path.write_text(source, encoding="utf-8")
        compile_agc(path, bytecode)
        return run_vm(bytecode, *args)

    def test_iterate_pipeline_terminals_and_zero_limit(self):
        result = self.compile_and_run(PIPELINE_PROGRAM)
        self.assertEqual(result.code, 0, result.stderr)
        self.assertEqual(result.stdout, "ok([3, 5, 7])\nok(15)\nok([])\nerror(\"stream: exceeds max items\")\n")

    def test_lines_is_lazy_closes_after_take_and_can_be_consumed_again(self):
        work = self.make_temp_dir("agentica-stream-lines-")
        path = work / "lines.txt"
        path.write_text("one\ntwo\nthree\n", encoding="utf-8")
        source = work / "program.agc"
        bytecode = work / "program.agcb"
        source.write_text(LINES_PROGRAM, encoding="utf-8")
        compile_agc(source, bytecode)
        result = run_vm(bytecode, args=(str(path),))
        self.assertEqual(result.code, 0, result.stderr)
        self.assertTrue(result.stdout.startswith("error("), result.stdout)
        self.assertIn("ok([\"one\", \"two\"])\none\ntwo\nok()\none\nerror(\"stop\")\n", result.stdout)

    def test_negative_take_is_reported_at_its_argument(self):
        source = """\
def next(n: Int) -> Int
  return n + 1
end

def main() -> Void
  n = Stream.iterate(1, &next).take(-1)
end
"""
        result = self.compile_and_run(source, "--json")
        self.assertEqual(result.code, 1)
        diagnostic = json.loads(result.stderr.strip().split("\n")[-1])
        self.assertEqual(diagnostic["code"], "RUNTIME-INVALID-COUNT")
        span = diagnostic["range"]
        self.assertEqual((span["start"]["line"], span["start"]["column"]), (6, 37))
        self.assertEqual((span["end"]["line"], span["end"]["column"]), (6, 39))
