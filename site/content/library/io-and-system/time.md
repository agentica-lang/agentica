---
title: Dates and times
weight: 9
description: Calendar dates, times of day and date-times with a fixed UTC offset, as checked values of the Time family, with Unix time, the wall clock, arithmetic and ISO 8601 text.
---

The `Time` family has four record types. Their fields are `Int`s, named as in Ruby's `Time`:

- `Time.Date`: a day of the calendar (`year`, `month`, `day`).
- `Time.TimeOfDay`: a clock reading with no date and no offset (`hour`, `min`, `sec`, `usec`).
- `Time.NaiveDateTime`: a date and a clock reading with no offset, so it names no instant (`year`, `month`, `day`, `hour`, `min`, `sec`, `usec`).
- `Time.DateTime`: a date and a clock reading at a fixed offset from UTC, so it names one instant (the fields of `Time.NaiveDateTime`, then `utc_offset`, in seconds east of UTC).

The calendar is the proleptic Gregorian one, with the years 1 to 9999. The precision is microseconds (`usec`, 0 to 999999). Unix time has no leap seconds, so a `sec` of 60 is an error. An offset is whole minutes, from `-86340` (`-23:59`) to `86340` (`+23:59`); there are no named time zones and no daylight saving time. The fields of a `Time.DateTime` are the reading at its offset.

Every value is valid, because only the builtins below build one: writing `Time.Date(year: ..., ...)` or `d.with(...)` is `CHECK-NOT-CONSTRUCTIBLE`. `JSON.encode` and `JSON.decode` refuse these types, alone or inside a struct (`CHECK-NOT-ENCODABLE`, `CHECK-NOT-DECODABLE`). `==` compares a `Time.Date`, a `Time.TimeOfDay` or a `Time.NaiveDateTime` field by field. A `Time.DateTime` has no `==` (`CHECK-TYPE-MISMATCH`): two readings of one instant at different offsets differ in their fields, so compare instants with `Time.compare(a, b) == 0`. `Test.eq` still compares two of them field by field, so a test asserts the exact reading.

A builtin that takes one of these values first is written as a method of it: `t.to_i`, `t.getlocal(3600)`. Without arguments the parentheses are optional, as for a field.

`Time.now` reads the wall clock; the other clocks are on [System, Time and Random](/library/io-and-system/system/).

## Time.Date.new

```signature
Time.Date.new(year: Int, month: Int, day: Int) -> Result[Time.Date]
```

The date, or an error of kind `argument` when it is not a real day: a year outside 1 to 9999, a month outside 1 to 12, or a day the month does not have.

```agentica
def main() -> Void
  d = Time.Date.new(2024, 2, 29).unwrap!
  puts("#{d.year} #{d.month} #{d.day}")
  puts(Time.Date.new(2026, 2, 29).message)
end
```

```output
2024 2 29
day 29 is not valid for month 2 of year 2026
```

## Time.TimeOfDay.new

```signature
Time.TimeOfDay.new(hour: Int, min: Int, sec: Int, usec: Int) -> Result[Time.TimeOfDay]
```

The clock reading, or an error of kind `argument` for an hour outside 0 to 23, a minute or second outside 0 to 59, or a `usec` outside 0 to 999999.

```agentica
def main() -> Void
  puts(Time.TimeOfDay.new(7, 32, 0, 999999))
  puts(Time.TimeOfDay.new(23, 59, 60, 0).message)
end
```

```output
ok(Time.TimeOfDay(hour: 7, min: 32, sec: 0, usec: 999999))
sec 60 is a leap second, which is not supported
```

## Time.NaiveDateTime.new

```signature
Time.NaiveDateTime.new(year: Int, month: Int, day: Int, hour: Int, min: Int, sec: Int, usec: Int) -> Result[Time.NaiveDateTime]
```

The date and the clock reading, with the checks of `Time.Date.new` and `Time.TimeOfDay.new`.

```agentica
def main() -> Void
  t = Time.NaiveDateTime.new(2026, 10, 14, 19, 5, 42, 201337).unwrap!
  puts("#{t.day} #{t.hour}:#{t.min}")
end
```

```output
14 19:5
```

## Time.DateTime.new

