# strftime of the Time family: every directive of the subset on each type, a directive a type cannot fill and an
# unknown one copied as written, the % that ends a format, years before 1000 with four digits, and the size of a text
# with characters past ASCII.
def main() -> Void
  t = Time.DateTime.new(2026, 10, 14, 21, 5, 42, 201337, -12600).unwrap!
  puts(t.strftime("%Y-%m-%d %H:%M:%S.%L %N %z %:z"))
  puts(t.strftime("%j %u %w %a %A %b %B %%"))
  puts(t.strftime("%Q %-d %5Y %:x %E %"))
  puts(t.naive_of.strftime("%d %B %Y, %H:%M %z %:z"))
  puts(t.to_date.strftime("%A %-d %e %H"))
  puts(Time.TimeOfDay.new(7, 3, 0, 5).unwrap!.strftime("%H:%M:%S.%N %Y"))
  puts(Time.Date.new(999, 1, 3).unwrap!.strftime("%Y %j %u %w %a"))
  puts(Time.DateTime.new(1, 1, 1, 0, 0, 0, 0, 0).unwrap!.strftime("%Y-%m-%d %a %z"))
  text = t.strftime("día %d · %B")
  puts("#{text} #{text.size}")
  puts(t.strftime("").size)
end
