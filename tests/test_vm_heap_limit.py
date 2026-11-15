"""--max-heap SIZE: a program whose memory would grow past SIZE ends with RUNTIME-HEAP-LIMIT and status 70 (#1113).

The limit is on the collector's heap of the process, which starts at 32M, so the cases use sizes above it and
programs that need far more. A build without the collector counts the bytes it hands out instead.
"""
import json
import os

import pytest

from tests.agentica_test import cli, compile_text, run, run_vm, scaled, vm_binary

# A sanitizer build has no collector, and a GC stress build collects at every allocation.
OTHER_BUILD = bool(os.environ.get("AGENTICA_VM_BINARY") or os.environ.get("AGENTICA_TEST_EXECUTABLE")) or any(
    mark in vm_binary().read_bytes() for mark in (b"__asan_init", b"__tsan_init"))

# Keeps every string it makes.
GROWS = """\
def main() -> Void
  kept: List[String] = []
  n = 0
  while true
    kept = kept.push("item number #{n} with some text to take space")
    n += 1
    if n == 1000
      puts(kept.size)
      IO.flush()
    end

  end

end
"""

# Makes 150 MB of strings and keeps none.
CHURNS = """\
def main() -> Void
  n = 0
  total = 0
  while n < 3000000
    text = "item number #{n} with some text to take space"
    total += text.length
    n += 1
  end

  puts(total)
end
"""

# 400 rounds of 20,000 garbage strings and 32 parses of an 8 KB array. A few MB are live, the heap is full of garbage
# whenever the parser asks for memory, and the parser's memory is malloc'd, outside the collector: the run ends early
# unless that memory gets a collection before it is refused. Many small parses rather than one large one: marking is
# conservative, and a stray pointer into a dead list keeps the whole list alive, so each list must be small next to
# the limit (#1681).
ROUNDS = """\
def main() -> Void
  numbers = "1"
  k = 0
  while k < 12
    numbers = numbers + "," + numbers
    k += 1
  end

  text = "[" + numbers + "]"
  round = 0
  parsed = 0
  while round < 400
    n = 0
    total = 0
    while n < 20000
      total += "garbage string number #{n}".length
      n += 1
    end

    piece = 0
    while piece < 32
      if JSON.parse(text).ok? and total > 0
        parsed += 1
      end

      piece += 1
    end

    round += 1
  end

  puts(parsed)
end
"""

CODE = "RUNTIME-HEAP-LIMIT"


def test_a_program_that_keeps_growing_ends_with_the_heap_limit(tmp_path):
    bytecode = compile_text(GROWS, "grows", tmp_path)
    result = run_vm(bytecode, "--max-heap", "64M", timeout=scaled(120))
    assert (result.code, result.stdout) == (70, "1000\n") and result.stderr.count("\n") == 1, result
    assert result.stderr.startswith("agentica: %s: " % CODE), result
    result = run_vm(bytecode, "--json", "--max-heap", str(64 << 20), timeout=scaled(120))
    assert (result.code, result.stdout) == (70, "1000\n"), result
    assert json.loads(result.stderr)["code"] == CODE, result


def test_the_flag_reaches_a_program_run_from_its_source(tmp_path):
    source = tmp_path / "grows.agc"
    source.write_text(GROWS, encoding="utf-8")
    result = run([*cli(), "--max-heap", "64M", source], timeout=scaled(120))
    assert result.code == 70 and CODE in result.stderr, result


@pytest.mark.skipif(OTHER_BUILD, reason="needs the collector of the default build")
def test_garbage_does_not_count(tmp_path):
    result = run_vm(compile_text(CHURNS, "churns", tmp_path), "--max-heap", "48M", timeout=scaled(120))
    assert (result.code, result.stdout, result.stderr) == (0, "142888890\n", ""), result


def test_a_limit_under_the_starting_heap_only_stops_its_growth(tmp_path):
    source = tmp_path / "small.agc"
    source.write_text('def main() -> Void\n  puts(JSON.parse("[1, 2]").ok?)\nend\n', encoding="utf-8")
    result = run([*cli(), "--max-heap", "8M", source], timeout=scaled(60))
    assert (result.code, result.stdout, result.stderr) == (0, "true\n", ""), result


@pytest.mark.skipif(OTHER_BUILD, reason="needs the collector of the default build")
@pytest.mark.parametrize("size", ["8M", "32M"])
def test_garbage_does_not_count_against_a_json_parse(tmp_path, size):
    result = run_vm(compile_text(ROUNDS, "rounds", tmp_path), "--max-heap", size, timeout=scaled(120))
    assert (result.code, result.stdout, result.stderr) == (0, "12800\n", ""), result


@pytest.mark.parametrize("size", ["0", "x", "64MB", "-1", "1025G", "1.5G", ""])
def test_a_bad_size_is_refused(tmp_path, size):
    bytecode = compile_text("def main() -> Void\n  puts(1)\nend\n", "one", tmp_path)
    source = tmp_path / "one.agc"
    for words in ([*cli(), "run", "--max-heap", size, "--", bytecode], [*cli(), "--max-heap", size, source]):
        result = run(words, timeout=scaled(60))
        assert (result.code, result.stdout) == (2, "") and "--max-heap" in result.stderr, result
