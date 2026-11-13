## The civil date and time in UTC of a count of milliseconds since the Unix epoch, the value of `Time.now_ms`.
##
## Interim: the builtin `Time` functions of §41 (`Time.format`, `Time.from_unix`) replace this module when they land.
##
## Import it with `import UTC from "std/utc"`. The name `Time` belongs to the builtin, so the module has another
## one. `parts` is the fields of Ruby's `Time#utc` (`year`, `month`, `day`, `hour`, `min`, `sec`, here with the
## names written out) and `iso8601` is Ruby's `Time#utc.iso8601(n)`. The calendar is the proleptic Gregorian one and
## Unix time has no leap seconds. There are no time zones: every answer is UTC. Written in Agentica; nothing here
## halts, for any Int.

## The date and the time of day of one instant, in UTC.
struct Parts
  ## The year; negative before year 0.
  year: Int
  ## The month, 1 to 12.
  month: Int
  ## The day of the month, 1 to 31.
  day: Int
  ## The hour, 0 to 23.
  hour: Int
  ## The minute, 0 to 59.
  minute: Int
  ## The second, 0 to 59.
  second: Int
  ## The millisecond, 0 to 999.
  millisecond: Int
end

## Splits milliseconds since the Unix epoch into the civil date and time in UTC. A negative value is a time before
## 1970.
def parts(time_ms: Int) -> Parts
  # Floor division written so that no intermediate product leaves the Int range, even at Int.min.
  days = time_ms / 86400000
  rest = time_ms % 86400000
  if rest < 0
    days -= 1
    rest += 86400000
  end
  # Days to a calendar date by eras of 400 years, counted from 0000-03-01 so the leap day ends the year.
  z = days + 719468
  era = z / 146097
  if z % 146097 < 0
    era -= 1
  end
  doe = z - era * 146097
  yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
  doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
  shifted = (5 * doy + 2) / 153
  day = doy - (153 * shifted + 2) / 5 + 1
  month = shifted + 3
  year = yoe + era * 400
  if shifted >= 10
    month = shifted - 9
    year += 1
  end
  Parts(
    year: year,
    month: month,
    day: day,
    hour: rest / 3600000,
    minute: (rest % 3600000) / 60000,
    second: (rest % 60000) / 1000,
    millisecond: rest % 1000,
  )
end

## Returns milliseconds since the Unix epoch as RFC 3339 text in UTC, such as `2026-10-12T10:15:02Z`. With
## `fraction_digits` above 0 the text has that many digits of the second after a point (`2026-10-12T10:15:02.345Z`),
## as Ruby's `Time#iso8601(n)` does, except that Ruby writes n digits for any n and this clamps: a count below 0 is
## read as 0 and one above 9 as 9. Digits past the third are 0, since the input has milliseconds. A year outside 0 to
## 9999 is written with its sign and at least four digits.
def iso8601(time_ms: Int, fraction_digits: Int = 0) -> String
  p = parts(time_ms)
  sign = ""
  year = p.year
  if year < 0
    sign = "-"
    year = 0 - year
  end
  date = "#{sign}#{pad(year, 4)}-#{pad(p.month, 2)}-#{pad(p.day, 2)}"
  clock = "#{pad(p.hour, 2)}:#{pad(p.minute, 2)}:#{pad(p.second, 2)}"
  "#{date}T#{clock}#{fraction(p.millisecond, fraction_digits)}Z"
end

private

# The point and the digits of the second after it, or "" for no digits.
def fraction(milli: Int, digits: Int) -> String
  # Clamp before padding: the loop below must run at most 6 times, whatever the caller passes.
  return "" if digits <= 0
  if digits > 9
    digits = 9
  end
  text = pad(milli, 3)
  while text.length < digits
    text = "#{text}0"
  end
  ".#{text.slice(0, digits)}"
end

def pad(n: Int, width: Int) -> String
  text = n.to_s
  while text.length < width
    text = "0#{text}"
  end
  text
end
