## Test driver of tests/test_std_utc.py: reads one JSON case per line of stdin, runs std/utc on it and prints one JSON
## line with the parts and the text.

import UTC from "std/utc"

# `digits` is passed to `iso8601` only when `has_digits` is true, so a case can leave the default in place.
struct Case
  ms: Int
  digits: Int
  has_digits: Bool
end

struct Reply
  year: Int
  month: Int
  day: Int
  hour: Int
  minute: Int
  second: Int
  millisecond: Int
  text: String
end

def run_case(c: Case) -> Reply
  p = UTC.parts(c.ms)
  text = UTC.iso8601(c.ms)
  if c.has_digits
    text = UTC.iso8601(c.ms, c.digits)
  end
  return Reply(
    year: p.year,
    month: p.month,
    day: p.day,
    hour: p.hour,
    minute: p.minute,
    second: p.second,
    millisecond: p.millisecond,
    text: text,
  )
end

def main() -> Void
  while true
    line = IO.gets()
    if !line.ok?
      return
    end
    case JSON.decode(line.unwrap!, Case)
      ok(c) -> puts(JSON.encode(run_case(c)))
      error(message) -> puts("bad case: #{message}")
    end
  end
end
