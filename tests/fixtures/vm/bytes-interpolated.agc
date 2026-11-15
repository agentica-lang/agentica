# `"a#{b}c".bytes` writes the parts into one Bytes: the same bytes as the String's, for every kind of part, for one
# part, for the most parts one builtin takes and one more, and for no bytes at all.
struct Point
  x: Int
  y: Float
end

def same(made: Bytes, text: String) -> Bool = made == text.bytes

def header(count: Int) -> Bytes = "$#{count}\r\n".bytes

def main() -> Void
  n = -42
  f = 1.5
  name = "ñ"
  point = Point(x: 1, y: 2.0)
  data = "abc".bytes
  puts(header(120).to_a)
  puts(same("#{n}".bytes, "#{n}"))
  puts(same("#{name}".bytes, name))
  puts(same("#{n} #{f} #{true} #{nil} #{name}".bytes, "#{n} #{f} #{true} #{nil} #{name}"))
  puts(same("#{[1, 2]} #{point} #{{"k": n}}".bytes, "#{[1, 2]} #{point} #{{"k": n}}"))
  puts(same("#{data} #{some(n)} #{ok(n)}".bytes, "#{data} #{some(n)} #{ok(n)}"))
  puts(same("#{n}#{n}#{n}#{n}#{n}#{n}#{n}#{n}".bytes, "#{n}#{n}#{n}#{n}#{n}#{n}#{n}#{n}"))
  puts(same("#{n}#{n}#{n}#{n}#{n}#{n}#{n}#{n}#{n}".bytes, "#{n}#{n}#{n}#{n}#{n}#{n}#{n}#{n}#{n}"))
  empty = ""
  puts("#{empty}#{empty}".bytes.length)
  puts("#{empty}".bytes == "".bytes)
  parts = [1, 2, 3].map do |k: Int| "#{k}:#{k * k};".bytes end
  puts(Bytes.concat(parts).to_a)
  puts("#{-9223372036854775807 - 1}|#{9223372036854775807}|#{0}".bytes.to_a)
end
