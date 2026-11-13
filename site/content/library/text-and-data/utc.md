---
title: UTC (std)
weight: 14
description: The std/utc module, which turns Unix milliseconds into the civil date and time in UTC and into RFC 3339 text.
---

This module is interim: the builtin `Time` functions (`Time.format`, `Time.from_unix`, issue #985) replace it when they land.

`std/utc` is written in Agentica: `import UTC from "std/utc"`. It reads the number of milliseconds since the Unix epoch, the value of `Time.now_ms()`, as a date and a time of day in UTC. The name `Time` belongs to the builtin, so the module has another one. `iso8601` is Ruby's `Time#utc.iso8601(n)` and the fields of `parts` are those of `Time#utc` (`year`, `month`, `day`, `hour`, `min`, `sec`, with the names written out). The calendar is the proleptic Gregorian one, Unix time has no leap seconds, and there are no time zones: every answer is UTC. Nothing in it halts, for any `Int`.

```ruby
UTC.parts(time_ms: Int) -> UTC.Parts
UTC.iso8601(time_ms: Int, fraction_digits: Int = 0) -> String
```

```agentica
import UTC from "std/utc"

def main() -> Void
  ms = 1_781_261_702_345
  puts(UTC.iso8601(ms))
  puts(UTC.iso8601(ms, 3))
  puts(UTC.iso8601(-1, 3))
  p = UTC.parts(ms)
  puts("#{p.year}-#{p.month}-#{p.day} #{p.hour}:#{p.minute}:#{p.second}.#{p.millisecond}")
end
```

```output
2026-06-12T10:55:02Z
2026-06-12T10:55:02.345Z
1969-12-31T23:59:59.999Z
2026-6-12 10:55:2.345
```

## parts

`parts` splits `time_ms` into a `UTC.Parts`, a struct with the fields `year`, `month` (1 to 12), `day` (1 to 31), `hour` (0 to 23), `minute` (0 to 59), `second` (0 to 59) and `millisecond` (0 to 999). A negative `time_ms` is a time before 1970. Leap years follow the Gregorian rule (1900 is not one, 2000 is).

## iso8601

`iso8601` writes RFC 3339 text with the offset `Z`. With `fraction_digits` above 0 it adds that many digits of the second after a point, as Ruby's `iso8601(n)` does. The input has milliseconds, so digits after the third are `0`. Ruby writes n digits for any n; this module clamps: a count below 0 is read as 0 and one above 9 as 9. A year outside 0 to 9999 is written with its sign and at least four digits (`-0001`, `10000`).
