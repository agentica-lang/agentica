# Dates and times (`Time` family)

Builtin records, no import. Fields are `Int`s with Ruby's `Time` names.
Proleptic Gregorian calendar, years 1 to 9999, microseconds, no leap seconds,
fixed offsets only (no named zones, no DST). The clocks (`Time.now_ms`, ...)
are in `builtins.md`.

```text
Time.Date(year, month, day)
Time.TimeOfDay(hour, min, sec, usec)
Time.NaiveDateTime(year, month, day, hour, min, sec, usec)     # no offset
Time.DateTime(year, month, day, hour, min, sec, usec, utc_offset)   # seconds east of UTC

Time.Date.new(year: Int, month: Int, day: Int) -> Result[Time.Date]
Time.TimeOfDay.new(hour: Int, min: Int, sec: Int, usec: Int) -> Result[Time.TimeOfDay]
Time.NaiveDateTime.new(year, month, day, hour, min, sec, usec) -> Result[Time.NaiveDateTime]
Time.DateTime.new(year, month, day, hour, min, sec, usec, utc_offset) -> Result[Time.DateTime]
Time.Date.leap?(year: Int) -> Bool               # any Int
Time.Date.days_in_month(year: Int, month: Int) -> Result[Int]
```

- A field out of range is an error of kind `argument` (`month 13 is not in
  1..12`); `sec` 60 is an error. `utc_offset` is whole minutes within
  `-86340..86340`.
- Only `*.new` builds a value: `Time.Date(year: ...)` and `d.with(...)` are
  `CHECK-NOT-CONSTRUCTIBLE`.
- No JSON: `JSON.encode`/`decode`/`schema` refuse them, also inside a struct
  (`CHECK-NOT-ENCODABLE`, `CHECK-NOT-DECODABLE`).
- `==` works on `Time.Date`, `Time.TimeOfDay` and `Time.NaiveDateTime`, not on
  `Time.DateTime` (`CHECK-TYPE-MISMATCH`): one instant has many readings.
