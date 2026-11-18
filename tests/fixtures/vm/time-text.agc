# The ISO 8601 text of the Time family: each type written with six fraction digits and Z or +HH:MM, then the forms a
# parse reads (lowercase t and z, -00:00, digits past the sixth cut off) and each error with its message.
def show(r: Result[Time.DateTime]) -> Void
  case r
    ok(t) -> puts(t.iso8601)
    error(err) -> puts("#{err.kind}: #{err.message}")
  end
end

def main() -> Void
  t = Time.DateTime.new(2026, 10, 14, 21, 5, 42, 201337, 7200).unwrap!
  puts(t.iso8601)
  puts(t.getutc.unwrap!.iso8601)
  puts(t.getlocal(-34200).unwrap!.iso8601)
  puts(t.naive_of.iso8601)
  puts(t.to_date.iso8601)
  puts(Time.TimeOfDay.new(7, 3, 0, 5).unwrap!.iso8601)
  puts(Time.at(-62135596800).unwrap!.iso8601)
  show(Time.DateTime.iso8601("2026-10-14T19:05:42.201337Z"))
  show(Time.DateTime.iso8601("2026-10-14t19:05:42.123456789z"))
  show(Time.DateTime.iso8601("2026-10-14T19:05:42.5-00:00"))
  show(Time.DateTime.iso8601("2026-10-14T19:05:42+05:30"))
  show(Time.DateTime.iso8601("2026-10-14T19:05:42"))
  show(Time.DateTime.iso8601("2026-10-14 19:05:42Z"))
  show(Time.DateTime.iso8601("2026-10-14T19:05:42.Z"))
  show(Time.DateTime.iso8601("2026-10-14T19:05:60Z"))
  show(Time.DateTime.iso8601("2026-10-14T19:05:42+24:00"))
  show(Time.DateTime.iso8601("2026-10-14T19:05:42+01:60"))
  show(Time.DateTime.iso8601("2026-10-14T19:05:42+0200"))
  show(Time.DateTime.iso8601("2026-10-14T19:05:42Zx"))
  show(Time.DateTime.iso8601("2026-02-30T00:00:00Z"))
  show(Time.DateTime.iso8601("0000-01-01T00:00:00Z"))
  show(Time.DateTime.iso8601(""))
  puts(Time.NaiveDateTime.iso8601("2026-10-14T19:05:42+02:00"))
  puts(Time.NaiveDateTime.iso8601("2026-10-14T19:05:42z"))
  puts(Time.NaiveDateTime.iso8601("2026-10-14T19:05:42.000001"))
  puts(Time.Date.iso8601("2026-10-14"))
  puts(Time.Date.iso8601("2026-10-14T00:00:00"))
  puts(Time.Date.iso8601("２０２６-10-14"))
  puts(Time.TimeOfDay.iso8601("07:32"))
  puts(Time.TimeOfDay.iso8601("07:32:00.5"))
end
