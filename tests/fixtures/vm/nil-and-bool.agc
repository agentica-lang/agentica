def same(a: Bool, b: Bool) -> Bool
  return a == b
end

def main() -> Void
  n = nil
  m = nil
  puts(n)
  print(n)
  print(" ")
  puts(n == m)
  puts(n != nil)
  puts(true)
  puts(false)
  puts(same(true, not false))
  IO.print(1)
  IO.print(2.5)
  IO.print(true)
  puts("")
  if n == nil
    n = nil
    puts(n)
  end
end
