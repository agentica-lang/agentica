"""The dates and times of the Time family through the product CLI: the types in every position, the constructors, and
the rules that keep every value valid (no construction, no .with, no JSON) and keep == off Time.DateTime. A case is
`(program, code, covered text)`: the code of the diagnostic and the source text its range covers; a program that must
check clean has no code.
"""

import pytest

from tests.spec_support import assert_rule

MAIN = "def main() -> Void\n"
DATE = "Time.Date.new(2026, 10, 14).unwrap!"
AWARE = "Time.DateTime.new(2026, 10, 14, 19, 5, 42, 0, 7200).unwrap!"
EVENT = "struct Event\n  at: Time.Date\nend\n\n"

CLEAN = [
    # The types in a parameter, a result, a field and a list; the fields read as Ints; each constructor and query.
    (
        EVENT
        + "def later(d: Time.Date, t: Time.TimeOfDay) -> List[Time.Date]\n  return [d]\nend\n\n"
        + MAIN
        + f"  d: Time.Date = {DATE}\n"
        "  t: Result[Time.TimeOfDay] = Time.TimeOfDay.new(19, 5, 42, 201337)\n"
        "  n: Result[Time.NaiveDateTime] = Time.NaiveDateTime.new(2026, 10, 14, 19, 5, 42, 201337)\n"
        f"  a: Time.DateTime = {AWARE}\n"
        "  e = Event(at: d)\n"
        "  days: Result[Int] = Time.Date.days_in_month(2026, 2)\n"
        "  leap: Bool = Time.Date.leap?(2024)\n"
        "  sum: Int = d.year + d.month + d.day + a.hour + a.min + a.sec + a.usec + a.utc_offset + e.at.day\n"
        "  puts(\"#{later(d, t.unwrap!).size} #{n.ok?} #{days.ok?} #{leap} #{sum} #{a}\")\nend\n",
        None,
        None,
    ),
    # The three types with one reading per value keep ==, alone and inside other values.
    (
        MAIN + f"  d = {DATE}\n"
        "  t = Time.TimeOfDay.new(1, 2, 3, 4).unwrap!\n"
        "  n = Time.NaiveDateTime.new(2026, 10, 14, 1, 2, 3, 4).unwrap!\n"
        "  _ = Test.eq(n, n)\n"
        "  puts(d == d and t == t and n == n and [d].include?(d))\nend\n",
        None,
        None,
    ),
    # A user type of the same name is not the builtin one, and a variant may be named Date or DateTime.
    (
        "struct Date\n  day: Int\nend\n\nenum Value\n  Date(Int)\n  DateTime(String)\nend\n\n"
        + MAIN
        + "  puts(Date(day: 1).day)\n  puts(Value.Date(1))\nend\n",
        None,
        None,
    ),
]

REFUSED = [
    # Only the constructors build a value: no construction and no .with.
    (MAIN + "  d = Time.Date(year: 2026, month: 13, day: 1)\nend\n", "CHECK-NOT-CONSTRUCTIBLE",
     "Time.Date(year: 2026, month: 13, day: 1)"),
    (MAIN + "  t = Time.TimeOfDay(hour: 25, min: 0, sec: 0, usec: 0)\nend\n", "CHECK-NOT-CONSTRUCTIBLE",
     "Time.TimeOfDay(hour: 25, min: 0, sec: 0, usec: 0)"),
    (MAIN + f"  d = {DATE}\n  e = d.with(month: 13)\nend\n", "CHECK-NOT-CONSTRUCTIBLE", "d.with(month: 13)"),
    (MAIN + f"  a = {AWARE}\n  b = a.with(utc_offset: 30)\nend\n", "CHECK-NOT-CONSTRUCTIBLE",
     "a.with(utc_offset: 30)"),
    # == on Time.DateTime would compare readings, not instants: alone, in a field and through a builtin.
    (MAIN + f"  a = {AWARE}\n  puts(a == a)\nend\n", "CHECK-TYPE-MISMATCH", "=="),
    (
        "struct Meeting\n  at: Time.DateTime\nend\n\n" + MAIN + f"  m = Meeting(at: {AWARE})\n  puts(m != m)\nend\n",
        "CHECK-TYPE-MISMATCH",
        "!=",
    ),
    (MAIN + f"  a = [{AWARE}]\n  puts(a.include?(a[0]))\nend\n", "CHECK-TYPE-MISMATCH", "a"),
    # JSON neither writes nor builds one, alone or inside a struct, and no codec or schema has one.
    (MAIN + f"  puts(JSON.encode({DATE}))\nend\n", "CHECK-NOT-ENCODABLE", DATE),
    (EVENT + MAIN + f"  puts(JSON.encode(Event(at: {DATE})))\nend\n", "CHECK-NOT-ENCODABLE", f"Event(at: {DATE})"),
    (MAIN + '  puts(JSON.decode("{}", Time.DateTime).ok?)\nend\n', "CHECK-NOT-DECODABLE", "Time.DateTime"),
    (EVENT + MAIN + '  puts(JSON.decode("{}", Event).ok?)\nend\n', "CHECK-NOT-DECODABLE", "Event"),
    (MAIN + "  puts(JSON.schema(Time.TimeOfDay))\nend\n", "CHECK-NOT-DECODABLE", "Time.TimeOfDay"),
    (MAIN + "  puts(Time.NaiveDateTime.codec)\nend\n", "CHECK-NOT-DECODABLE", "Time.NaiveDateTime"),
    # The constructors take Ints and give a Result; a misspelled member or function has the closest name.
    (MAIN + "  d: Time.Date = Time.Date.new(2026, 10, 14)\nend\n", "CHECK-TYPE-MISMATCH",
     "Time.Date.new(2026, 10, 14)"),
    (MAIN + '  d = Time.Date.new(2026, "10", 14)\nend\n', "CHECK-TYPE-MISMATCH", '"10"'),
    (MAIN + "  d = Time.Date.nwe(2026, 10, 14)\nend\n", "CHECK-UNKNOWN-NAME", "Time.Date.nwe(2026, 10, 14)"),
    (MAIN + "  d = Time.Dat.new(2026, 10, 14)\nend\n", "CHECK-UNKNOWN-NAME", "Time.Dat"),
]


@pytest.mark.parametrize(("program", "code", "text"), CLEAN + REFUSED)
def test_time_rules(agentica_check, program, code, text):
    assert_rule(agentica_check(program), program, code, text)
