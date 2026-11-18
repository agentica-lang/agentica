"""The constructors and calendar queries of the Time family (#985) against Python's datetime and calendar.

tests/fixtures/time/driver.agc reads one JSON case per line and prints one reply per line. Python is the independent
peer: `datetime.date`, `datetime.time` and `datetime.datetime` accept exactly the real days and clock readings of the
years 1 to 9999 (proleptic Gregorian, no leap seconds), and `calendar` has the leap rule and the length of each month.
The one rule Python lacks is the offset: Agentica takes whole minutes of less than a day, where Python takes any
timedelta under a day. Hypothesis draws the fields from the edges of each range and from the whole Int range.

The profiles and the seed of each tier are in tests/conftest.py.
"""
import calendar
from datetime import date, datetime, time, timedelta, timezone
from importlib.util import find_spec

import pytest

from tests.agentica_test import FIXTURES, compile_agc, require, run_json_cases

require(find_spec("hypothesis") is not None, "hypothesis is required (poetry install --only test --no-root)")

from hypothesis import given, strategies as st  # noqa: E402

INT_MIN = -(2 ** 63)
INT_MAX = 2 ** 63 - 1
OFFSET_MAX = 23 * 3600 + 59 * 60


@pytest.fixture(scope="module")
def driver(tmp_path_factory):
    return compile_agc(FIXTURES / "time" / "driver.agc", tmp_path_factory.mktemp("agentica-time-") / "driver.agcb")


def near(*edges):
    """Ints at and around the edges of a range, and any Int."""
    return st.sampled_from([e + d for e in edges for d in (-1, 0, 1)]) | st.integers(INT_MIN, INT_MAX)


