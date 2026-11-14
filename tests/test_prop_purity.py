"""Property tests (Hypothesis) of `pure` in `Analysis.bodies` (#1159): a program of arithmetic, `if`, `case` and
calls, recursion and cycles included, is pure; one call of a builtin with an effect makes every function that reaches
it impure, with that effect and the chain of calls, and leaves the others pure.

The profiles and the seed of each tier are in tests/conftest.py.
"""
import json
from importlib.util import find_spec

import pytest

from tests.agentica_test import require, run_vm, vm_environment
from tests.test_std_analysis import DRIVER, compile_agc

require(find_spec("hypothesis") is not None, "hypothesis is required (poetry install --only test --no-root)")

from hypothesis import given, strategies as st  # noqa: E402

EFFECTS = [
    ('puts("x")', "stdout", "puts"),
    ('_ = File.read_text("x")', "filesystem", "File.read_text"),
    ("_ = Time.now_ms()", "clock", "Time.now_ms"),
    ("_ = Random.int(1, 9)", "random", "Random.int"),
]


@pytest.fixture(scope="module")
def setup(tmp_path_factory):
    work = tmp_path_factory.mktemp("agentica-purity-")
    return compile_agc(DRIVER, work / "driver.agcb"), work


@st.composite
def programs(draw):
    """The calls of each function f0..fN, and maybe one effect: the function that makes it and which one."""
    count = draw(st.integers(1, 5))
    calls = [draw(st.lists(st.integers(0, count - 1), max_size=3, unique=True)) for _ in range(count)]
    effect = draw(st.none() | st.tuples(st.integers(0, count - 1), st.integers(0, len(EFFECTS) - 1)))
    return calls, effect


def source(calls, effect):
    lines = []
    for at, callees in enumerate(calls):
        called = " + ".join(f"f{callee}(n - 1)" for callee in callees) or "1"
        lines.append(f"def f{at}(n: Int) -> Int")
        if effect is not None and effect[0] == at:
            lines.append("  " + EFFECTS[effect[1]][0])
        lines += ["  if n <= 0", f"    return {at}", "  end", "  case n % 2",
                  f"    0 -> return n + {called}", f"    _ -> return n * {at + 2}", "  end", "end", ""]
    return "\n".join(lines)


def chain(calls, start, goal):
    """The shortest chain of calls from `start` to `goal` (the functions after `start`), or None."""
    paths = {start: []}
    queue = [start]
    for at in queue:
        if at == goal:
            return paths[at]
        for callee in calls[at]:
            if callee not in paths:
                paths[callee] = paths[at] + [callee]
                queue.append(callee)
    return None


@given(programs())
def test_one_effect_makes_impure_exactly_the_functions_that_reach_it(setup, program):
    driver, work = setup
    calls, effect = program
    (work / "generated.agc").write_text(source(calls, effect), encoding="utf-8")
    result = run_vm(driver, args=["bodies", "generated.agc"], cwd=work, env=vm_environment())
    assert result.code == 0 and result.stderr == "", result.stderr
    functions = {function["name"]: function for function in json.loads(result.stdout)["functions"]}
    for at in range(len(calls)):
        function = functions[f"f{at}"]
        path = None if effect is None else chain(calls, at, effect[0])
        if path is None:
            assert (function["pure"], function["impure"]) == (True, [])
        else:
            _, kind, call = EFFECTS[effect[1]]
            reasons = [(reason["effect"], reason["call"], reason["through"]) for reason in function["impure"]]
            assert (function["pure"], reasons) == (False, [(kind, call, [f"f{step}" for step in path])])
