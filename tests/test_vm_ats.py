"""ATS shared tables on the VM: the semantics of one table against an independent Python model
(tests/fixtures/ats-peer.py), many tasks on four schedulers updating one table with exact results, a table that BDD
steps capture from main and that starts fresh in each scenario, and, in the slow tier, tables made and dropped in a
loop whose heap stays bounded.
"""
import json
import random
import re

import pytest

from tests.agentica_test import FIXTURES, PYTHON, cli, compile_text, run, run_vm, vm_environment

KEYS = ["a", "b", "c", "d", "e", "f"]

HELPERS = """\
def show_get(t: ATS[String, Int], k: String) -> Void
  found = t.get(k)
  if found.ok?
    puts("get #{k} #{found.unwrap!}")
  else
    puts("get #{k} missing")
  end
end

"""

STATEMENTS = {
    "put": 't.put("{k}", {v})',
    "put_new": 'puts("put_new {k} #{{t.put_new("{k}", {v})}}")',
    "delete": 't.delete("{k}")',
    "add": 'puts("add {k} #{{t.add("{k}", {v})}}")',
    "get": 'show_get(t, "{k}")',
    "has_key": 'puts("has_key {k} #{{t.has_key?("{k}")}}")',
    "size": 'puts("size #{{t.size}}")',
    "keys": 'puts("keys #{{t.keys.join(",")}}")',
    "to_map": 'puts("to_map #{{t.to_map}}")',
}

SHARED = """\
struct Job
  id: Int
  hits: ATS[String, Int]
  cache: ATS[String, Int]
end

def work(job: Job) -> Int
  stored = 0
  i = 0
  while i < 200
    job.hits.add("total", 1)
    job.hits.add("task-#{job.id}", 1)
    if job.cache.put_new("key-#{i % 50}", i % 50)
      stored += 1
    end
    job.cache.put("own-#{job.id}-#{i % 10}", job.id)
    i += 1
  end

  if job.id % 2 == 1
    for j in 0...10
      job.cache.delete("own-#{job.id}-#{j}")
    end
  end

  return stored
end

def main() -> Void
  hits: ATS[String, Int] = ATS.new()
  cache: ATS[String, Int] = ATS.new()
  tasks = (0...64).to_a.map do |id| Task.spawn(&work, Job(id: id, hits: hits, cache: cache)) end
  stored = tasks.map do |task| Task.await(task) end.sum
  puts("total #{hits.get("total").unwrap_or(0)}")
  puts("stored #{stored}")
  puts("hits #{hits.size}")
  puts("cache #{cache.size}")
  wrong = (0...64).to_a.filter do |id|
    hits.get("task-#{id}").unwrap_or(0) != 200 or cache.has_key?("own-#{id}-9") == (id % 2 == 1)
  end
  puts("wrong #{wrong}")
  shared = (0...50).to_a.filter do |k| cache.get("key-#{k}").unwrap_or(-1) != k end
  puts("shared wrong #{shared}")
end
"""

STEPS = """\
import BDD from "std/bdd"

def main() -> Void
  hits: ATS[String, Int] = ATS.new()
  BDD.run([
    BDD.step("I count a visit") do |ctx: BDD.Context, args: List[String]|
      hits.add("home", 1)
      ctx
    end,
    BDD.step("the count is {int}") do |ctx: BDD.Context, args: List[String]|
      BDD.assert(ctx, hits.get("home").unwrap_or(0) == args[0].to_i!, "wrong count")
    end,
  ])
end
"""

FEATURE = """\
Feature: Visits

  Scenario: two visits
    When I count a visit
    And I count a visit
    Then the count is 2

  Scenario: one visit
    When I count a visit
    Then the count is 1
"""

CHURN = """\
def churn(id: Int) -> Int
  round = 0
  while round < 250
    t: ATS[Int, String] = ATS.new()
    i = 0
    while i < 2000
      t.put(i % 500, "v#{i}")
      i += 1
    end
    round += 1
  end
  return id
end

def main() -> Void
  tasks = (0...8).to_a.map do |id| Task.spawn(&churn, id) end
  puts(tasks.map do |task| Task.await(task) end.sum)
end
"""


def operations(seed, count):
    rng = random.Random(seed)
    names = list(STATEMENTS)
    return [[rng.choice(names), rng.choice(KEYS), rng.randint(-50, 50)] for _ in range(count)]


def program(ops):
    lines = ["  " + STATEMENTS[name].format(k=key, v=value) for name, key, value in ops]
    return HELPERS + "def main() -> Void\n  t: ATS[String, Int] = ATS.new()\n" + "\n".join(lines) + "\nend\n"


def test_one_table_does_what_a_python_dict_does(tmp_path):
    ops = operations(17, 600)
    bytecode = compile_text(program(ops), "ats_ops", tmp_path)
    vm = run_vm(bytecode, "--schedulers", "1", env=vm_environment())
    assert vm.code == 0, vm.stderr
    peer = run([PYTHON, FIXTURES / "ats-peer.py"], stdin=json.dumps(ops).encode("utf-8"))
    assert peer.code == 0, peer.stderr
    assert vm.stdout.splitlines() == peer.stdout.splitlines()
    assert any(line.startswith("keys ") and len(line) > 9 for line in peer.stdout.splitlines())


def test_tasks_on_four_schedulers_share_a_counter_and_a_cache(tmp_path):
    bytecode = compile_text(SHARED, "ats_shared", tmp_path)
    vm = run_vm(bytecode, "--schedulers", "4", env=vm_environment())
    assert vm.code == 0, vm.stderr
    # 64 tasks add 200 each; 50 shared keys are stored once in all; the 32 even tasks keep their 10 own keys.
    assert vm.stdout.splitlines() == [
        "total 12800", "stored 50", "hits 65", "cache 370", "wrong []", "shared wrong []"]


def test_a_table_captured_by_bdd_steps_starts_fresh_in_each_scenario(tmp_path):
    (tmp_path / "steps.agc").write_text(STEPS, encoding="utf-8")
    (tmp_path / "visits.feature").write_text(FEATURE, encoding="utf-8")
    result = run(cli() + ["test", "visits.feature", "--steps", "steps.agc"], cwd=tmp_path, env=vm_environment())
    assert result.code == 0, result.stdout + result.stderr
    assert "2 passed, 0 failed" in result.stdout


@pytest.mark.slow
def test_tables_made_and_dropped_in_a_loop_keep_the_heap_bounded(tmp_path):
    bytecode = compile_text(CHURN, "ats_churn", tmp_path)
    vm = run_vm(bytecode, "--schedulers", "4", env=vm_environment({"AGENTICA_VM_TRACE": "gc"}))
    assert vm.code == 0, vm.stderr
    assert vm.stdout == "28\n"
    # 4 million puts allocate several GB of nodes; a table nothing refers to any more must be collected.
    heaps = [int(size) for size in re.findall(r"gc collect .*? heap=(\d+)", vm.stderr)]
    assert heaps, "the gc trace printed no collection"
    assert max(heaps) < 256 * 1024 * 1024, max(heaps)
