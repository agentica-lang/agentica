## Test driver of tests/test_time.py: reads one JSON case per line of stdin, calls the Time builtin it names with its
## Int arguments and prints one JSON line: whether it succeeded, the fields or value it gave, and the error kind. A
## conversion takes the fields of a valid value first, which the driver builds with its constructor.

struct Case
  op: String
  args: List[Int]
end

struct Reply
  ok: Bool
  fields: List[Int]
  kind: String
end

def done(fields: List[Int]) -> Reply = Reply(ok: true, fields: fields, kind: "")

def failed(err: Error) -> Reply = Reply(ok: false, fields: [], kind: err.kind)

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

def aware(a: List[Int]) -> Time.DateTime = Time.DateTime.new(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7]).unwrap!

def plain(a: List[Int]) -> Time.NaiveDateTime
  Time.NaiveDateTime.new(a[0], a[1], a[2], a[3], a[4], a[5], a[6]).unwrap!
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
    _ -> convert(c.op, a)
  end
end

def convert(op: String, a: List[Int]) -> Reply
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
    _ -> now()
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
