## Test driver of tests/test_time.py: reads one JSON case per line of stdin, calls the Time builtin it names with its
## Int arguments (or its text) and prints one JSON line: whether it succeeded, the fields, value or text it gave, and
## the error kind. A conversion takes the fields of a valid value first, which the driver builds with its constructor.

struct Case
  op: String
  args: List[Int]
  text: String
end

struct Reply
  ok: Bool
  fields: List[Int]
  kind: String
  text: String
end

def done(fields: List[Int]) -> Reply = Reply(ok: true, fields: fields, kind: "", text: "")

def failed(err: Error) -> Reply = Reply(ok: false, fields: [], kind: err.kind, text: err.message)

def written(text: String) -> Reply = Reply(ok: true, fields: [], kind: "", text: text)

def date(a: List[Int]) -> Reply
  case Time.Date.new(a[0], a[1], a[2])
    ok(d) -> done([d.year, d.month, d.day])
    error(err) -> failed(err)
  end
end

def time_of_day(a: List[Int]) -> Reply
  case Time.TimeOfDay.new(a[0], a[1], a[2], a[3])
    ok(t) -> done([t.hour, t.min, t.sec, t.usec])
    error(err) -> failed(err)
  end
end

def naive(a: List[Int]) -> Reply
  case Time.NaiveDateTime.new(a[0], a[1], a[2], a[3], a[4], a[5], a[6])
    ok(t) -> done([t.year, t.month, t.day, t.hour, t.min, t.sec, t.usec])
    error(err) -> failed(err)
  end
end

def datetime(a: List[Int]) -> Reply = aware_reply(Time.DateTime.new(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7]))

def aware_reply(built: Result[Time.DateTime]) -> Reply
  case built
    ok(t) -> done(aware_fields(t))
    error(err) -> failed(err)
  end
end

def aware_fields(t: Time.DateTime) -> List[Int] = [t.year, t.month, t.day, t.hour, t.min, t.sec, t.usec, t.utc_offset]

def naive_fields(t: Time.NaiveDateTime) -> List[Int] = [t.year, t.month, t.day, t.hour, t.min, t.sec, t.usec]

def aware(a: List[Int]) -> Time.DateTime = aware_at(a, 0)

def plain(a: List[Int]) -> Time.NaiveDateTime = plain_at(a, 0)

def aware_at(a: List[Int], i: Int) -> Time.DateTime
  Time.DateTime.new(a[i], a[i + 1], a[i + 2], a[i + 3], a[i + 4], a[i + 5], a[i + 6], a[i + 7]).unwrap!
end

def plain_at(a: List[Int], i: Int) -> Time.NaiveDateTime
  Time.NaiveDateTime.new(a[i], a[i + 1], a[i + 2], a[i + 3], a[i + 4], a[i + 5], a[i + 6]).unwrap!
end

def day_at(a: List[Int], i: Int) -> Time.Date = Time.Date.new(a[i], a[i + 1], a[i + 2]).unwrap!

def clock_at(a: List[Int], i: Int) -> Time.TimeOfDay = Time.TimeOfDay.new(a[i], a[i + 1], a[i + 2], a[i + 3]).unwrap!

def arithmetic(op: String, a: List[Int]) -> Reply
  case op
    "date_add_days" -> date_reply(day_at(a, 0).add_days(a[3]))
    "naive_add_days" -> naive_reply(plain(a).add_days(a[7]))
    "aware_add_days" -> aware_reply(aware(a).add_days(a[8]))
    "naive_add_us" -> naive_reply(plain(a).add_us(a[7]))
    "aware_add_us" -> aware_reply(aware(a).add_us(a[8]))
    "days_between" -> done([day_at(a, 0).days_between(day_at(a, 3))])
    "us_between" -> done([aware(a).us_between(aware_at(a, 8))])
    "naive_us_between" -> done([plain(a).us_between(plain_at(a, 7))])
    "compare" -> done([Time.compare(aware(a), aware_at(a, 8))])
    "compare_naive" -> done([Time.compare_naive(plain(a), plain_at(a, 7))])
    "compare_date" -> done([Time.compare_date(day_at(a, 0), day_at(a, 3))])
    "compare_time" -> done([Time.compare_time(clock_at(a, 0), clock_at(a, 4))])
    "cwday" -> done([day_at(a, 0).cwday])
    _ -> done([day_at(a, 0).yday])
  end
