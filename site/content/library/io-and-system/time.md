---
title: Dates and times
weight: 9
description: Calendar dates, times of day and date-times with a fixed UTC offset, as checked values of the Time family.
---

The `Time` family has four record types. Their fields are `Int`s, named as in Ruby's `Time`:

- `Time.Date`: a day of the calendar (`year`, `month`, `day`).
- `Time.TimeOfDay`: a clock reading with no date and no offset (`hour`, `min`, `sec`, `usec`).
- `Time.NaiveDateTime`: a date and a clock reading with no offset, so it names no instant (`year`, `month`, `day`, `hour`, `min`, `sec`, `usec`).
- `Time.DateTime`: a date and a clock reading at a fixed offset from UTC, so it names one instant (the fields of `Time.NaiveDateTime`, then `utc_offset`, in seconds east of UTC).

The calendar is the proleptic Gregorian one, with the years 1 to 9999. The precision is microseconds (`usec`, 0 to 999999). Unix time has no leap seconds, so a `sec` of 60 is an error. An offset is whole minutes, from `-86340` (`-23:59`) to `86340` (`+23:59`); there are no named time zones and no daylight saving time. The fields of a `Time.DateTime` are the reading at its offset.

Every value is valid, because only the constructors below build one: writing `Time.Date(year: ..., ...)` or `d.with(...)` is `CHECK-NOT-CONSTRUCTIBLE`. `JSON.encode` and `JSON.decode` refuse these types, alone or inside a struct (`CHECK-NOT-ENCODABLE`, `CHECK-NOT-DECODABLE`). `==` compares a `Time.Date`, a `Time.TimeOfDay` or a `Time.NaiveDateTime` field by field. A `Time.DateTime` has no `==` (`CHECK-TYPE-MISMATCH`): two readings of one instant at different offsets differ in their fields. `Test.eq` still compares two of them field by field, so a test asserts the exact reading.

The clocks are on [System, Time and Random](/library/io-and-system/system/).

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