```signature
Time.DateTime.new(year: Int, month: Int, day: Int, hour: Int, min: Int, sec: Int, usec: Int, utc_offset: Int) -> Result[Time.DateTime]
```

The reading at `utc_offset` seconds east of UTC, with the checks of `Time.NaiveDateTime.new`, and an error of kind `argument` for an offset that is not whole minutes or is outside `-86340` to `86340`.

```agentica
def main() -> Void
  t = Time.DateTime.new(2026, 10, 14, 21, 5, 42, 201337, 7200).unwrap!
  puts("#{t.hour} #{t.utc_offset}")
  puts(Time.DateTime.new(2026, 10, 14, 21, 5, 42, 0, 30).message)
end
```

```output
21 7200
utc_offset 30 is not a whole number of minutes
```

## Time.Date.leap?

```signature
Time.Date.leap?(year: Int) -> Bool
```

Whether the year has 366 days: divisible by 4, and not by 100 unless by 400. It takes any `Int`.

```agentica
def main() -> Void
  puts([1900, 2000, 2024, 2026].map do |year| Time.Date.leap?(year) end)
end
```

```output
[false, true, true, false]
```

## Time.Date.days_in_month

```signature
Time.Date.days_in_month(year: Int, month: Int) -> Result[Int]
```

The number of days of the month, 28 to 31, or an error of kind `argument` for a year outside 1 to 9999 or a month outside 1 to 12.

```agentica
def main() -> Void
  puts(Time.Date.days_in_month(2024, 2))
  puts(Time.Date.days_in_month(2026, 13).message)
end
```

```output
ok(29)
month 13 is not in 1..12
```

## Time.at and Time.at_us

```signature
Time.at(seconds: Int) -> Result[Time.DateTime]
Time.at_us(us: Int) -> Result[Time.DateTime]
```

The instant `seconds` (or `us` microseconds) after the Unix epoch, 1970-01-01T00:00:00Z, in UTC (`utc_offset` 0). A negative count is before 1970. The range is `-62135596800` to `253402300799` seconds (`-62135596800000000` to `253402300799999999` microseconds), the first and the last instant of the years 1 to 9999; a count outside it is an error of kind `argument`.

```agentica
def main() -> Void
  puts(Time.at(1_000_000_000).unwrap!)
  puts(Time.at_us(-1).unwrap!)
  puts(Time.at(253402300800).message)
end
```

```output
Time.DateTime(year: 2001, month: 9, day: 9, hour: 1, min: 46, sec: 40, usec: 0, utc_offset: 0)
Time.DateTime(year: 1969, month: 12, day: 31, hour: 23, min: 59, sec: 59, usec: 999999, utc_offset: 0)
seconds 253402300800 is not in -62135596800..253402300799
```

## Time.now

```signature
Time.now() -> Time.DateTime
```

The wall clock in UTC, to the microsecond. The wall clock can jump, so measure a duration with `Time.monotonic_ms` or `Time.monotonic_ns` instead.

```agentica
def main() -> Void
  puts(Time.now().utc_offset)
end
```

```output
0
```

## to_i and to_us

```signature
Time.DateTime.to_i(time: Time.DateTime) -> Int
Time.DateTime.to_us(time: Time.DateTime) -> Int
```

The instant as seconds (`to_i`) or microseconds (`to_us`) since the Unix epoch, whatever the offset. `to_i` rounds toward minus infinity, as Ruby's `Time#to_i` does: the microsecond before the epoch is in second `-1`. Neither fails; a reading in the year 1 or 9999 at an offset may give an instant just outside the range of `Time.at`.

```agentica
def main() -> Void
  t = Time.DateTime.new(2001, 9, 9, 3, 46, 40, 500000, 7200).unwrap!
  puts("#{t.to_i} #{t.to_us}")
  puts(Time.at_us(-1).unwrap!.to_i)
end
```

```output
1000000000 1000000000500000
-1
```

## getutc and getlocal

```signature
Time.DateTime.getutc(time: Time.DateTime) -> Result[Time.DateTime]
Time.DateTime.getlocal(time: Time.DateTime, utc_offset: Int) -> Result[Time.DateTime]
```

