# The constructors of the Time family: one value of each type, then each check that refuses a field, with its message.
def show(r: Result[Time.Date]) -> Void
  case r
    ok(d) -> puts(d)
    error(err) -> puts("#{err.kind}: #{err.message}")
  end
end

def show_clock(r: Result[Time.TimeOfDay]) -> Void
  case r
    ok(t) -> puts(t)
    error(err) -> puts("#{err.kind}: #{err.message}")
  end
end

def show_aware(r: Result[Time.DateTime]) -> Void
  case r
    ok(t) -> puts(t)
    error(err) -> puts("#{err.kind}: #{err.message}")
  end
end

def main() -> Void
  show(Time.Date.new(2024, 2, 29))
  show(Time.Date.new(2026, 2, 29))
  show(Time.Date.new(0, 1, 1))
  show(Time.Date.new(10000, 1, 1))
  show(Time.Date.new(2026, 13, 1))
  show(Time.Date.new(2026, 4, 31))
  show_clock(Time.TimeOfDay.new(23, 59, 59, 999999))
  show_clock(Time.TimeOfDay.new(24, 0, 0, 0))
  show_clock(Time.TimeOfDay.new(0, 60, 0, 0))
  show_clock(Time.TimeOfDay.new(23, 59, 60, 0))
  show_clock(Time.TimeOfDay.new(0, 0, -1, 0))
  show_clock(Time.TimeOfDay.new(0, 0, 0, 1000000))
  puts(Time.NaiveDateTime.new(2026, 10, 14, 19, 5, 42, 201337))
  puts(Time.NaiveDateTime.new(2026, 10, 14, 19, 5, 60, 0))
  show_aware(Time.DateTime.new(2026, 10, 14, 21, 5, 42, 201337, 7200))
  show_aware(Time.DateTime.new(1, 1, 1, 0, 0, 0, 0, -86340))
  show_aware(Time.DateTime.new(2026, 10, 14, 21, 5, 42, 0, 86400))
  show_aware(Time.DateTime.new(2026, 10, 14, 21, 5, 42, 0, 30))
  show_aware(Time.DateTime.new(2026, 2, 30, 21, 5, 42, 0, 30))
  puts(Time.Date.leap?(2000))
  puts(Time.Date.leap?(1900))
  puts(Time.Date.days_in_month(2024, 2))
  puts(Time.Date.days_in_month(2026, 0))
  puts(Time.Date.days_in_month(0, 2))
  d = Time.Date.new(2026, 10, 14).unwrap!
  puts(d == Time.Date.new(2026, 10, 14).unwrap!)
  puts("#{d.year}-#{d.month}-#{d.day}")
  Time.Date.new(2026, 2, 29).unwrap!
end
