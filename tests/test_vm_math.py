"""Spans of the diagnostics of the number helpers.

The goldens of tests/fixtures/vm/ hold the codes; these tests add where each
one points: the exponent of pow, the argument of Math.sqrt, the whole call of
clamp (as for Random.int).
"""
from tests.test_vm_bits import check_span


def test_int_pow_negative_points_at_the_exponent(tmp_path):
    check_span("int-pow-negative", "RUNTIME-INVALID-COUNT", (3, 14), (3, 19), tmp_path)


def test_math_sqrt_negative_points_at_the_argument(tmp_path):
    check_span("math-sqrt-negative", "RUNTIME-INVALID-NUMBER", (3, 18), (3, 28), tmp_path)


def test_int_clamp_min_above_max_points_at_the_call(tmp_path):
    check_span("int-clamp-range", "RUNTIME-INVALID-RANGE", (3, 8), (3, 21), tmp_path)
