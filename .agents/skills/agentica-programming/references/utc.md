# UTC (`std/utc`)

`import UTC from "std/utc"`. Unix milliseconds (`Time.now_ms()`) as a civil
date and time in UTC. `Time` is the builtin's name, so the module is `UTC`.
`iso8601` is Ruby's `Time#utc.iso8601(n)`. Written in Agentica; nothing halts.

```text
UTC.parts(ms: Int) -> UTC.Parts
UTC.iso8601(ms: Int, fraction_digits: Int = 0) -> String
```

- `UTC.Parts` has `year`, `month` (1-12), `day`, `hour`, `minute`, `second`
  and `millisecond`. A negative `ms` is before 1970.
- `iso8601` gives `2026-06-12T10:55:02Z`; with `fraction_digits` 1 to 9 a
  point and that many digits (`.345Z`; past the third they are `0`). Below 0
  counts as 0, above 9 as 9. A year outside 0 to 9999 keeps its sign and four
  digits (`-0001`, `10000`).
- Proleptic Gregorian calendar, no leap seconds, no time zones, UTC only.
