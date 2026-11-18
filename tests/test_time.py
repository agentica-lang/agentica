"""The constructors, calendar queries, conversions and ISO 8601 text of the Time family (#985) against Python's
datetime and calendar.

tests/fixtures/time/driver.agc reads one JSON case per line and prints one reply per line. Python is the independent
peer: `datetime.date`, `datetime.time` and `datetime.datetime` accept exactly the real days and clock readings of the
years 1 to 9999 (proleptic Gregorian, no leap seconds), and `calendar` has the leap rule and the length of each month.
The one rule Python lacks is the offset: Agentica takes whole minutes of less than a day, where Python takes any
timedelta under a day. Hypothesis draws the fields from the edges of each range and from the whole Int range.
Unix time is a timedelta from the epoch, which Python divides with floor division, as Ruby's Time#to_i rounds; a sum
that leaves the years 1 to 9999 overflows in Python as it errs in Agentica. The text is Python's isoformat with Z for
+00:00; Python's fromisoformat reads more forms than the strict ones of Agentica, so the peer of a parse first matches
the strict form with a regular expression and only then asks fromisoformat.

The profiles and the seed of each tier are in tests/conftest.py.
"""
import calendar
import re
import time as clock_time
from datetime import date, datetime, time, timedelta, timezone
from importlib.util import find_spec

import pytest

from tests.agentica_test import FIXTURES, compile_agc, require, run_json_cases

require(find_spec("hypothesis") is not None, "hypothesis is required (poetry install --only test --no-root)")

from hypothesis import given, strategies as st  # noqa: E402

INT_MIN = -(2 ** 63)
INT_MAX = 2 ** 63 - 1
OFFSET_MAX = 23 * 3600 + 59 * 60
EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)
FIRST_S, LAST_S = -62_135_596_800, 253_402_300_799
FIRST_US, LAST_US = FIRST_S * 1_000_000, LAST_S * 1_000_000 + 999_999
SECOND, MICROSECOND = timedelta(seconds=1), timedelta(microseconds=1)


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


def naive_tuple(t):
    return (t.year, t.month, t.day, *clock(t))


VALID_DATES = st.dates().map(lambda d: (d.year, d.month, d.day))
VALID_NAIVE = st.datetimes().map(naive_tuple)
# Readings within a day of the ends of the range, where a change of offset may leave it; Hypothesis favors short
# timedeltas, so most are close to an end.
WITHIN_A_DAY = st.timedeltas(min_value=timedelta(0), max_value=timedelta(days=1) - MICROSECOND)
EDGE_NAIVE = (WITHIN_A_DAY.map(lambda d: datetime.min + d) | WITHIN_A_DAY.map(lambda d: datetime.max - d)).map(
    naive_tuple)
EDGE_AWARE = st.tuples(EDGE_NAIVE, VALID_OFFSETS).map(lambda p: (*p[0], p[1]))
VALID_AWARE = st.tuples(VALID_NAIVE | EDGE_NAIVE, VALID_OFFSETS).map(lambda p: (*p[0], p[1]))
# Hypothesis favors small Ints, which are all in range for at_us, so the Ints past each end get a branch of their own.
SECONDS_SINCE = near(FIRST_S, LAST_S, 0) | st.integers(FIRST_S, LAST_S)
US_SINCE = (near(FIRST_US, LAST_US, 0, -1_000_000) | st.integers(FIRST_US, LAST_US)
            | st.integers(INT_MIN, FIRST_US - 1) | st.integers(LAST_US + 1, INT_MAX))


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


def aware(y, mo, d, h, mi, s, us, off):
    return datetime(y, mo, d, h, mi, s, us, tzinfo=timezone(timedelta(seconds=off)))


def aware_fields(value):
    return [*naive_tuple(value), int(value.utcoffset().total_seconds())]


def peer_since(**delta):
    value = peer(lambda: EPOCH + timedelta(**delta))
    return value and aware_fields(value)


def peer_getlocal(*args):
    *fields, off = args
    if off % 60 != 0 or abs(off) > OFFSET_MAX:
        return None
    # astimezone passes through UTC, which may leave the range when the reading does not: shift the reading instead.
    value = peer(lambda: datetime(*fields[:7]) + timedelta(seconds=off - fields[7]))
    return value and [*naive_tuple(value), off]


def peer_assume_offset(*args):
    *fields, off = args
    return peer_datetime(*fields, off)


