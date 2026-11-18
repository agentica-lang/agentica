# Unix time and offsets in the Time family: the instants around the epoch and the ends of the range, to_i rounding
# toward minus infinity, a change of offset that keeps the instant, and the errors with their messages.
def show(r: Result[Time.DateTime]) -> Void
  case r
    ok(t) -> puts(t)
    error(err) -> puts("#{err.kind}: #{err.message}")
  end
end

def main() -> Void
  show(Time.at(0))
  show(Time.at(-1))
  show(Time.at(-62135596800))
  show(Time.at(-62135596801))
  show(Time.at(253402300799))
  show(Time.at(9223372036854775807))
  show(Time.at_us(-1))
  show(Time.at_us(253402300799999999))
  show(Time.at_us(253402300800000000))
  before = Time.at_us(-1).unwrap!
  puts("#{before.to_i} #{before.to_us}")
  puts(Time.at_us(-1000001).unwrap!.to_i)
  t = Time.DateTime.new(2026, 10, 14, 21, 5, 42, 201337, 7200).unwrap!
  puts("#{t.to_i} #{t.to_us}")
  show(t.getlocal(-18000))
  show(t.getutc)
  show(t.getlocal(30))
  show(t.getlocal(86400))
  puts(t.naive_of)
  puts(t.to_date)
  first = Time.DateTime.new(1, 1, 1, 0, 30, 0, 0, 3600).unwrap!
  puts(first.to_us)
  show(first.getutc)
  show(first.getlocal(7200))
  n = Time.NaiveDateTime.new(2024, 2, 29, 23, 30, 0, 5).unwrap!
  show(n.assume_offset(-3600))
  show(n.assume_offset(61))
  puts(n.to_date)
  puts(n.assume_offset(-3600).unwrap!.getutc.unwrap!.to_date)
  puts(Time.now().utc_offset)
end