The same instant read at offset 0 (`getutc`) or at `utc_offset` seconds east of UTC (`getlocal`). An error of kind `argument` when the offset is not one `Time.DateTime.new` takes, or when the new reading is outside the years 1 to 9999.

```agentica
def main() -> Void
  t = Time.DateTime.new(2026, 10, 14, 21, 5, 42, 0, 7200).unwrap!
  puts(t.getutc.unwrap!.hour)
  puts(t.getlocal(-18000).unwrap!.hour)
  puts(t.getlocal(30).message)
end
```

```output
19
14
utc_offset 30 is not a whole number of minutes
```

## naive_of and assume_offset

```signature
Time.DateTime.naive_of(time: Time.DateTime) -> Time.NaiveDateTime
Time.NaiveDateTime.assume_offset(naive: Time.NaiveDateTime, utc_offset: Int) -> Result[Time.DateTime]
```

`naive_of` keeps the reading and drops the offset. `assume_offset` gives a naive reading an offset, which makes it an instant; it keeps the fields, so its only error (of kind `argument`) is an offset that `Time.DateTime.new` refuses.

```agentica
def main() -> Void
  n = Time.NaiveDateTime.new(2026, 10, 14, 9, 0, 0, 0).unwrap!
  t = n.assume_offset(-18000).unwrap!
  puts(t.to_i)
  puts(t.naive_of == n)
end
```

```output
1791986400
true
```

## to_date

```signature
Time.DateTime.to_date(time: Time.DateTime) -> Time.Date
Time.NaiveDateTime.to_date(naive: Time.NaiveDateTime) -> Time.Date
```

The date of the reading, at its own offset.

```agentica
def main() -> Void
  t = Time.DateTime.new(2026, 10, 14, 23, 30, 0, 0, -3600).unwrap!
  puts(t.to_date)
  puts(t.getutc.unwrap!.to_date)
end
```

```output
Time.Date(year: 2026, month: 10, day: 14)
Time.Date(year: 2026, month: 10, day: 15)
```

## iso8601

```signature
date.iso8601() -> String
time.iso8601() -> String
naive.iso8601() -> String
```

The ISO 8601 text of a value of any of the four types (`date` a `Time.Date`, `time` a `Time.TimeOfDay` or a `Time.DateTime`, `naive` a `Time.NaiveDateTime`): `YYYY-MM-DD` for a date, `HH:MM:SS.ffffff` for a time of day, the two joined by `T` for a date and time, and for a `Time.DateTime` its offset, `Z` at offset 0 and `+HH:MM` or `-HH:MM` otherwise (RFC 3339). The fraction always has six digits, so texts of one offset sort as their instants do.

```agentica
def main() -> Void
  t = Time.DateTime.new(2026, 10, 14, 21, 5, 42, 201337, 7200).unwrap!
  puts(t.iso8601)
  puts(t.getutc.unwrap!.iso8601)
  puts(t.naive_of.iso8601)
  puts(t.to_date.iso8601)
end
```

```output
2026-10-14T21:05:42.201337+02:00
2026-10-14T19:05:42.201337Z
2026-10-14T21:05:42.201337
2026-10-14
```

## Time.Date.iso8601 and the other parses

```signature
Time.Date.iso8601(text: String) -> Result[Time.Date]
Time.TimeOfDay.iso8601(text: String) -> Result[Time.TimeOfDay]
Time.NaiveDateTime.iso8601(text: String) -> Result[Time.NaiveDateTime]
Time.DateTime.iso8601(text: String) -> Result[Time.DateTime]
```

The value that the text spells in the form `iso8601` writes, with the checks of the type's `new`. The seconds may have no fraction or a `.` and any number of digits; the digits past the sixth are cut off, not rounded. `T` and `Z` may be lowercase, as RFC 3339 allows, and `-00:00` is offset 0.

`Time.DateTime.iso8601` needs an offset and `Time.NaiveDateTime.iso8601` refuses one, so a text with no offset is never read as an instant by mistake. Any other text is an error of kind `argument` that says what was expected and at which character (counted from 1): a space for `T`, `+0200`, an offset hour above 23, `07:32` with no seconds, text after the value, or a second of 60.