PEERS |= {
    "at": lambda s: peer_since(seconds=s),
    "at_us": lambda us: peer_since(microseconds=us),
    "to_i": lambda *a: [(aware(*a) - EPOCH) // SECOND],
    "to_us": lambda *a: [(aware(*a) - EPOCH) // MICROSECOND],
    "getlocal": peer_getlocal,
    "getutc": lambda *a: peer_getlocal(*a, 0),
    "assume_offset": peer_assume_offset,
    "naive_of": lambda *a: list(a[:7]),
    "to_date": lambda *a: [*aware(*a).date().timetuple()[:3]],
    "naive_to_date": lambda *a: list(a[:3]),
}

CONVERSIONS = (
    st.tuples(st.just("at"), st.tuples(SECONDS_SINCE))
    | st.tuples(st.just("at_us"), st.tuples(US_SINCE))
    | st.tuples(st.sampled_from(["to_i", "to_us", "naive_of", "to_date"]), VALID_AWARE)
    | st.tuples(st.just("getutc"), EDGE_AWARE | VALID_AWARE)
    | st.tuples(st.just("getlocal"), st.tuples(VALID_AWARE, VALID_OFFSETS | OFFSETS).map(lambda p: (*p[0], p[1])))
    | st.tuples(st.just("assume_offset"), st.tuples(VALID_NAIVE | EDGE_NAIVE, VALID_OFFSETS | OFFSETS).map(
        lambda p: (*p[0], p[1])))
    | st.tuples(st.just("naive_to_date"), VALID_NAIVE)
)
CONVERSION_VERDICTS = ("at", "at_us", "getlocal", "getutc", "assume_offset")


def request(op, args):
    """The JSON case of the driver: a parse takes its one argument as the text, every other op takes Ints."""
    if op.startswith("parse_"):
        return {"op": op, "args": [], "text": args[0]}
    return {"op": op, "args": list(args), "text": ""}


def check(driver, cases, verdicts=None):
    """Run the cases and compare each reply with the peer, fields or text; count the verdicts by (op, ok) in
    `verdicts`."""
    replies = run_json_cases(driver, [request(op, args) for op, args in cases])
    for (op, args), reply in zip(cases, replies):
        expected = PEERS[op](*args)
        if expected is None:
            assert (reply["ok"], reply["kind"]) == (False, "argument"), (op, args, reply)
        elif isinstance(expected, str):
            assert (reply["ok"], reply["text"]) == (True, expected), (op, args, reply)
        else:
            assert (reply["ok"], reply["fields"]) == (True, expected), (op, args, reply)
        if verdicts is not None:
            verdicts[op, reply["ok"]] = verdicts.get((op, reply["ok"]), 0) + 1


def agree(driver, cases, ops):
    """Hypothesis lists of cases agree with the peer, and both answers of each op in `ops` come up many times, so the
    draws keep reaching each check and its absence."""
    verdicts = {}

    @given(st.lists(cases, min_size=50, max_size=300))
    def run(drawn):
        check(driver, drawn, verdicts)

    run()
    thin = {key: verdicts.get(key, 0) for key in [(op, ok) for op in ops for ok in (True, False)]
            if verdicts.get(key, 0) < 100}
    assert thin == {}, verdicts


def test_constructors_and_queries_agree_with_python(driver):
    agree(driver, CASES, VERDICT_OPS)


def test_conversions_agree_with_python(driver):
    agree(driver, CONVERSIONS, CONVERSION_VERDICTS)


def test_unix_time_at_the_ends_of_the_range_and_before_1970(driver):
    seconds = (INT_MIN, FIRST_S - 1, FIRST_S, -86_401, -1, 0, 1, LAST_S, LAST_S + 1, INT_MAX)
    us = (INT_MIN, FIRST_US - 1, FIRST_US, -1_000_001, -1_000_000, -999_999, -1, 0, LAST_US, LAST_US + 1, INT_MAX)
    cases = [("at", (s,)) for s in seconds] + [("at_us", (u,)) for u in us]
    check(driver, cases)
    replies = run_json_cases(driver, [request(op, args) for op, args in cases])
    built = {(op, args[0]): reply["fields"] for (op, args), reply in zip(cases, replies) if reply["ok"]}
    assert sorted(value for op, value in built if op == "at") == [FIRST_S, -86_401, -1, 0, 1, LAST_S]
    assert sorted(value for op, value in built if op == "at_us") == [
        FIRST_US, -1_000_001, -1_000_000, -999_999, -1, 0, LAST_US]
    check(driver, [(op, tuple(fields)) for fields in built.values() for op in ("to_i", "to_us", "getutc")])
    # to_i rounds toward minus infinity: the microsecond before the epoch is in second -1, as in Ruby and Python.
    instants = [built["at_us", u] for u in (-1_000_001, -1_000_000, -999_999, -1)]
    to_i = run_json_cases(driver, [request("to_i", fields) for fields in instants])
    assert [r["fields"] for r in to_i] == [[-2], [-1], [-1], [-1]]


def test_now_is_the_wall_clock_in_utc(driver):
    before = clock_time.time_ns() // 1000
    reply = run_json_cases(driver, [request("now", [])])[0]
    after = clock_time.time_ns() // 1000
    *fields, us = reply["fields"]
    assert fields[7] == 0
    assert before <= us <= after
    assert PEERS["to_us"](*fields) == [us]


def test_every_day_of_the_leap_cycle_and_the_ends_of_the_range(driver):
    cases = [("date", (y, mo, d)) for y in (1, 4, 100, 400, 1900, 2000, 2023, 2024, 9999)
             for mo in range(0, 14) for d in range(0, 33)]
    cases += [("leap", (y,)) for y in (INT_MIN, INT_MIN + 1, -400, -100, -4, -1, 0, INT_MAX, INT_MAX - 1)]
    check(driver, cases)


def test_the_first_and_last_instants_at_the_widest_offsets(driver):
    corners = [(1, 1, 1, 0, 0, 0, 0), (9999, 12, 31, 23, 59, 59, 999_999)]
    offsets = (-86_340, -86_341, -86_400, 0, 86_340, 86_341, 86_400)
    replies = run_json_cases(driver, [request("datetime", [*c, o]) for c in corners for o in offsets])
    assert [r["ok"] for r in replies] == [True, False, False, True, True, False, False] * 2
    check(driver, [("datetime", (*c, o)) for c in corners for o in offsets])


def iso_offset(off):
    return "Z" if off == 0 else timedelta_text(off)


def timedelta_text(off):
    sign = "-" if off < 0 else "+"
    minutes = abs(off) // 60
    return f"{sign}{minutes // 60:02d}:{minutes % 60:02d}"


def peer_format(value):
    text = value.isoformat(timespec="microseconds") if not isinstance(value, date) or isinstance(value, datetime) \
        else value.isoformat()
    return text[:-6] + "Z" if text.endswith("+00:00") else text


CLOCK_TEXT = r"([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]+))?"
DATE_TEXT = r"[0-9]{4}-[0-9]{2}-[0-9]{2}"
STRICT = {
    "parse_date": re.compile(f"({DATE_TEXT})", re.ASCII),
    "parse_time_of_day": re.compile(CLOCK_TEXT, re.ASCII),
    "parse_naive": re.compile(f"({DATE_TEXT})[Tt]{CLOCK_TEXT}", re.ASCII),
    "parse_datetime": re.compile(f"({DATE_TEXT})[Tt]{CLOCK_TEXT}([Zz]|[+-]([0-9]{{2}}):([0-9]{{2}}))", re.ASCII),
}


def peer_parse(op, text):
    """The fields Python reads from the strict form of the text, or None. The fraction is cut to six digits and the
    offset hours and minutes checked here, which are rules of RFC 3339 that fromisoformat does not keep."""
    match = STRICT[op].fullmatch(text)
    if match is None:
        return None
    groups = match.groups()
    if op == "parse_date":
        return peer(lambda: [*date.fromisoformat(groups[0]).timetuple()[:3]])
    at = 0 if op == "parse_time_of_day" else 1
    clock_text = ":".join(groups[at:at + 3]) + "." + (groups[at + 3] or "")[:6].ljust(6, "0")
    if op == "parse_time_of_day":
        return peer(lambda: list(clock(time.fromisoformat(clock_text))))
    naive = peer(lambda: datetime.fromisoformat(f"{groups[0]}T{clock_text}"))
    if naive is None or op == "parse_naive":
        return naive and list(naive_tuple(naive))
    if groups[5] in "Zz":
        return [*naive_tuple(naive), 0]
    hours, minutes = int(groups[6]), int(groups[7])
    if hours > 23 or minutes > 59:
        return None
    sign = -1 if groups[5][0] == "-" else 1
    return [*naive_tuple(naive), sign * (hours * 3600 + minutes * 60)]


PEERS |= {
    "format_date": lambda *a: peer_format(date(*a)),
    "format_time_of_day": lambda *a: peer_format(time(*a)),
    "format_naive": lambda *a: peer_format(datetime(*a)),
    "format_datetime": lambda *a: peer_format(aware(*a)),
    **{op: (lambda text, op=op: peer_parse(op, text)) for op in STRICT},
}

FORMATS = (
    st.tuples(st.just("format_date"), VALID_DATES)
    | st.tuples(st.just("format_time_of_day"), st.times().map(clock))
    | st.tuples(st.just("format_naive"), VALID_NAIVE | EDGE_NAIVE)
    | st.tuples(st.just("format_datetime"), VALID_AWARE)
)


@st.composite
def spelled(draw):
    """A parse case: the text of a valid value spelled any way the strict form allows (case of T and Z, -00:00, from
    no to many fraction digits), then one time in two broken by a change of one character or a field out of range."""
    y, mo, d, h, mi, s, us, off = draw(VALID_AWARE)
    day = f"{y:04d}-{mo:02d}-{d:02d}"
    fraction = draw(st.sampled_from(["", f".{us:06d}", f".{us:06d}" + draw(st.text("0123456789", max_size=12)),
                                     f".{us:06d}"[:draw(st.integers(2, 6))]]))
    clock_text = f"{h:02d}:{mi:02d}:{s:02d}{fraction}"
    zone = draw(st.sampled_from([iso_offset(off), "z" if off == 0 else timedelta_text(off), "-00:00"]))
    t = draw(st.sampled_from("Tt"))
    op, text = draw(st.sampled_from([("parse_date", day), ("parse_time_of_day", clock_text),
                                     ("parse_naive", f"{day}{t}{clock_text}"),
                                     ("parse_datetime", f"{day}{t}{clock_text}{zone}")]))
    if draw(st.booleans()):
        at = draw(st.integers(0, len(text)))
        change = draw(st.sampled_from(["replace", "insert", "delete", "field"]))
        if change == "field":
            digits = [i for i, c in enumerate(text) if c.isdigit()]
            at = draw(st.sampled_from(digits))
            text = text[:at] + draw(st.sampled_from("0569")) + text[at + 1:]
        elif change == "delete":
            text = text[:at] + text[at + 1:]
        else:
            new = draw(st.sampled_from([chr(c) for c in range(128)] + ["é", "\u0663"]))
            text = text[:at] + new + text[at + (change == "replace"):]
    return op, (text,)


PARSE_VERDICTS = tuple(STRICT)


def test_parses_agree_with_python(driver):
    agree(driver, spelled(), PARSE_VERDICTS)


@given(st.lists(FORMATS, min_size=1, max_size=100))
def test_the_text_is_pythons_and_a_parse_of_it_gives_the_value_back(driver, cases):
    check(driver, cases)
    texts = run_json_cases(driver, [request(op, args) for op, args in cases])
    parsed = run_json_cases(driver, [request(op.replace("format_", "parse_"), [reply["text"]])
                                     for (op, _), reply in zip(cases, texts)])
    assert [reply["fields"] for reply in parsed] == [list(args) for _, args in cases]


@given(st.lists(st.tuples(st.sampled_from(PARSE_VERDICTS), st.tuples(st.text(max_size=40))), max_size=100))
def test_any_text_parses_or_is_refused_as_an_argument(driver, cases):
    check(driver, cases)


# Forms that Python's fromisoformat reads and RFC 3339 or the strict ISO 8601 form does not.
PYTHON_ONLY = [
    ("parse_datetime", "2026-10-14 19:05:42Z"),
    ("parse_datetime", "2026-10-14T19:05:42+0200"),
    ("parse_datetime", "2026-10-14T19:05:42+02"),
    ("parse_datetime", "2026-10-14T19:05:42+02:00:30"),
    ("parse_datetime", "2026-10-14T19:05Z"),
    ("parse_datetime", "2026-10-14T19Z"),
    ("parse_datetime", "20261014T190542Z"),
    ("parse_datetime", "2026-10-14T19:05:42,5Z"),
    ("parse_datetime", "2026-10-14T19:05:42"),
    ("parse_naive", "2026-10-14T19:05:42+02:00"),
    ("parse_naive", "2026-10-14T19:05:42Z"),
    ("parse_naive", "2026-10-14"),
    ("parse_naive", "2026-10-14 19:05:42"),
    ("parse_date", "20261014"),
    ("parse_date", "2026-W42-3"),
    ("parse_date", "2026-10-14T00:00:00"),
    ("parse_time_of_day", "19:05"),
    ("parse_time_of_day", "190542"),
    ("parse_time_of_day", "19:05:42Z"),
    ("parse_time_of_day", "19:05:42+02:00"),
    ("parse_time_of_day", "T19:05:42"),
]
# Control characters that differ from a separator in one bit (CR is "-" | 0x20, SUB is ":" | 0x20).
CONTROLS = [
    ("parse_date", "2026\r10\r14"),
    ("parse_time_of_day", "19\x1a05\x1a42"),
    ("parse_datetime", "2026\r10-14T19:05\x1a42Z"),
    ("parse_datetime", "2026-10-14T19:05:42\x1a"),
]


def test_forms_python_reads_and_control_characters_are_refused(driver):
    cases = PYTHON_ONLY + CONTROLS
    replies = run_json_cases(driver, [request(op, [text]) for op, text in cases])
    assert [(reply["ok"], reply["kind"]) for reply in replies] == [(False, "argument")] * len(cases)
    check(driver, [(op, (text,)) for op, text in cases])
