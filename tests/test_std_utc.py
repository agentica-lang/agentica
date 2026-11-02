"""std/utc: the civil date and time in UTC of Unix milliseconds, and RFC 3339 text.

tests/fixtures/utc/driver.agc reads one JSON case per line of stdin and prints one JSON reply per line. Python's
datetime is the independent peer for the years 1 to 9999 (the leap days, the ends of every month, the edges of the
range, and a seeded random sample). Beyond that range datetime has no value, so a second peer, the days-from-civil
algorithm of Howard Hinnant written the other way round, checks that the parts of any Int convert back to the same
milliseconds.
"""
import json
import random
import re
from datetime import datetime, timedelta, timezone

import pytest

from tests.agentica_test import FIXTURES, compile_agc, run_vm

EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)
INT_MIN = -(2 ** 63)
INT_MAX = 2 ** 63 - 1
DAY_MS = 86_400_000
RANGE_LOW = -62_135_596_800_000  # 0001-01-01T00:00:00Z
RANGE_HIGH = 253_402_300_799_999  # 9999-12-31T23:59:59.999Z


@pytest.fixture(scope="module")
def driver(tmp_path_factory):
    return compile_agc(FIXTURES / "utc" / "driver.agc", tmp_path_factory.mktemp("agentica-utc-") / "driver.agcb")


def call(driver, cases):
    """Run [(ms, digits_or_None)] through the driver and return one reply dict per case."""
    lines = [json.dumps({"ms": ms, "digits": digits or 0, "has_digits": digits is not None}) for ms, digits in cases]
    result = run_vm(driver, stdin=("\n".join(lines) + "\n").encode("utf-8"))
    assert result.code == 0, result.stderr
    replies = [json.loads(line) for line in result.stdout.splitlines()]
    assert len(replies) == len(cases)
    return replies


def to_ms(moment):
    return (moment - EPOCH) // timedelta(milliseconds=1)


