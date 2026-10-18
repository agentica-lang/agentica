"""Shard 6 of the VM golden tests (tests/vm_diff_support.py)."""
import pytest

from tests.agentica_test import compile_agc, vm_binary
from tests.vm_diff_support import (
    SAMPLED_SWEEP, Fixture, fixture_programs, json_crash_free, limit_options, outcome, read_expected,
    read_expected_steps, run_fixture_vm, sampled_limits, shard_assignment, step_allowance, step_limited,
    style_options, sweep_limits, sweep_note, text_code, text_crash_free, total_steps, vm_batch,
)

SHARD = 6


@pytest.fixture(scope="module", autouse=True)
def _warmup():
    vm_binary()


def check_steps(total, expected_steps, name):
    assert total <= step_allowance(expected_steps), \
        "%s takes %s steps, more than its golden %s allows (over-charging)" % (name, total, expected_steps)


def check_limited(on_vm, full, name, limit, note=""):
    seen = outcome(on_vm)
    message = "%s --max-steps %s%s (exit 124/137 or timeout: the run timed out): %r" % (name, limit, note, seen)
    if seen != full:
        assert seen[0] == 1, message
        assert seen[3] == "RUNTIME-STEP-LIMIT", message
        assert full[1].startswith(seen[1]), message
        assert full[2].startswith(seen[2]), message
    return seen == full


def check_sweep(results, limits, full, name, note=""):
    finished = False
    for on_vm, limit in zip(results, limits):
        done = check_limited(on_vm, full, name, limit, note)
        if finished:
            assert done, "%s --max-steps %s%s stops after a smaller limit finished" % (name, limit, note)
        finished = done
    assert finished, "%s finishes under --max-steps %s%s" % (name, limits[-1], note)


def check_text_format(on_vm, full, message):
    assert tuple(on_vm[:2]) == tuple(full[:2]), message
    stderr, text_crashes, text_summaries = text_crash_free(on_vm[2])
    expected, json_crashes, json_summaries = json_crash_free(full[2])
    assert text_crashes == json_crashes, message
    assert text_summaries == json_summaries, message
    assert stderr.startswith(expected), "%s: %r does not start with %r" % (message, stderr, expected)
    diagnostic = stderr[min(len(stderr), len(expected)):]
    if full[3]:
        assert text_code(diagnostic) == full[3], message
    else:
        assert diagnostic == "", message


def check_fixture(program, work):
    name = program.name
    fixture = Fixture.of(program)
    bytecode = compile_agc(program, work / (program.stem + ".agcb"))
    full = read_expected(program)
    expected_steps = read_expected_steps(program)
    total = total_steps(lambda limit: step_limited(run_fixture_vm(fixture, bytecode, limit, work)))
    check_steps(total, expected_steps, name)
    limits = sampled_limits(total, expected_steps, name) if SAMPLED_SWEEP else sweep_limits(total, expected_steps)
    text_styles = ["plain", "ai"]
    results = vm_batch(
        fixture, bytecode,
        [style_options("json")] + [style_options(style) for style in text_styles]
        + [limit_options(limit) + style_options("json") for limit in limits], work)
    assert outcome(results[0]) == full, name
    for style, on_vm in zip(text_styles, results[1:]):
        check_text_format(on_vm, full, "%s %s" % (name, style))
    check_sweep(results[1 + len(text_styles):], limits, full, name, sweep_note())


def _make_test(program):
    def test_fixture(tmp_path):
        check_fixture(program, tmp_path)

    test_fixture.__name__ = "test_" + program.stem.replace("-", "_")
    test_fixture.__doc__ = (
        "%s gives its expected exit code, stdout, stderr and diagnostic code under every --max-steps"
        % program.name)
    return test_fixture


for _program in [program for program, _shard in shard_assignment(fixture_programs()) if _shard == SHARD]:
    _test = _make_test(_program)
    assert _test.__name__ not in globals(), _test.__name__
    globals()[_test.__name__] = _test