YEARS = near(1, 4, 100, 400, 1900, 2000, 2024, 9999) | st.integers(1, 9999)
MONTHS = near(1, 2, 12) | st.integers(1, 12)
DAYS = near(1, 28, 29, 30, 31) | st.integers(1, 31)
HOURS = near(0, 23) | st.integers(0, 23)
MINUTES = near(0, 59) | st.integers(0, 59)
SECONDS = near(0, 59, 60) | st.integers(0, 59)
USECS = near(0, 999_999) | st.integers(0, 999_999)
OFFSETS = (near(-OFFSET_MAX, OFFSET_MAX, 0, -60, 60, 30, 86_400, -86_400)
           | st.integers(-OFFSET_MAX // 60, OFFSET_MAX // 60).map(lambda m: m * 60)
           | st.integers(-90_000, 90_000))
VALID_OFFSETS = st.integers(-OFFSET_MAX // 60, OFFSET_MAX // 60).map(lambda m: m * 60)
DATE_EDGES = (YEARS, MONTHS, DAYS)
CLOCK_EDGES = (HOURS, MINUTES, SECONDS, USECS)


@st.composite
def fields(draw, valid, edges):
    """A valid tuple of fields; one time in three, one field of it is replaced by an edge of its range or any Int."""
    values = list(draw(valid))
    if draw(st.integers(0, 2)) == 0:
        at = draw(st.integers(0, len(values) - 1))
        values[at] = draw(edges[at])
    return tuple(values)


def clock(t):
    return (t.hour, t.minute, t.second, t.microsecond)


VALID_DATES = st.dates().map(lambda d: (d.year, d.month, d.day))
VALID_NAIVE = st.datetimes().map(lambda t: (t.year, t.month, t.day, *clock(t)))


def peer(build):
    """The fields Python builds, or None when it refuses them."""
    try:
        return build()
    except (ValueError, OverflowError):
        return None


def peer_date(y, mo, d):
    return peer(lambda: [*date(y, mo, d).timetuple()[:3]])


def peer_clock(h, mi, s, us):
    value = peer(lambda: time(h, mi, s, us))
    return value and [value.hour, value.minute, value.second, value.microsecond]


def peer_naive(y, mo, d, h, mi, s, us):
    value = peer(lambda: datetime(y, mo, d, h, mi, s, us))
    return value and [value.year, value.month, value.day, value.hour, value.minute, value.second, value.microsecond]


def peer_datetime(y, mo, d, h, mi, s, us, off):
    if off % 60 != 0 or abs(off) > OFFSET_MAX:
        return None
    value = peer(lambda: datetime(y, mo, d, h, mi, s, us, tzinfo=timezone(timedelta(seconds=off))))
    return value and peer_naive(y, mo, d, h, mi, s, us) + [int(value.utcoffset().total_seconds())]


def peer_days_in_month(y, mo):
    if not (1 <= y <= 9999 and 1 <= mo <= 12):
        return None
    return [calendar.monthrange(y, mo)[1]]


def peer_leap(y):
    return [int(calendar.isleap(y))]


PEERS = {
    "date": peer_date,
    "time_of_day": peer_clock,
    "naive": peer_naive,
    "datetime": peer_datetime,
    "days_in_month": peer_days_in_month,
    "leap": peer_leap,
}

CASES = (
    st.tuples(st.just("date"), fields(VALID_DATES, DATE_EDGES))
    | st.tuples(st.just("time_of_day"), fields(st.times().map(clock), CLOCK_EDGES))
    | st.tuples(st.just("naive"), fields(VALID_NAIVE, DATE_EDGES + CLOCK_EDGES))
    | st.tuples(st.just("datetime"), fields(st.tuples(VALID_NAIVE, VALID_OFFSETS).map(lambda p: (*p[0], p[1])),
                                             DATE_EDGES + CLOCK_EDGES + (OFFSETS,)))
    | st.tuples(st.just("days_in_month"), st.tuples(YEARS, MONTHS))
    | st.tuples(st.just("leap"), st.tuples(YEARS))
)
VERDICT_OPS = ("date", "time_of_day", "naive", "datetime", "days_in_month")


def check(driver, cases, verdicts=None):
    """Run the cases and compare each reply with the peer; count the verdicts by (op, ok) in `verdicts`."""
    replies = run_json_cases(driver, [{"op": op, "args": list(args)} for op, args in cases])
    for (op, args), reply in zip(cases, replies):
        expected = PEERS[op](*args)
        if expected is None:
            assert (reply["ok"], reply["kind"]) == (False, "argument"), (op, args, reply)
        else:
            assert (reply["ok"], reply["fields"]) == (True, expected), (op, args, reply)
        if verdicts is not None:
            verdicts[op, reply["ok"]] = verdicts.get((op, reply["ok"]), 0) + 1


def test_constructors_and_queries_agree_with_python(driver):
    verdicts = {}

    @given(st.lists(CASES, min_size=50, max_size=300))
    def agree(cases):
        check(driver, cases, verdicts)

    agree()
    # Both answers of every constructor come up many times, so the draws keep reaching each check and its absence.
    thin = {key: verdicts.get(key, 0) for key in [(op, ok) for op in VERDICT_OPS for ok in (True, False)]
            if verdicts.get(key, 0) < 100}
    assert thin == {}, verdicts


def test_every_day_of_the_leap_cycle_and_the_ends_of_the_range(driver):
    cases = [("date", (y, mo, d)) for y in (1, 4, 100, 400, 1900, 2000, 2023, 2024, 9999)
             for mo in range(0, 14) for d in range(0, 33)]
    cases += [("leap", (y,)) for y in (INT_MIN, INT_MIN + 1, -400, -100, -4, -1, 0, INT_MAX, INT_MAX - 1)]
    check(driver, cases)


def test_the_first_and_last_instants_at_the_widest_offsets(driver):
    corners = [(1, 1, 1, 0, 0, 0, 0), (9999, 12, 31, 23, 59, 59, 999_999)]
    offsets = (-86_340, -86_341, -86_400, 0, 86_340, 86_341, 86_400)
    replies = run_json_cases(driver, [{"op": "datetime", "args": [*c, o]} for c in corners for o in offsets])
    assert [r["ok"] for r in replies] == [True, False, False, True, True, False, False] * 2
    check(driver, [("datetime", (*c, o)) for c in corners for o in offsets])
