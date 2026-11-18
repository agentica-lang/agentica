"""The dates and times of the Time family through the product CLI: the types in every position, the constructors, the
conversions written as methods, and the rules that keep every value valid (no construction, no .with, no JSON) and
keep == off Time.DateTime. A case is
`(program, code, covered text)`: the code of the diagnostic and the source text its range covers; a program that must
check clean has no code.
"""

import pytest

from tests.spec_support import assert_rule, covered

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
    # A conversion is a method of its record, with or without parentheses, and a field of the record stays a field. A
    # lambda parameter with no type that calls one takes the record.
    (
        MAIN
        + "  a: Result[Time.DateTime] = Time.at(-1)\n"
        "  b: Result[Time.DateTime] = Time.at_us(-1)\n"
        "  now: Time.DateTime = Time.now()\n"
        "  utc: Result[Time.DateTime] = now.getutc\n"
        "  local: Result[Time.DateTime] = now.getlocal(-18000)\n"
        "  n: Time.NaiveDateTime = now.naive_of()\n"
        "  back: Result[Time.DateTime] = n.assume_offset(3600)\n"
        "  days: List[Time.Date] = [now.to_date, n.to_date()]\n"
        "  stamp = ->(t) { t.getutc }\n"
        "  sum: Int = now.to_i + now.to_us + now.year + stamp.call(now).unwrap!.hour\n"
        "  puts(\"#{a.ok?} #{b.ok?} #{utc.ok?} #{local.ok?} #{back.ok?} #{days.size} #{sum}\")\nend\n",
        None,
        None,
    ),
    # Each type writes its ISO 8601 text with iso8601 and reads it back with Type.iso8601(text), a Result.
    (
        MAIN
        + f"  a = {AWARE}\n"
        "  texts: List[String] = [a.iso8601, a.naive_of.iso8601(), a.to_date.iso8601, "
        "Time.TimeOfDay.new(1, 2, 3, 4).unwrap!.iso8601]\n"
        "  d: Result[Time.Date] = Time.Date.iso8601(texts[2])\n"
        "  t: Result[Time.TimeOfDay] = Time.TimeOfDay.iso8601(texts[3])\n"
        "  n: Result[Time.NaiveDateTime] = Time.NaiveDateTime.iso8601(texts[1])\n"
        "  b: Result[Time.DateTime] = Time.DateTime.iso8601(texts[0])\n"
        "  puts(\"#{d.ok?} #{t.ok?} #{n.ok?} #{b.ok?}\")\nend\n",
        None,
        None,
    ),
    # A field of a program's struct keeps a lambda parameter that reads it, though a record has a method of the name.
    (
        "struct Job\n  to_date: Int\n  getutc: Int\nend\n\n"
        + MAIN
        + "  f = ->(j) { j.to_date + j.getutc }\n  puts(f.call(Job(to_date: 1, getutc: 2)))\nend\n",
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
    # A conversion is a method of one record only, takes its own arguments, and a name the record lacks is a field it
    # lacks (without parentheses) or a method it lacks (with them).
    (MAIN + f"  d = {DATE}\n  puts(d.to_i)\nend\n", "CHECK-UNKNOWN-FIELD", "d.to_i"),
    (MAIN + "  n = Time.NaiveDateTime.new(1, 1, 1, 0, 0, 0, 0).unwrap!\n  puts(n.to_us())\nend\n",
     "CHECK-UNKNOWN-METHOD", "n.to_us()"),
    (MAIN + f"  a = {AWARE}\n  puts(a.to_i(3))\nend\n", "CHECK-ARITY", "a.to_i(3)"),
    (MAIN + f"  a = {AWARE}\n  b = a.getlocal(\"+02:00\")\nend\n", "CHECK-TYPE-MISMATCH", '"+02:00"'),
    (MAIN + f"  a = {AWARE}\n  puts(a.hours)\nend\n", "CHECK-UNKNOWN-FIELD", "a.hours"),
    (MAIN + f"  a = {AWARE}\n  puts(Time.to_i(a))\nend\n", "CHECK-UNKNOWN-NAME", "Time.to_i(a)"),
    (MAIN + "  a: Time.DateTime = Time.at(0)\nend\n", "CHECK-TYPE-MISMATCH", "Time.at(0)"),
    # The parse takes text and gives a Result; the text of a value takes no argument.
    (MAIN + f"  d = {DATE}\n  puts(Time.Date.iso8601(d))\nend\n", "CHECK-TYPE-MISMATCH", "d"),
    (MAIN + '  d: Time.Date = Time.Date.iso8601("2026-10-14")\nend\n', "CHECK-TYPE-MISMATCH",
     'Time.Date.iso8601("2026-10-14")'),
    (MAIN + f"  d = {DATE}\n  puts(d.iso8601(6))\nend\n", "CHECK-ARITY", "d.iso8601(6)"),
]


@pytest.mark.parametrize(("program", "code", "text"), CLEAN + REFUSED)
def test_time_rules(agentica_check, program, code, text):
    assert_rule(agentica_check(program), program, code, text)


def test_a_struct_field_that_holds_a_datetime_is_labeled_where_equality_is_refused(agentica_check):
    program = "struct Meeting\n  at: Time.DateTime\nend\n\n" + MAIN + f"  m = Meeting(at: {AWARE})\n  puts(m == m)\nend\n"
    found = agentica_check(program)
    assert_rule(found, program, "CHECK-TYPE-MISMATCH", "==")
    assert [covered(program, label["range"]) for label in found["labels"]] == ["at: Time.DateTime\n"]


def test_a_misplaced_conversion_names_its_method_form(agentica_check):
    found = agentica_check(MAIN + f"  a = {AWARE}\n  puts(Time.to_i(a))\nend\n")
    assert found["code"] == "CHECK-UNKNOWN-NAME"
    assert "a.to_i" not in found["help"] and "value.to_i" in found["help"], found["help"]
    unknown = agentica_check(MAIN + f"  a = {AWARE}\n  puts(a.foo())\nend\n")
    assert "to_i" in unknown["help"] and "getlocal" in unknown["help"], unknown["help"]


def test_an_unknown_field_of_a_record_with_methods_lists_its_methods(agentica_check):
    naive = agentica_check(MAIN + "  n = Time.NaiveDateTime.new(1, 1, 1, 0, 0, 0, 0).unwrap!\n  puts(n.getutc)\nend\n")
    assert naive["code"] == "CHECK-UNKNOWN-FIELD"
    assert "assume_offset" in naive["help"] and "to_date" in naive["help"], naive["help"]
    typo = agentica_check(MAIN + f"  a = {AWARE}\n  puts(a.yeer)\nend\n")
    assert "\"year\"" in typo["help"] and "getlocal" in typo["help"], typo["help"]
