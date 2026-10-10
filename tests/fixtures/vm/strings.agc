def shout(text: String, times: Int) -> String
  result = ""
  i = 0
  while i < times
    result = result + text
    i = i + 1
  end
  return result + "!"
end

def same(a: String, b: String) -> Void
  puts("#{a.inspect} == #{b.inspect}: #{a == b}, != #{a != b}")
end

def main() -> Void
  puts(shout("ab", 3))
  puts(shout("", 2))
  empty = ""
  puts(empty)
  print(empty + "")
  puts("é" + "😀" + "")
  same("", "")
  same("a", "")
  same("abc", "abd")
  same("abc", "ab")
  same("é", "é".to_s)
  same("é", "é")
  same("😀", "😀")
  same("a" + "b", "ab")
  print("no newline")
  print(" then ")
  puts("end")
  IO.puts("io puts")
  IO.print("io print\n")
  IO.warn("to stderr")
  IO.warn(42)
  puts(String.from_int(-9223372036854775807 - 1))
  puts(String.from_float(0.1 + 0.2))
end
