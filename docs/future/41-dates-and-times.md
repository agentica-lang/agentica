## 41. Dates and times

**Status:** designed, not scheduled. The owner's scope of 2026-10-14 is in this
section, and the roadmap order table does not place it. Its types are checker
changes, so they come after the Agentica front end (41.13), as the owner decided
on 2026-10-15. `Time.monotonic_ns` (41.10) is independent and has landed.
It is VM-only and adds no grammar syntax: new builtin types and new functions of
the existing `Time` module. Every name here is a proposal for the owner to
review. The precision is microseconds, as the owner decided on 2026-10-15
(41.8).

Programs compute with dates and times: a due date, the timestamp of a log
line (the grammar's logging section), an expiry, a time from a JSON API.
Today a program has `Time.now_ms()`
(wall clock) and `Time.monotonic_ms()`, and nothing else. It turns milliseconds
into a date by hand, and it cannot tell a value with an offset from one without.
`File.stat` already gives `modified_seconds` as Unix seconds (`vm/files.c`), so
`Time.from_unix(info.modified_seconds)` turns it into a `DateTime`.

### 41.1 Where it lives, and the exception to "std/ first"

The roadmap rule "New library features: `std/` first" (`docs/roadmap/README.md`)
puts pure computation in `stdlib/*.agc`. This section is a deliberate exception,
chosen by the owner on 2026-10-14: the calendar types and their conversions are
native, as builtins of the existing `Time` module, written in C under `vm/`. The
reasons:

- The types are the part a `std/` module cannot give. A struct declared in a
  module is constructible by any program and its name is not reserved, so the
  rule "a `Date` is a real day" cannot be kept. The types must be builtins
  (41.2), and the functions that build and read them belong next to them.
- One place for time: `Time.now_ms` and `Time.monotonic_ms` already live there,
  and `Time.now()` returns the same clock as a `DateTime`.
- Speed: a conversion is a few dozen integer operations in C, one builtin call.
  An Agentica version would cost about a hundred interpreted steps per
  conversion (an estimate, not measured), and each step counts against
  `--max-steps`.
- Registration: a `std/` module needs one line in `src/stdlib.rkt`. Row 7.2.7
  counts that line as data (41.13), so it does not block a `std/` module; the
  reasons above decide this section.

The exception is new and is not yet in the roadmap rule. When the types land,
the rule gets a new item: calendar types and their conversions, which need a
builtin type. This section does not edit the rule text.

### 41.2 Types

The file and function names in this section are the Racket front end's, as they
are today. The types and their checks go in `compiler/` after the bootstrap
(41.13); the Racket names here only show the current mechanism.

Four builtin value types, declared like the builtin records `FileInfo` and
`HttpServerOptions` in `src/builtin-types.rkt`:

```text
Date(year: Int, month: Int, day: Int)
TimeOfDay(hour: Int, minute: Int, second: Int, microsecond: Int)
NaiveDateTime(year: Int, month: Int, day: Int,
              hour: Int, minute: Int, second: Int, microsecond: Int)
DateTime(year: Int, month: Int, day: Int,
         hour: Int, minute: Int, second: Int, microsecond: Int,
         offset_minutes: Int)
```

- **Date** is a calendar day.
- **TimeOfDay** is a clock reading with no date and no offset, such as
  `07:32:00.999999`. It is not an instant. TOML has this kind of value (a local
  time), and so do SQL and ISO 8601.
- **NaiveDateTime** is a wall-clock reading with no offset, such as
  `2026-10-14T19:05:42.201337`. It does not say which instant that is.
- **DateTime** (aware) is a wall-clock reading plus a fixed offset in minutes.
  The instant is the reading minus the offset, and UTC is offset 0. The fields
  are the local ones: `dt.hour` is the hour at that offset, and parsing `+02:00`
  keeps `+02:00`.

This follows Python: `date`, `time`, and `datetime` with and without `tzinfo`.
Elixir has the same four structs (`%Date{}`, `%Time{}`, `%NaiveDateTime{}`,
`%DateTime{}`). The name here is `TimeOfDay`, because `Time` is the module. The
names are proposals for the owner to review (41.20).

The fields are flat, not `DateTime(date: Date, ...)`. Flat fields give one level
of field access, and they need no `builtin-struct-needs` entry in
`src/lower.rkt`, which a nested record would need, as `HttpResponse` needs
`Header`.

Reserved names. Like `Await` (the builtin enum added by PR #217), the names
`Date`, `TimeOfDay`, `NaiveDateTime` and `DateTime` become reserved:
`reserved-type-names` in `src/checker.rkt` takes every key of `builtin-records`.
A user `struct`, `enum`, type parameter or import alias with one of these names
is `CHECK-REDEFINED-NAME`. On the Racket front end, `enum Await[T]`, `import
Time from "std/binary"` and a user `struct Header` each give that code today.
The implementation PR marks this **Breaking:** in `CHANGELOG.md`. No migration
path or compatibility workaround is added: the language has no external users
yet.

Enum variants are not reserved. A variant is always written with its enum
(`Toml.Value.DateTime`), so a variant named like a builtin type does not clash
with it. The same holds today for `Toml.Value.Int` and `Toml.Value.Bool`, and
it keeps `Toml.Value.DateTime` valid when §41 lands. The checker port in
`compiler/` must not start reserving variant names: a variant named `Date` or
`DateTime` checks ok (41.15).

Construction. Builtin records can be constructed today: `Header(name: "a",
value: "b")` checks. For dates that is wrong: `Date(year: 2026, month: 13, day:
1)` would check and then break every function that reads it. The types part adds
a checker rule: constructing `Date`, `TimeOfDay`, `NaiveDateTime` or `DateTime`
is `CHECK-NOT-CONSTRUCTIBLE` (a new code), with the help "use `Time.date`,
`Time.time_of_day`, `Time.naive` or `Time.datetime`". Reading fields stays
allowed. Rejected alternatives: validating every input in C and halting (the
invariant then lives in every function, and a bad value is found at use, not at
construction); opaque types with accessor functions, as `Process` is (`dt.hour`
is what programs expect from a record, as `FileInfo` shows).

Records have no equality (`==` on a struct is `CHECK-TYPE-MISMATCH`,
`docs/grammar/06-semantics.md`), so use `Time.compare`, `Time.compare_naive`,
`Time.compare_date` or `Time.compare_time`. `puts(dt)` prints the struct form,
so use `Time.format` for text.

### 41.3 Constructors

```text
Time.date(year: Int, month: Int, day: Int) -> Result[Date]
Time.time_of_day(hour: Int, minute: Int, second: Int, microsecond: Int)
  -> Result[TimeOfDay]
Time.naive(year: Int, month: Int, day: Int,
           hour: Int, minute: Int, second: Int, microsecond: Int)
  -> Result[NaiveDateTime]
Time.datetime(year: Int, month: Int, day: Int,
              hour: Int, minute: Int, second: Int, microsecond: Int,
              offset_minutes: Int) -> Result[DateTime]
Time.assume_offset(value: NaiveDateTime, offset_minutes: Int)
  -> Result[DateTime]
```

- Checks: year 1 to 9999; month 1 to 12; day valid for the month and year (leap
  years included); hour 0 to 23; minute 0 to 59; second 0 to 59 (a second 60 is
  `leap second not supported`, 41.8); microsecond 0 to 999999; `offset_minutes`
  from -1439 to 1439, which is the range of `±hh:mm` with `hh` up to 23 and
  `mm` up to 59. The fields give the local reading, which must be in years 1
  to 9999 at any offset (41.8). `Time.time_of_day` has no year and no offset, so
  it checks only the clock fields.
- Errors are `error(...)` with a message, for example `month 13 is not in 1 ..
  12` or `day 30 is not valid for month 2 of year 2026`. A bad value from input
  is an error the program handles, as `String.to_int` does. `Result.unwrap!`
  covers the case where the program knows the value is good.
- No `Date`-taking form of `naive`. One form per job: the seven-number form
  matches Python's `datetime(...)` and needs no second value; the fields of a
  valid `Date` can still be passed in (`Time.naive(d.year, d.month, d.day, 19,
  5, 42, 201337)`).
- No conversion from a `DateTime` or a `NaiveDateTime` to `TimeOfDay` in v1.
  `Time.time_of_day(dt.hour, dt.minute, dt.second, dt.microsecond).unwrap!`
  does it; the fields of a valid value are always in range.
- Two aware constructors, because they take different inputs: `datetime` builds
  from numbers, as Python's constructor does with `tzinfo`; `assume_offset`
  gives an offset to a reading that already exists (from `parse_naive` or a
  `NaiveDateTime`). Both run the same checks.

### 41.4 Unix time and the clock

```text
Time.from_unix(seconds: Int) -> Result[DateTime]
Time.from_unix_us(us: Int) -> Result[DateTime]
Time.to_unix(value: DateTime) -> Int
Time.to_unix_us(value: DateTime) -> Int
Time.now() -> DateTime
```

- The unit is in the name. The functions without a suffix count whole seconds,
  and `_us` counts microseconds, the precision of the fields. Milliseconds are
  not a unit of the new functions: `Time.now_ms` and `Time.monotonic_ms` keep
  theirs.
- Both `from_unix` functions return UTC, offset 0. A value outside years 1 to
  9999 is an error. `from_unix` checks its argument against the range in seconds
  before it multiplies by 10^6, so no value overflows.
- `to_unix` is `to_unix_us` divided by 1000000, rounded toward minus infinity:
  `to_unix(from_unix_us(-1))` is `-1`, and `from_unix(-1)` is 23:59:59.000000 of
  1969-12-31 (the same second). `to_unix_us` cannot fail, since the range is
  about 2.5e17 us of the 9.2e18 an Int holds (§42.4). The two directions are
  not exact inverses at the edges: an aware value at offset -1439 can have an
  instant up to a day past 9999-12-31, so `to_unix_us` can return a value that
  `from_unix_us` rejects (41.15 tests it).
- `Time.now()` is the wall clock in UTC. It reads the clock the way
  `Time.now_ms` does (`timespec_get` with `TIME_UTC`), and it keeps the
  nanoseconds truncated to microseconds. The resolution is the OS clock's, so a
  clock coarser than a microsecond leaves zeros in the last digits. If the clock
  is outside years 1 to 9999 it halts with `RUNTIME-INTERNAL` ("cannot read the
  clock"), as `Time.now_ms` does for a clock it cannot read. That does not
  happen on a real machine. A program that wants the number uses
  `Time.to_unix_us(Time.now())`.
- A naive reading has no Unix time. It goes through `assume_offset` first.

### 41.5 Offsets and naive values

```text
Time.with_offset(value: DateTime, offset_minutes: Int) -> Result[DateTime]
Time.to_utc(value: DateTime) -> Result[DateTime]
Time.naive_of(value: DateTime) -> NaiveDateTime
```

- `with_offset` keeps the instant and changes the reading, as Python's
  `astimezone` does with a fixed offset. It returns a Result because the reading
  can leave years 1 to 9999: 0001-01-01T00:00:00+01:00 is in year 0 in UTC.
- `to_utc` is `with_offset(value, 0)`, with the same Result.
- `naive_of` keeps the reading and drops the offset, as Python's
  `replace(tzinfo=None)` does. It cannot fail.
- `assume_offset` (41.3) is the other direction. Each conversion has its own
  name, so a program never changes the meaning of a value silently.

Comparing or subtracting a naive value with an aware one is a compile-time type
error (`CHECK-TYPE-MISMATCH`, the same error that passing a `FileInfo` where an
`Int` is expected gives; the Racket front end checks it today, 41.2). Python
raises `TypeError` at run time for ordering and subtraction; here the program
does not start.

### 41.6 Text

RFC 3339 for aware values; ISO 8601 for naive values, dates and times of day.

```text
Time.format(value: DateTime) -> String
Time.format_naive(value: NaiveDateTime) -> String
Time.format_date(value: Date) -> String
Time.format_time(value: TimeOfDay) -> String
Time.parse(text: String) -> Result[DateTime]
Time.parse_naive(text: String) -> Result[NaiveDateTime]
Time.parse_date(text: String) -> Result[Date]
Time.parse_time(text: String) -> Result[TimeOfDay]
```

Examples: 19:05:42.201337 UTC on 2026-10-14 formats as
`2026-10-14T19:05:42.201337Z`; at offset `+02:00` it formats as
`2026-10-14T21:05:42.201337+02:00`. `format_naive` of the same reading gives
`2026-10-14T19:05:42.201337`, `format_date` gives `2026-10-14`, and
`format_time` of its clock reading gives `19:05:42.201337`.

Format decisions:

- Offset 0 is written `Z`, and other offsets as `+hh:mm` or `-hh:mm`. This is
  the form the logger's examples use, and RFC 3339 writes it for UTC.
- Always six fraction digits, `.000000` included. The value has microsecond
  precision, and a fixed width keeps the length of the text the same, so strings
  from one offset sort by time. Trimming zeros would make `.2` and `.200000` two
  spellings of one value.
- Years are four digits. Format never writes a year outside 1 to 9999.

Parse decisions:

- `parse` requires an offset and `parse_naive` forbids one. These are two
  functions, not one that returns either kind. A function has one return type,
  and a program that gets a naive reading where it expected an instant has the
  bug the naive/aware split exists to catch. Each error names the other
  function: `missing offset; use Time.parse_naive for text without one`, and
  `offset "Z" is not allowed here; use Time.parse`.
- `T` and `Z` may be lowercase, as RFC 3339 section 5.6 allows. The parser reads
  other systems' output; the formatter always writes uppercase.
- A space in place of `T` is rejected. RFC 3339 allows it only in a note, and
  Agentica has one spelling.
- After the seconds, a `.` and one or more digits are allowed. Digits past the
  sixth are truncated, not rounded: rounding can carry into the next second or
  day. Inputs with more than six digits (nanoseconds, from many systems) must
  not fail, and truncation keeps them valid. Python's `datetime.fromisoformat`
  truncates the same way.
- `-00:00` is read as offset 0. It is the same instant. RFC 3339 section 4.3
  uses `-00:00` for an unknown local offset, and that is lost here: the text
  reads as `+00:00`. This is a chosen loss.
- Rejected: `+0200` (no colon), offsets with `hh` above 23 or `mm` above 59,
  second `60` (41.8), trailing text, empty text, and a `.` with no digits.
- `parse_date` reads `YYYY-MM-DD` only.
- `parse_time` reads `HH:MM:SS` with the same optional fraction and the same
  seconds rules as `parse`, and nothing else: a date, an offset or no second
  (`07:32`) is an error.
- Any other text gives `error("...")` with the character index, for example
  `expected YYYY-MM-DDTHH:MM:SS at character 11`. Messages are lowercase with no
  final period, as in `std/binary`.

Text errors are always `error(...)`, never a halt.

### 41.7 Arithmetic and queries

```text
Time.add_days(value: Date, days: Int) -> Result[Date]
Time.add_us(value: DateTime, us: Int) -> Result[DateTime]
Time.add_us_naive(value: NaiveDateTime, us: Int) -> Result[NaiveDateTime]
Time.days_between(from: Date, to: Date) -> Int
Time.us_between(from: DateTime, to: DateTime) -> Int
Time.us_between_naive(from: NaiveDateTime, to: NaiveDateTime) -> Int
Time.compare(a: DateTime, b: DateTime) -> Int
Time.compare_naive(a: NaiveDateTime, b: NaiveDateTime) -> Int
Time.compare_date(a: Date, b: Date) -> Int
Time.compare_time(a: TimeOfDay, b: TimeOfDay) -> Int
Time.date_of(value: DateTime) -> Date
Time.date_of_naive(value: NaiveDateTime) -> Date
Time.weekday(value: Date) -> Int
Time.day_of_year(value: Date) -> Int
Time.days_in_month(year: Int, month: Int) -> Result[Int]
Time.leap_year?(year: Int) -> Bool
```

- Naming: a function of `DateTime` has the plain name. A function that exists
  for another type too takes that type's suffix: `_naive` for `NaiveDateTime`,
  `_date` for `Date`, `_time` for `TimeOfDay`. So `format`, `format_naive`,
  `format_date` and `format_time`; `compare`, `compare_naive`, `compare_date`
  and `compare_time`; `date_of` and `date_of_naive`. A function that exists for
  one type keeps its plain name, as `add_days`, `days_between`, `weekday` and
  `day_of_year` do for `Date`. Each name has one meaning. The `us` in a name is
  the unit (microseconds), not a type suffix.
- `add_us` adds to the instant and keeps the offset, so the reading moves.
  `add_days` adds calendar days to a `Date`.
- Differences are `to - from`, positive when `to` is later, for `days_between`
  and both `us_between` functions. The parameter names give the direction.
- `us_between` on aware values is the difference of instants, so offsets count.
  The naive one is the difference of readings, which is exact because there are
  no DST changes with fixed offsets.
- `compare` returns -1, 0 or 1 by instant. Two values with one instant and
  different offsets compare equal, as in Python. `compare_naive` compares
  readings, `compare_date` compares days and `compare_time` compares clock
  readings; all of them give -1, 0 or 1.
- `weekday` is ISO: 1 is Monday, 7 is Sunday. 2026-10-14 is 3, a Wednesday.
- `day_of_year` is 1 to 366. 2026-10-14 is 287.
- `days_in_month` is an error for a month outside 1 to 12 or a year outside 1 to
  9999. `leap_year?` is the proleptic rule for any Int year.
- `add_days` and `add_us` check the argument against the range before they add,
  so an Int argument near the top of the range gives `error(...)`, not
  `RUNTIME-INTEGER-OVERFLOW`. The result must be in range too (41.8).

Not in v1: `add_months` and `add_years` (41.16), and arithmetic on `TimeOfDay`.

### 41.8 Calendar, range and clock rules

- The calendar is proleptic Gregorian: the Gregorian leap rule applies to every
  year, as in Python's `datetime`, so the Python vectors (41.15) need no model
  of history.
- Years are 1 to 9999, four digits, as in ISO 8601. Year 0 and negative years
  are not dates. The bounds are on the local reading: every `Date`,
  `NaiveDateTime` and `DateTime` has its reading in years 1 to 9999, whatever
  its offset. In UTC, `0001-01-01T00:00:00Z` is `-62135596800000000` us and
  `9999-12-31T23:59:59.999999Z` is `253402300799999999` us. `from_unix` and
  `from_unix_us` give an error outside those two instants, since their results
  are in UTC. `from_unix` takes them in seconds (`-62135596800` and
  `253402300799`), and `from_unix_us` in microseconds. `to_unix_us` cannot fail
  (41.4).
- Every operation that returns a value checks that the result's reading is in
  years 1 to 9999: `add_us`, `add_us_naive`, `add_days`, `with_offset`,
  `to_utc`, `from_unix` and `from_unix_us`. The check runs before the addition,
  so it cannot overflow. `assume_offset` and `naive_of` keep the reading, so
  they need no check.
- Unix time has no leap seconds, as in POSIX: each day has 86400 seconds. Second
  `60` is rejected by `naive`, `datetime`, `parse`, `time_of_day` and
  `parse_time`, with the message `leap second not supported`. This is a chosen
  loss: a leap second cannot be kept, because Unix time has none, and a table of
  leap seconds is as much work as the zone data of 41.16.
- Precision is microseconds, as in Python and Elixir. The field `microsecond`
  is 0 to 999999. `Time.now_ms` and `Time.monotonic_ms` keep milliseconds, and
  so does the input of `std/logger` (`time_ms`), which the logger turns
  into microseconds with `* 1000` (41.11). Nanoseconds would not fit an Int over
  the whole range: the latest value is about 2.5e20 ns since 1970, and an Int
  holds 9.2e18 (`Int` is 64 bits on every target, §42.4), so Unix nanoseconds
  overflow after the year 2262. Microseconds fit: the latest value is about
  2.5e17 us, against the 9.2e18 an Int holds.
- Offsets are fixed. There is no daylight saving time, so every day of a fixed
  offset is 86400000000 us.

### 41.9 Algorithms

Days from civil date and back use the two published algorithms of Howard Hinnant
(`days_from_civil` and `civil_from_days`, in his note "chrono-compatible
low-level date algorithms"). The C code is written for this repo from those
steps; nothing is copied from another project.

Division needs care. `docs/grammar/06-semantics.md` says integer `/` truncates
toward zero and `%` takes the sign of the dividend, and the C operators do the
same. The algorithms rely on floor division for negative values (days before
1970, negative instants). The code uses `floor_div` and `floor_mod` helpers with
a positive divisor, and every helper is covered by the vectors for negative
inputs (41.15). Each conversion is a few dozen integer operations.

### 41.10 Measuring elapsed time

Durations come from the monotonic clock, and the pattern is:

```agentica
def main() -> Void
  start = Time.monotonic_ms()
  Task.sleep(5)
  puts(Time.monotonic_ms() - start >= 4)
end
```

- Never measure a duration with a wall-clock value: `Time.now_ms()`,
  `Time.now()`, or a difference of two `DateTime` values. The wall clock can
  jump, so the difference can be negative or wrong. `Time.us_between` is for
  calendar differences (days until a due date), not for how long code runs.
- `Time.monotonic_ns() -> Int` (landed): nanoseconds from an arbitrary
  origin that never goes backward. It reads the same clock as
  `Time.monotonic_ms`, with the same code: `clock_gettime(CLOCK_MONOTONIC)` on
  POSIX and `QueryPerformanceCounter` on Windows. On Windows it splits the
  counter into seconds and a remainder before it scales to nanoseconds, as
  `monotonic_ms` does, because multiplying the raw count by 10^9 overflows an
  Int after about 15 minutes of uptime at the usual 10 MHz frequency. An Int
  holds about 292 years of nanoseconds from the origin, which the program never
  reads, so the range is not a practical limit.
- Why nanoseconds: short work (a call of a few microseconds) is invisible in
  milliseconds.
- Why not `uv_hrtime`: `numbers.c` reads the OS clock directly for
  `monotonic_ms`, and a second clock path would let the two builtins disagree.
  The implementation PR can compare the two if the owner prefers libuv.
- This is exception 1 of the std-first rule (the OS clock), so it is a C
  builtin. It is a new row of `src/builtins.rkt`, which the freeze allows
  (41.13), and it is independent of the types, so it landed first (#248).
- Tests: a golden fixture `time-monotonic-ns.agc` checks that two readings do
  not go back, that `Task.sleep(20)` takes at least 15000000 ns, and that
  `Time.monotonic_ns() / 1000000` lies between two `Time.monotonic_ms()`
  readings taken around it, which checks the unit and the shared clock. The
  independent counterpart is `tests/fixtures/monotonic-peer.py` (Python,
  standard library): it runs a program that reads the clock before and after
  `Task.sleep(20)` on Linux, where both read `CLOCK_MONOTONIC`, and checks that
  both readings lie between two `time.monotonic_ns()` readings taken around the
  run, with strict bounds and no margin. The sleep floor has a margin of 5 ms:
  the loop calls `uv_update_time` before it starts a timer (`vm/loop.c`), so a
  timer fires early by under 1 ms of truncation, plus any lag of libuv's coarse
  clock, and 5 ms covers that.
- No `elapsed` helper. The helper would be `Time.monotonic_ms() - start` with a
  name, and it would hide which clock it reads. The existing code
  (`stdlib/test/runner.agc`) writes the subtraction, and it stays that way.

### 41.11 Relation to `std/logger`

`Logger.time_text(ms)` becomes
`Time.format(Time.from_unix_us(ms * 1000).unwrap!)`: the log's text and the
`Time` formatter are one code path, and the log time is one native call instead
of the integer arithmetic the logger describes. A value outside years 1 to
9999
halts, as any `!` form does, and so does a `ms * 1000` that overflows an Int
(`*` halts on overflow, as `docs/grammar/06b-builtins.md` says). The log's own
time always comes from `Time.now_ms()`, which is in range, and the vectors cover
the edges.

The text changes with this. The time has six fraction digits
(`2026-10-12T10:15:02.345000Z`), where the logger shows three. The logger's
examples and its "with milliseconds" are updated in the implementation PR
(41.14), and the owner decides the digits (41.20). The grammar's logging section
is updated there too.

### 41.12 Cost

- Each conversion (civil to days, days to civil, Unix time to fields, text) is a
  few dozen C integer operations and one builtin call, which costs one step plus
  its arguments (§23.6).
- Allocation: one record for each date or time value, and one `String` for text.
  Parsing scans the text once.
- The record has a fixed size; no field is a list or a nested record.

### 41.13 Freeze and roadmap impact

The parts land under different rules:

- **Part:** Types, reserved names, the construction rule and its code
  - **Files:** `compiler/` (the Agentica front end)
  - **Rule:** A checker change in the Agentica front end (§18), decided by the
    owner on 2026-10-15. Not a table row.

- **Part:** `Time.*` functions (41.3 to 41.7)
  - **Files:** `compiler/` (the Agentica catalog, §18.3), `vm/dates.c`
  - **Rule:** With the types, in the Agentica front end (§18): most of the
    functions return the new types, so their catalog rows wait for it.

- **Part:** `Time.monotonic_ns` (41.10)
  - **Files:** `src/builtins.rkt`, `src/lower.rkt` (or the Agentica builtin
    catalog, if port step 4 is done), `vm/numbers.c`
  - **Rule:** Independent of the types, so it landed first (#248). After row
    7.2.7 the freeze allows its table row and its `vm-builtins` name.

Most of the functions return the new types, so they cannot land before the
types. The owner decided on 2026-10-15 that the types come after the Agentica
front end (§18), where the same rules are written in Agentica, so the `Time.*`
functions wait for it too. `Time.monotonic_ns` is the only part that landed
earlier (#248). The order table is not changed by this section; the roadmap's
"Designed, not scheduled" paragraph says where the types wait.

### 41.14 Files and docs of the implementation PR

The two parts land in two PRs (41.10 and 41.13).

The monotonic clock (41.10), which landed first (#248):

- `src/builtins.rkt`: one row next to the `Time` rows. `src/lower.rkt`: its
  `vm-builtins` name, or, if port step 4 is done, the Agentica builtin catalog
  instead. `vm/numbers.c`: the builtin.
- `docs/grammar/06b-builtins.md`: `Time.monotonic_ns` next to
  `Time.monotonic_ms` (the `Time` line).
- Programming skill: the `Time` line of the `builtins.md` reference of the
  `agentica-programming` skill.
- Site: `site/content/library/io-and-system/system.md` (a `Time.monotonic_ns`
  section).
- `CHANGELOG.md` under `## [Unreleased]`.
- Tests: the golden `time-monotonic-ns.agc` and its peer
  `tests/fixtures/monotonic-peer.py`.

The types and the `Time.*` functions, after the bootstrap (41.13), in the
Agentica front end:

- `compiler/`: the four records, the reserved names, the construction rule and
  its code `CHECK-NOT-CONSTRUCTIBLE`, and the `Time.*` rows of the Agentica
  catalog (§18.3, step 4).
- JSON (41.18): option B adds four type-table kinds (`AGC_TYPE_*` in
  `vm/value.h`, `load_types` in `vm/loader.c`), a text branch in
  `vm/json_typed.c` and `vm/json_value.c`, and the encode and decode rules in
  `compiler/`. Option A adds only the not-decodable and not-encodable rule in
  `compiler/`. Either way, `docs/grammar/06b-builtins.md` gets the JSON lines.
- `vm/dates.c` (new): the civil-date algorithms, the text and the builtins, with
  their own table, registered as the other tables are.
- Grammar: `docs/grammar/04-lexical.md` (reserved builtin names),
  `docs/grammar/06b-builtins.md` (the records, the `Time` functions and the
  construction rule), `docs/grammar/07-diagnostics.md` (the new code).
- `docs/grammar/06d-io-and-network.md` (the logging section) and the logger
  site page: the log time with six fraction digits (41.11).
- Programming skill: `.agents/skills/agentica-programming/references/dates.md`
  (new), with its row in the "When to read a reference" table of `SKILL.md`;
  `references/builtins.md` (the other `Time` lines) and
  `references/diagnostics.md`. Development skill:
  `.agents/skills/agentica-development/references/vm-builtins.md` (the builtin
  list).
- Site: `site/content/library/text-and-data/dates-and-times.md` (new, with
  runnable examples).
- `CHANGELOG.md` under `## [Unreleased]`: the new functions, and **Breaking:**
  for the reserved names.

When the feature lands: its text moves to the grammar and the site, and §41 is
deleted from `docs/future/`, following the working rule of
`docs/future/README.md`.

### 41.15 Tests

The Python vectors are the independent counterpart, as in §23.7.
`tests/fixtures/dates-vectors.py` uses only the standard library (`datetime` and
`timedelta`), with a fixed random seed, and writes
`tests/fixtures/vm/dates-vectors.stdin`. The fixture `dates-vectors.agc` reads
it and has a golden `dates-vectors.expected`. The vectors:

- Civil and Unix: the epoch; -1 us and -86400000001 us (before 1970); the bounds
  of years 1 and 9999 (41.8); leap days 2000-02-29 (`951782400000000` us) and
  2400-02-29, and the invalid 1900-02-29 and 2100-02-29; every month end of
  years 1, 4, 100, 400, 1900, 2000, 2026 and 9999; every day of 1899 to 1901 and
  of 9998 to 9999.
- Across the epoch: `add_us(from_unix_us(-1), 1)` is
  1970-01-01T00:00:00.000000Z, and `add_us(from_unix_us(0), -1)` is
  1969-12-31T23:59:59.999999Z. These check the floor division of 41.9 on
  negative microseconds.
- Offsets: -1439, -720, 0, 840 (+14:00) and 1439 minutes, each with a reading,
  both ways. The two edge readings of 41.8 with offsets: 0001-01-01T00:00:00 at
  +1439 and 9999-12-31T23:59:59.999999 at -1439. Their UTC readings are out of
  range, so `with_offset(dt, 0)` is an error for each.
- Fractions: `.000000`, `.999999`, `.000001`, and seven and nine digits
  (truncated to microseconds: `.1234567` gives 123456).
- Text: `format` and `parse` of the vectors, with `Z` and `+02:00`, and
  lowercase `t` and `z`. `format_time` and `parse_time` both ways for the clock
  readings 00:00:00.000000 and 23:59:59.999999.
- Calendar queries (`weekday`, `day_of_year`, `days_in_month`, `leap_year?`) for
  the same dates, and `add_days`, `days_between` and `compare_date` for seeded
  random pairs.
- `compare_time` for seeded random pairs of clock readings, and for the first
  and last readings of the day, 00:00:00.000000 and 23:59:59.999999.

The fixture checks every vector in both directions, prints one line for each
mismatch, and then prints `N vectors ok`.

Round trips, in the same fixture: `parse(format(dt))` gives back `dt` for every
vector without extra fraction digits; `from_unix_us(to_unix_us(dt))` equals
`with_offset(dt, 0)` when that is ok, and is an error exactly when it is;
`parse_naive(format_naive(n))` gives back `n`; `parse_time(format_time(t))`
gives back `t`; `add_days(a, days_between(a, b))` gives `b`. For seeded random
pairs `a` and `b` of `DateTime`, `add_us(a, us_between(a, b))` has the instant
of `b` (`compare` gives 0) when it is ok, and is an error exactly when its
reading at the offset of `a` is outside years 1 to 9999. Records have no `==`
(41.2), so the check uses `compare`. The naive form,
`add_us_naive(a, us_between_naive(a, b))`, gives back `b` (`compare_naive`
gives 0).

Errors: `dates-errors.agc` (golden) prints the message of every error for fixed
bad inputs: months 0 and 13, day 31 of April, 2100-02-29, years 0 and 10000,
hour 24, minute 60, second 60, microsecond 1000000 (for `Time.time_of_day`, and
the same fields of `naive` and `datetime`), offsets 1440 and -1440, an
out-of-range `from_unix_us`, and a `from_unix` second outside the range. It also
covers the parse errors of 41.6 (no offset in `parse`, an offset in
`parse_naive`, a space for `T`, `+0200`, `:60`, trailing text, empty text, a `.`
with no digits, and `parse_time` of text with a date, an offset or no second),
the message of second 60 (`leap second not supported`), and the results that
leave the range (`add_us` and `add_us_naive` past 9999-12-31T23:59:59.999999,
and the edge readings of the offsets bullet). It prints the accepted bounds
0001-01-01 and 9999-12-31.

Checker (the goldens of the Agentica front end, against `agentica check --json`,
as 42.13 says, since the Racket checker is frozen; each asserts the code and the
span): a user `struct Date` gives `CHECK-REDEFINED-NAME`; `Date(...)` and
`TimeOfDay(...)` give `CHECK-NOT-CONSTRUCTIBLE`; `Time.compare` with a naive and
an aware argument gives `CHECK-TYPE-MISMATCH`; and an `enum` with variants
`Date` and `DateTime` checks ok (41.2).

Monotonic clock: 41.10.

The vectors fixture may be slow under the `--max-steps` sweep; if so, it goes in
`heavy-fixtures` in `tests/vm-diff-common.rkt`, as §23.7 says.

### 41.16 Later

- Named time zones, such as `Europe/Madrid`. They need the IANA database. The C
  builtin would read `/usr/share/zoneinfo` (exception 1, the OS), which a
  Windows host does not have, so the design of that builtin is a later decision.
  A zone name would be a new type or a field of `DateTime`. Not decided.
- `add_months` and `add_years`. Jan 31 plus one month needs a policy (clamp to
  the last day is the usual one), which the owner should choose. Adding them
  later changes no type.
- A duration type. Plain microseconds (`Int`, the unit of `add_us`) are enough
  for now.
- Custom formats (a strftime-like form). `format` covers ISO 8601 and RFC 3339.
- Other text formats: RFC 2822 (mail), and the HTTP date (`vm/http_server.c`
  writes it in C today).
- ISO week dates (`2026-W42-3`).

### 41.17 Not planned

- Mutable date values. Values are immutable (`docs/grammar/06-semantics.md`).
- Locale-dependent names and formats.
- Leap seconds (41.8).
- A `Date`-taking form of `Time.naive` (41.3), an auto-detecting `parse` that
  returns either kind (41.6), and `format_offset` (use `with_offset` and then
  `format`).

### 41.18 JSON

Without a rule, `JSON.decode` would build a `DateTime` from an object's fields
with none of the checks of 41.3, since a nested builtin record decodes as a
struct (`docs/grammar/06b-builtins.md`). `JSON.encode` would write an object,
not an RFC 3339 or ISO 8601 text. There are two options, and the owner has not
chosen.

- **B (recommended).** A field of type `Date`, `TimeOfDay`, `NaiveDateTime` or
  `DateTime` is a JSON string. `JSON.encode` writes the text of
  `Time.format_date`, `Time.format_time`, `Time.format_naive` or `Time.format`
  (41.6). `JSON.decode` reads the string with `Time.parse_date`,
  `Time.parse_time`, `Time.parse_naive` or `Time.parse`, so the checks of 41.3
  and 41.6 run, and an error names the field path, as the other decode errors
  do. `JSON.schema` gives a string for each of the four. Reason: the text is the
  form that other systems write, and the checks run where the text comes in.
  - Cost: each type gets a type-table kind of its own (`AGC_TYPE_*` in
    `vm/value.h`, read by `load_types` in `vm/loader.c`), so the `.agcb` format
    changes. The typed encoder and decoder (`vm/json_typed.c`,
    `vm/json_value.c`) get a text branch for each kind. If §42 lands first,
    these kinds are added to its version 7 (42.11). If §41 lands first, it sets
    version 7, and §42 sets version 8. (Version 4 is the struct update `with`
    of 15c, version 5 is the module constants of §44, and version 6 is the
    compiler prelude.)
  - Top level: `JSON.decode(text, DateTime)` reads a JSON string with
    `Time.parse` and gives `Result[DateTime]`; text that is not a JSON string is
    an error. `JSON.encode` of a `DateTime` gives the JSON string.
- **A (alternative).** In v1, a field of one of the four types is
  `CHECK-NOT-DECODABLE` for `JSON.decode` and `CHECK-NOT-ENCODABLE` for
  `JSON.encode`, as Results and other nested types already are
  (`docs/grammar/06b-builtins.md`). A program converts the value with
  `Time.format` and `Time.parse` itself. Reason: nothing to design for v1; the
  cost is one conversion in each program that reads or writes a date.
  - Cost: one rule in `compiler/`: the four types are not decodable and not
    encodable, as Results are not encodable. No new `.agcb` kind and no format
    change; `vm/json_typed.c` and `vm/json_value.c` do not change.
  - Top level: `JSON.decode(text, DateTime)` and `JSON.encode` of a `DateTime`
    are `CHECK-NOT-DECODABLE` and `CHECK-NOT-ENCODABLE`, the same checks as for
    a field.

### 41.19 TOML (std/toml)

std/toml (phase 45-0, 45.4) keeps the text of a TOML date-time: its
`DateTime(String)` variant holds the text as written, until these types land.
When §41 lands, std/toml maps TOML's four kinds of date and time to four
variants, named after the types:

- offset date-time, `1979-05-27T07:32:00Z`: `DateTime(DateTime)`, read with
  `Time.parse`;
- local date-time, `1979-05-27T07:32:00`: `NaiveDateTime(NaiveDateTime)`, read
  with `Time.parse_naive`;
- local date, `1979-05-27`: `Date(Date)`, read with `Time.parse_date`;
- local time, `07:32:00.999999`: `TimeOfDay(TimeOfDay)`, read with
  `Time.parse_time`.

That replaces one variant with four, so it changes `Toml.Value`. It is a
breaking change of std/toml, and its design waits for §41 to land. The variant
names do not clash with the types, because enum variants are not reserved
(41.2).

The costs, to be accepted when it lands:

- Conformance. Year `0000` and second `60` are valid TOML 1.0, and std/toml
  accepts both today. §41 rejects both (41.8), so they become a std/toml parse
  error at the value's position. Python's `tomllib`, the test peer of 45.11,
  rejects both too. This is a small loss of conformance, and it is documented.
- Round trip. It is semantic, not textual. `Time.format` writes six fraction
  digits and `Z`, so `07:32:00` comes back as `07:32:00.000000`. `-00:00`,
  lowercase `t` and `z`, and digits past the sixth are lost as well. The value
  stays the same at microsecond precision; the text does not.
- Space for `T`. TOML allows a space (`1979-05-27 07:32:00Z`). std/toml changes
  it to `T` before it calls the parser, since §41.6 rejects a space.
- Truncation. TOML asks for truncation of fraction digits past the precision an
  implementation keeps, which §41.6 does too.
- TOML 1.1 makes seconds optional. If std/toml moves to 1.1, `parse_time` would
  need to accept `HH:MM`.

### 41.20 Questions for the owner

- **JSON (41.18).** Option A or option B for v1. Recommendation: B.
- **Name of the time-of-day type (41.2).** `TimeOfDay`, as proposed, or
  `LocalTime`, which says what the value lacks, as `NaiveDateTime` does for the
  offset. Recommendation: `TimeOfDay`.
- **Log digits (41.11).** Six fraction digits, as `Time.format` writes them, or
  three, as the logger shows now (which needs a second formatter for the log).
  Recommendation: six.
