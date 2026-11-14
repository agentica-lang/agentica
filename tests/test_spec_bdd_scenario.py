"""BddScenario, the std-only rows behind the scenarios of an `agentica test` worker, through the CLI: user code cannot
name them; inside std/ `srand` starts the running task's random numbers again from the seed, as main's under --seed,
and `uncount` takes the running task out of Task.pending_count once, whatever way it ends.

The std/ cases compile a program against a copy of stdlib/ with one more module, through the front end of the binary.
"""
import json
import shutil

from tests.agentica_test import ROOT, STAGE2, agentica_version, cli, require, run, vm_command, vm_environment


def test_user_code_cannot_name_bdd_random(tmp_path):
    program = tmp_path / "main.agc"
    program.write_text("def main() -> Void\n  BddScenario.uncount()\nend\n", encoding="utf-8")
    result = run(cli() + ["--json", "check", str(program)], env=vm_environment())
    assert result.code == 1, result
    found = json.loads(result.stderr.strip().splitlines()[-1])
    start = found["range"]["start"]
    assert (found["code"], start["line"], start["column"]) == ("CHECK-UNKNOWN-NAME", 2, 3)


def compiled_with_probe(tmp_path, probe, main):
    require(STAGE2.is_file(), "the front end is not built (%s): run make" % STAGE2)
    std = tmp_path / "std"
    shutil.copytree(ROOT / "stdlib", std)
    (std / "probe.agc").write_text(probe, encoding="utf-8")
    with (std / "MODULES").open("a", encoding="utf-8") as modules:
        modules.write("probe\n")
    program = tmp_path / "main.agc"
    program.write_text('import Probe from "std/probe"\n\n' + main, encoding="utf-8")
    compiled = tmp_path / "main.agcb"
    built = run([*vm_command(), "--", STAGE2, "--version", agentica_version(), "--stdlib", std,
                 "--self", ROOT / "dist" / "agentica", "--", "compile", program, "-o", compiled],
                env=vm_environment())
    assert built.code == 0, built
    return compiled


def test_srand_in_a_task_draws_what_main_draws_first_under_the_same_seed(tmp_path):
    compiled = compiled_with_probe(
        tmp_path,
        "def reseeded(seed: Int) -> Int\n  BddScenario.srand(seed)\n  Random.int(0, 1000000000)\nend\n",
        "def main() -> Void\n"
        "  first = Random.int(0, 1000000000)\n"
        "  second = Random.int(0, 1000000000)\n"
        "  task = Task.spawn do Probe.reseeded(Random.seed) end\n"
        '  puts("#{first} #{second} #{Task.await(task)}")\n'
        "end\n")
    for seed in ("7", "2147483647"):
        result = run([*vm_command(), "--seed", seed, "--", compiled], env=vm_environment())
        assert result.code == 0, result
        first, second, reseeded = result.stdout.split()
        assert reseeded == first != second, result


# Each line: the count inside the uncounted task, then the count once it ended and one plain task waits. Twice in one
# task, then in main (already out), then in a task that is cancelled while it sleeps, then in one that crashes.
UNCOUNT_PROBE = """\
def twice() -> Int
  BddScenario.uncount()
  BddScenario.uncount()
  Task.pending_count()
end

def in_main() -> Void
  BddScenario.uncount()
end

def parked(ready: Channel[Int]) -> Result[Int]
  BddScenario.uncount()
  try ready.send(Task.pending_count(), 5000)
  Task.sleep(60000)
  ok(0)
end

def crashes(zero: Int) -> Result[Int]
  BddScenario.uncount()
  ok(1 / zero)
end
"""

UNCOUNT_MAIN = """\
def wait(gate: Channel[Int]) -> Result[Int]
  gate.recv(60000)
end

def with_one_waiting(inside: Int) -> String
  gate: Channel[Int] = Channel.new(1)
  waiting = Task.spawn do wait(gate) end
  count = Task.pending_count()
  _ = gate.send(0, 1000)
  _ = Task.await(waiting)
  "#{inside} #{count}"
end

def main() -> Void
  puts(with_one_waiting(Task.await(Task.spawn do Probe.twice() end)))
  Probe.in_main()
  puts(with_one_waiting(Task.pending_count()))
  ready: Channel[Int] = Channel.new(1)
  sleeper = Task.spawn do Probe.parked(ready) end
  inside = ready.recv(5000).unwrap!
  Task.cancel(sleeper)
  _ = Task.await(sleeper)
  puts(with_one_waiting(inside))
  crashed = Task.await(Task.spawn do Probe.crashes(0) end)
  puts(with_one_waiting(crashed.unwrap_or(0)))
end
"""


def test_uncount_takes_a_task_out_of_the_pending_count_once_however_it_ends(tmp_path):
    compiled = compiled_with_probe(tmp_path, UNCOUNT_PROBE, UNCOUNT_MAIN)
    result = run([*vm_command(), "--", compiled], env=vm_environment())
    assert result.code == 0, result
    assert result.stdout.splitlines() == ["0 1", "0 1", "0 1", "0 1"], result
