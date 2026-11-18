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

Time.at(seconds: Int) -> Result[Time.DateTime]   # UTC; years 1..9999 only
Time.at_us(us: Int) -> Result[Time.DateTime]
Time.now() -> Time.DateTime                      # wall clock, UTC, µs
t.to_i -> Int                # seconds since the epoch, floor (at_us(-1).to_i == -1)
t.to_us -> Int
t.getutc -> Result[Time.DateTime]                # same instant, offset 0
t.getlocal(utc_offset: Int) -> Result[Time.DateTime]
t.naive_of -> Time.NaiveDateTime                 # same reading, no offset
n.assume_offset(utc_offset: Int) -> Result[Time.DateTime]   # same reading
t.to_date -> Time.Date       # also on a Time.NaiveDateTime

x.iso8601 -> String          # any of the four; .ffffff always, Z or +HH:MM
Time.Date.iso8601(text: String) -> Result[Time.Date]   # also TimeOfDay,
Time.DateTime.iso8601(text) -> Result[Time.DateTime]   # NaiveDateTime
x.strftime(format: String) -> String   # any of the four; a subset of Ruby's
  # %Y %m %d %j %u %w %a %A %b %B %H %M %S %L %N %z %:z %%, English names

d.add_days(days: Int) -> Result[...]   # Date, NaiveDateTime, DateTime
t.add_us(us: Int) -> Result[...]       # NaiveDateTime, DateTime (same offset)
from.days_between(to) -> Int           # Date; to - from
from.us_between(to) -> Int             # DateTime (instants), NaiveDateTime
Time.compare(a, b) -> Int              # -1, 0, 1 by instant; also
                                       # compare_naive, compare_date, compare_time
d.cwday -> Int                         # 1 Monday .. 7 Sunday; d.yday 1..366
```

- A builtin that takes the record first is its method: write `t.to_i` (the
  method form). A field name stays a field.
- `getutc`/`getlocal` keep the instant and fail when the new reading leaves the
  years 1 to 9999. Durations: `Time.monotonic_ms`, not `Time.now`.

- A field out of range is an error of kind `argument` (`month 13 is not in
  1..12`); `sec` 60 is an error. `utc_offset` is whole minutes within
  `-86340..86340`.
- Only `*.new` builds a value: `Time.Date(year: ...)` and `d.with(...)` are
  `CHECK-NOT-CONSTRUCTIBLE`.
- No JSON: `JSON.encode`/`decode`/`schema` refuse them, also inside a struct
  (`CHECK-NOT-ENCODABLE`, `CHECK-NOT-DECODABLE`).
- `==` works on `Time.Date`, `Time.TimeOfDay` and `Time.NaiveDateTime`, not on
  `Time.DateTime` (`CHECK-TYPE-MISMATCH`): one instant has many readings; use
  `Time.compare(a, b) == 0`.
  `Test.eq` still compares two `Time.DateTime` values field by field.
- Parse is strict: `T`/`Z` any case, fraction cut (not rounded) to µs,
  `Time.DateTime.iso8601` needs an offset, `Time.NaiveDateTime.iso8601`
  refuses one; a space for `T`, `+0200`, `07:32` and sec 60 are errors.
- An add that leaves the years 1 to 9999 is an `argument` error, for any Int
  count. A duration is an Int of microseconds.
- `strftime` has no flags or widths, and any other directive stays as
  written: `%e`, `%y`, `%F`, `%T`, `%-d`, and one the type lacks (`%H` of a
  date, `%z` without an offset).