```agentica
def main() -> Void
  puts(Time.DateTime.iso8601("2026-10-14t19:05:42.123456789z").unwrap!.iso8601)
  puts(Time.DateTime.iso8601("2026-10-14T19:05:42").message)
  puts(Time.DateTime.iso8601("2026-10-14 19:05:42Z").message)
  puts(Time.NaiveDateTime.iso8601("2026-10-14T19:05:42Z").message)
  puts(Time.TimeOfDay.iso8601("07:32:00.5"))
end
```

```output
2026-10-14T19:05:42.123456Z
missing offset; use Time.NaiveDateTime.iso8601 for text without one
expected YYYY-MM-DDTHH:MM:SS at character 11
offset "Z" is not allowed here; use Time.DateTime.iso8601
ok(Time.TimeOfDay(hour: 7, min: 32, sec: 0, usec: 500000))
```

## add_days and add_us

```signature
date.add_days(days: Int) -> Result[Time.Date]
naive.add_days(days: Int) -> Result[Time.NaiveDateTime]
time.add_days(days: Int) -> Result[Time.DateTime]
naive.add_us(us: Int) -> Result[Time.NaiveDateTime]
time.add_us(us: Int) -> Result[Time.DateTime]
```

The value `days` calendar days or `us` microseconds later, or earlier for a negative count. A `Time.DateTime` keeps its offset, so its reading and its instant move together; with fixed offsets every day is 86400 seconds. An error of kind `argument` when the reading leaves the years 1 to 9999, for any `Int` count: the count is checked before it is added, so it cannot overflow. A duration is a plain `Int` of microseconds; there is no arithmetic on a `Time.TimeOfDay`.

```agentica
def main() -> Void
  d = Time.Date.new(2024, 2, 28).unwrap!
  puts(d.add_days(1).unwrap!.iso8601)
  t = Time.DateTime.new(2026, 10, 14, 23, 30, 0, 0, 7200).unwrap!
  puts(t.add_us(3_600_000_000).unwrap!.iso8601)
  puts(d.add_days(9_000_000).message)
end
```

```output
2024-02-29
2026-10-15T00:30:00.000000+02:00
the date is outside the years 1 to 9999
```

## days_between and us_between

```signature
from.days_between(to: Time.Date) -> Int
from.us_between(to: Time.DateTime) -> Int
from.us_between(to: Time.NaiveDateTime) -> Int
```

The difference `to - from`, positive when `to` is later: in days between two dates, in microseconds between two instants (offsets count) or between two readings.

```agentica
def main() -> Void
  a = Time.DateTime.new(2026, 10, 14, 12, 0, 0, 0, 7200).unwrap!
  b = Time.DateTime.new(2026, 10, 14, 12, 0, 0, 0, 0).unwrap!
  puts(a.us_between(b))
  puts(a.naive_of.us_between(b.naive_of))
  puts(a.to_date.days_between(Time.Date.new(2027, 1, 1).unwrap!))
end
```

```output
7200000000
0
79
```

## Time.compare

```signature
Time.compare(time: Time.DateTime, other: Time.DateTime) -> Int
Time.compare_naive(naive: Time.NaiveDateTime, other: Time.NaiveDateTime) -> Int
Time.compare_date(date: Time.Date, other: Time.Date) -> Int
Time.compare_time(time: Time.TimeOfDay, other: Time.TimeOfDay) -> Int
```

`-1`, `0` or `1` as the first value is before, the same as or after `other`, as Ruby's `<=>` gives. `Time.compare` compares instants, so one instant at two offsets is `0`; the others compare readings, days and clock readings.

```agentica
def main() -> Void
  a = Time.DateTime.new(2026, 10, 14, 21, 0, 0, 0, 7200).unwrap!
  puts(Time.compare(a, a.getutc.unwrap!))
  puts(Time.compare_naive(a.naive_of, a.getutc.unwrap!.naive_of))
end
```

```output
0
1
```

## cwday and yday

```signature
date.cwday() -> Int
date.yday() -> Int
```

The ISO day of the week, `1` for Monday to `7` for Sunday, and the day of the year, `1` to `366`. A date and time gives them through `to_date`.

```agentica
def main() -> Void
  d = Time.Date.new(2026, 10, 14).unwrap!
  puts("#{d.cwday} #{d.yday}")
end
```

```output
3 287
```
