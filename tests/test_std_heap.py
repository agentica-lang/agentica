"""std/heap against Python's heapq: random lists, with repeats, pushed and popped in turns."""
import heapq
import json
import random

from tests.agentica_test import cli, output_lines, run, vm_environment

PROGRAM = """\
import Heap from "std/heap"

def main() -> Void
  steps = JSON.decode(IO.read(), List[Int]).unwrap!
  h = Heap.new do |a: Int, b: Int| a < b end
  out: List[Int] = []
  for step in steps
    if step >= 0
      h = Heap.push(h, step)
    else
      popped = Heap.pop(h).unwrap!
      out = out.push(popped.value)
      h = popped.remaining
    end
  end

  puts(JSON.encode(out.concat(Heap.to_a(h))))
end
"""


def steps_and_expected(seed):
    """Pushes (values >= 0, with repeats) and pops (-1) in a random order, and what heapq gives for them."""
    rng = random.Random(seed)
    steps, held, out = [], [], []
    for _ in range(400):
        if held and rng.random() < 0.4:
            steps.append(-1)
            out.append(heapq.heappop(held))
        else:
            value = rng.randrange(50)
            steps.append(value)
            heapq.heappush(held, value)
    return steps, out + sorted(held)


def test_heap_matches_heapq(tmp_path):
    program = tmp_path / "heap.agc"
    program.write_text(PROGRAM, encoding="utf-8")
    for seed in range(5):
        steps, expected = steps_and_expected(seed)
        result = run(cli() + [str(program)], stdin=json.dumps(steps), env=vm_environment())
        assert result.code == 0, result.stderr
        assert json.loads(output_lines(result.stdout)[0]) == expected, seed