end

def date_fields(d: Time.Date) -> List[Int] = [d.year, d.month, d.day]

def now() -> Reply
  t = Time.now()
  done(aware_fields(t).push(t.to_us))
end

def days_in_month(a: List[Int]) -> Reply
  case Time.Date.days_in_month(a[0], a[1])
    ok(n) -> done([n])
    error(err) -> failed(err)
  end
end

def leap(a: List[Int]) -> Reply
  return done([1]) if Time.Date.leap?(a[0])

  done([0])
end

def run_case(c: Case) -> Reply
  a = c.args
  case c.op
    "date" -> date(a)
    "time_of_day" -> time_of_day(a)
    "naive" -> naive(a)
    "datetime" -> datetime(a)
    "days_in_month" -> days_in_month(a)
    "leap" -> leap(a)
    _ -> convert(c.op, a, c.text)
  end
end

def date_reply(built: Result[Time.Date]) -> Reply
  case built
    ok(d) -> done(date_fields(d))
    error(err) -> failed(err)
  end
end

def clock_reply(built: Result[Time.TimeOfDay]) -> Reply
  case built
    ok(t) -> done([t.hour, t.min, t.sec, t.usec])
    error(err) -> failed(err)
  end
end

def naive_reply(built: Result[Time.NaiveDateTime]) -> Reply
  case built
    ok(t) -> done(naive_fields(t))
    error(err) -> failed(err)
  end
end

def text_case(op: String, a: List[Int], text: String) -> Reply
  case op
    "format_date" -> written(Time.Date.new(a[0], a[1], a[2]).unwrap!.iso8601)
    "format_time_of_day" -> written(Time.TimeOfDay.new(a[0], a[1], a[2], a[3]).unwrap!.iso8601)
    "format_naive" -> written(plain(a).iso8601)
    "format_datetime" -> written(aware(a).iso8601)
    "parse_date" -> date_reply(Time.Date.iso8601(text))
    "parse_time_of_day" -> clock_reply(Time.TimeOfDay.iso8601(text))
    "parse_naive" -> naive_reply(Time.NaiveDateTime.iso8601(text))
    _ -> aware_reply(Time.DateTime.iso8601(text))
  end
end

def convert(op: String, a: List[Int], text: String) -> Reply
  case op
    "at" -> aware_reply(Time.at(a[0]))
    "at_us" -> aware_reply(Time.at_us(a[0]))
    "to_i" -> done([aware(a).to_i])
    "to_us" -> done([aware(a).to_us])
    "getlocal" -> aware_reply(aware(a).getlocal(a[8]))
    "getutc" -> aware_reply(aware(a).getutc)
    "assume_offset" -> aware_reply(plain(a).assume_offset(a[7]))
    "naive_of" -> done(naive_fields(aware(a).naive_of))
    "to_date" -> done(date_fields(aware(a).to_date))
    "naive_to_date" -> done(date_fields(plain(a).to_date))
    "now" -> now()
    _ -> more(op, a, text)
  end
end

def main() -> Void
  while true
    line = IO.gets()
    return if !line.ok?

    case JSON.decode(line.unwrap!, Case)
      ok(c) -> puts(JSON.encode(run_case(c)))
      error(err) -> puts("bad case: #{err.message}")
    end
  end
end

def more(op: String, a: List[Int], text: String) -> Reply
  return text_case(op, a, text) if op.start_with?("format_") or op.start_with?("parse_")

  arithmetic(op, a)
end
