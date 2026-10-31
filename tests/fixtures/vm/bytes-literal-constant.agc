# `"text".bytes` on a literal is one Bytes constant made at load: equal to the copy that an interpolated string or
# String.bytes on a variable makes, in a loop, empty, non-ASCII and as a module constant.
SEP = "\n\n".bytes

def main() -> Void
  total = 0
  for k in 0...1000
    total += "xy".bytes.length
  end

  puts(total)
  word = "xy"
  puts("xy".bytes == word.bytes)
  puts("".bytes == Bytes.from_list([]).unwrap!)
  puts("ñ".bytes.to_a)
  name = "z"
  puts("a#{name}".bytes == "az".bytes)
  puts(SEP.to_a)
end
