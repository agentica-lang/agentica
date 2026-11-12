"""ATS shared tables on the VM: the semantics of one table against an independent Python model
(tests/fixtures/ats-peer.py) with String and with Bytes keys, many tasks on four schedulers updating one table with
exact results, a table that BDD steps capture from main and that starts fresh in each scenario, and, in the slow tier,
tables made and dropped in a loop whose heap stays bounded.
"""
import json
import random
import re

import pytest

from tests.agentica_test import FIXTURES, PYTHON, cli, compile_text, run, run_vm, vm_environment

KEYS = ["a", "b", "c", "d", "e", "f"]
# Bytes keys as hex: the empty key, keys with 0 bytes inside, and keys that are prefixes of others.
BYTES_KEYS = ["", "00", "0000", "0061", "61", "6100", "6162", "ff"]

HELPERS = """\
def show_get(t: ATS[{type}, Int], label: String, k: {type}) -> Void
  found = t.get(k)
  if found.ok?
    puts("get #{{label}} #{{found.unwrap!}}")
  else
    puts("get #{{label}} missing")
  end
end

def key(hex: String) -> Bytes
  return OpenSSL.Digest.hexdecode(hex).unwrap!
end

"""

# {k} is the key as the peer prints it, {key} the expression of the key in the program.
STATEMENTS = {
    "put": "t.put({key}, {v})",
    "put_new": 'puts("put_new {k} #{{t.put_new({key}, {v})}}")',
    "delete": "t.delete({key})",
    "add": 'puts("add {k} #{{t.add({key}, {v})}}")',
    "get": 'show_get(t, "{k}", {key})',
    "has_key": 'puts("has_key {k} #{{t.has_key?({key})}}")',
    "size": 'puts("size #{{t.size}}")',
    "keys": 'puts("keys #{{{keys}.join(",")}}")',
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
  while i < 2000
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
  stored = tasks.map { |task| Task.await(task) }.sum
  puts("total #{hits.get("total").unwrap_or(0)}")
  puts("stored #{stored}")
  puts("hits #{hits.size}")
  puts("cache #{cache.size}")
  wrong = (0...64).to_a.filter do |id|
    hits.get("task-#{id}").unwrap_or(0) != 2000 or cache.has_key?("own-#{id}-9") == (id % 2 == 1)
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
    BDD.step("I count a visit") do |ctx: BDD.Context, _args: List[String]|
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
  puts(tasks.map { |task| Task.await(task) }.sum)
end
"""


def operations(seed, count, keys):
    rng = random.Random(seed)
    names = list(STATEMENTS)
    return [[rng.choice(names), rng.choice(keys), rng.randint(-50, 50)] for _ in range(count)]


def program(ops, key_type):
    if key_type == "Bytes":
        key, keys = 'key("{k}")', "t.keys.map do |k| OpenSSL.Digest.hexencode(k) end"
    else:
        key, keys = '"{k}"', "t.keys"
    lines = []
    for name, k, value in ops:
        template = STATEMENTS[name].replace("{key}", key).replace("{keys}", keys)
        lines.append("  " + template.format(k=k, v=value))
    head = HELPERS.format(type=key_type) + "def main() -> Void\n  t: ATS[%s, Int] = ATS.new()\n" % key_type
    return head + "\n".join(lines) + "\nend\n"


@pytest.mark.parametrize(("key_type", "keys", "flags"), [("String", KEYS, []), ("Bytes", BYTES_KEYS, ["--bytes"])])
def test_one_table_does_what_a_python_dict_does(tmp_path, key_type, keys, flags):
    ops = operations(17, 600, keys)
    bytecode = compile_text(program(ops, key_type), "ats_ops", tmp_path)
    vm = run_vm(bytecode, "--schedulers", "1", env=vm_environment())
    assert vm.code == 0, vm.stderr
    peer = run([PYTHON, FIXTURES / "ats-peer.py", *flags], stdin=json.dumps(ops).encode("utf-8"))
    assert peer.code == 0, peer.stderr
    assert vm.stdout.splitlines() == peer.stdout.splitlines()
    assert any(line.startswith("keys ") and len(line) > 9 for line in peer.stdout.splitlines())


def test_tasks_on_four_schedulers_share_a_counter_and_a_cache(tmp_path):
    bytecode = compile_text(SHARED, "ats_shared", tmp_path)
    vm = run_vm(bytecode, "--schedulers", "4", env=vm_environment())
    assert vm.code == 0, vm.stderr
    # 64 tasks add 2000 each; 50 shared keys are stored once in all; the 32 even tasks keep their 10 own keys.
    assert vm.stdout.splitlines() == [
        "total 128000", "stored 50", "hits 65", "cache 370", "wrong []", "shared wrong []"]


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
