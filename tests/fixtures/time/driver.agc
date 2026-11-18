## Test driver of tests/test_time.py: reads one JSON case per line of stdin, calls the Time builtin it names with its
## Int arguments and prints one JSON line: whether it succeeded, the fields or value it gave, and the error kind.

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

def datetime(a: List[Int]) -> Reply
  case Time.DateTime.new(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7])
    ok(t) -> done([t.year, t.month, t.day, t.hour, t.min, t.sec, t.usec, t.utc_offset])
    error(err) -> failed(err)
  end
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
  case c.op
    "date" -> date(c.args)
    "time_of_day" -> time_of_day(c.args)
    "naive" -> naive(c.args)
    "datetime" -> datetime(c.args)
    "days_in_month" -> days_in_month(c.args)
    _ -> leap(c.args)
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