def peer_parts(ms):
    moment = EPOCH + timedelta(milliseconds=ms)
    return {"year": moment.year, "month": moment.month, "day": moment.day, "hour": moment.hour,
            "minute": moment.minute, "second": moment.second, "millisecond": moment.microsecond // 1000}


def peer_text(ms, digits):
    moment = EPOCH + timedelta(milliseconds=ms)
    fraction = f"{moment.microsecond // 1000:03d}".ljust(9, "0")[:digits]
    # strftime's %Y is not padded to four digits on every platform.
    return f"{moment.year:04d}" + moment.strftime("-%m-%dT%H:%M:%S") + (f".{fraction}" if digits else "") + "Z"


def edge_times():
    """The leap days, the ends of every month, and the edges of the range, each with a ms before and after."""
    times = set()
    for year in (1, 4, 1600, 1900, 1969, 1970, 1999, 2000, 2023, 2024, 2038, 2100, 2400, 9999):
        for month in range(1, 13):
            for day in (1, 27, 28, 29, 30, 31):
                try:
                    times.add(to_ms(datetime(year, month, day, tzinfo=timezone.utc)))
                except ValueError:
                    pass  # the month is shorter
        times.add(to_ms(datetime(year, 12, 31, 23, 59, 59, tzinfo=timezone.utc)) + 999)
    times.add(to_ms(datetime(1, 1, 1, tzinfo=timezone.utc)))
    times.update({-1, 0, 1, 999, 1000, DAY_MS - 1, DAY_MS, -DAY_MS, -DAY_MS - 1})
    return sorted(t for ms in times for t in (ms - 1, ms, ms + 1) if RANGE_LOW <= t <= RANGE_HIGH)


def test_parts_and_text_agree_with_datetime_on_the_edges_and_a_sample(driver):
    rng = random.Random(41)
    times = edge_times() + [rng.randint(RANGE_LOW, RANGE_HIGH) for _ in range(1500)]
    times += [rng.randint(-DAY_MS * 3, DAY_MS * 3) for _ in range(100)]
    replies = call(driver, [(ms, 0) for ms in times])
    for ms, reply in zip(times, replies):
        assert {k: reply[k] for k in peer_parts(ms)} == peer_parts(ms), ms
        assert reply["text"] == peer_text(ms, 0), ms


def test_fraction_digits_follow_iso8601_of_ruby(driver):
    times = [0, 1, 12, 345, 1000, 1_000_000_007, -1, -999, -1001, 1_790_000_002_345]
    cases = [(ms, digits) for ms in times for digits in range(0, 10)]
    for (ms, digits), reply in zip(cases, call(driver, cases)):
        assert reply["text"] == peer_text(ms, digits), (ms, digits)


def test_fraction_digits_out_of_range_are_clamped_and_the_default_is_none(driver):
    ms = 1_790_000_002_345
    texts = [r["text"] for r in call(driver, [(ms, None), (ms, -5), (ms, 10), (ms, 400)])]
    assert texts == ["2026-09-21T14:13:22Z", "2026-09-21T14:13:22Z", "2026-09-21T14:13:22.345000000Z",
                     "2026-09-21T14:13:22.345000000Z"]


def test_huge_digit_counts_are_clamped_and_return_at_once(driver):
    # A count is clamped before the zeros are written, so Int.max does not loop for ever (the run has a timeout).
    ms = 1_790_000_002_345
    texts = [r["text"] for r in call(driver, [(ms, INT_MAX), (ms, INT_MIN), (0, INT_MAX), (INT_MIN, INT_MAX)])]
    assert texts[0] == "2026-09-21T14:13:22.345000000Z"
    assert texts[1] == "2026-09-21T14:13:22Z"
    assert texts[2] == "1970-01-01T00:00:00.000000000Z"
    assert re.fullmatch(r"-\d{4,}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}0{6}Z", texts[3]), texts[3]


def test_years_outside_0_to_9999_have_a_sign_and_four_digits(driver):
    # The first ms of year 0 and of year 10000, then the ms before each, and a year before 0 and one past 9999.
    year_0, year_10000 = -62_167_219_200_000, 253_402_300_800_000
    cases = [(year_0, 3), (year_0 - 1, 3), (year_10000, 3), (year_10000 - 1, 3), (year_0 - 400 * 366 * DAY_MS, 0),
             (year_10000 + 400 * 366 * DAY_MS, 0)]
    texts = [r["text"] for r in call(driver, cases)]
    assert texts[:4] == ["0000-01-01T00:00:00.000Z", "-0001-12-31T23:59:59.999Z", "10000-01-01T00:00:00.000Z",
                         "9999-12-31T23:59:59.999Z"]
    assert texts[4].startswith("-04") and texts[5].startswith("10")


def days_from_civil(year, month, day):
    """Howard Hinnant's days_from_civil: days since 1970-01-01 of a proleptic Gregorian date."""
    year -= month <= 2
    era = year // 400
    yoe = year - era * 400
    doy = (153 * (month + (-3 if month > 2 else 9)) + 2) // 5 + day - 1
    doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def test_parts_of_any_int_convert_back_to_the_same_milliseconds(driver):
    rng = random.Random(7)
    times = [INT_MIN, INT_MIN + 1, INT_MAX, INT_MAX - 1] + [rng.randint(INT_MIN, INT_MAX) for _ in range(300)]
    times += [rng.randint(-10 ** 15, 10 ** 15) for _ in range(300)]
    for ms, reply in zip(times, call(driver, [(ms, None) for ms in times])):
        assert 1 <= reply["month"] <= 12 and 1 <= reply["day"] <= 31, ms
        days = days_from_civil(reply["year"], reply["month"], reply["day"])
        clock = ((reply["hour"] * 60 + reply["minute"]) * 60 + reply["second"]) * 1000 + reply["millisecond"]
        assert days * DAY_MS + clock == ms, ms
        assert reply["text"].endswith("Z") and ("-" in reply["text"][:1]) == (reply["year"] < 0), ms
