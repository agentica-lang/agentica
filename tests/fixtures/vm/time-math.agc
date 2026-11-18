# Arithmetic, comparison and queries of the Time family: adds at the ends of the range and past them with the largest
# Ints, differences across offsets, -1, 0 and 1 of each comparison, and the ISO weekday and day of the year.
def show(r: Result[Time.Date]) -> Void
  case r
    ok(d) -> puts(d.iso8601)
    error(err) -> puts("#{err.kind}: #{err.message}")
  end
end

def show_aware(r: Result[Time.DateTime]) -> Void
  case r
    ok(t) -> puts(t.iso8601)
    error(err) -> puts("#{err.kind}: #{err.message}")
  end
end

def main() -> Void
  d = Time.Date.new(2024, 2, 28).unwrap!
  show(d.add_days(1))
  show(d.add_days(366))
  show(d.add_days(-738943))
  show(d.add_days(-738944))
  show(d.add_days(9223372036854775807))
  show(d.add_days(-9223372036854775807 - 1))
  t = Time.DateTime.new(9999, 12, 31, 23, 59, 59, 999999, 3600).unwrap!
  show_aware(t.add_us(-1))
  show_aware(t.add_us(1))
  show_aware(t.add_days(-1))
  show_aware(t.add_us(9223372036854775807))
  n = Time.NaiveDateTime.new(1, 1, 1, 0, 0, 0, 0).unwrap!
  puts(n.add_us(-1).message)
  puts(n.add_days(3652058).unwrap!.iso8601)
  puts(n.add_us(315537897599999999).unwrap!.iso8601)
  u = t.getutc.unwrap!
  puts("#{t.us_between(u)} #{t.naive_of.us_between(u.naive_of)} #{d.days_between(Time.Date.new(2025, 1, 1).unwrap!)}")
  puts([Time.compare(t, u), Time.compare(t.add_us(-1).unwrap!, u), Time.compare(u, t.add_days(-1).unwrap!)])
  puts([
    Time.compare_naive(t.naive_of, u.naive_of),
    Time.compare_date(d, d),
    Time.compare_date(d.add_days(1).unwrap!, d),
  ])

  a = Time.TimeOfDay.new(12, 0, 0, 0).unwrap!
  b = Time.TimeOfDay.new(11, 59, 59, 999999).unwrap!
  puts([Time.compare_time(a, b), Time.compare_time(b, a), Time.compare_time(a, a)])
  for day in [Time.Date.new(2026, 10, 14).unwrap!, Time.Date.new(1, 1, 1).unwrap!, Time.Date.new(2024, 12, 31).unwrap!]
    puts("#{day.iso8601} #{day.cwday} #{day.yday}")
  end
end
