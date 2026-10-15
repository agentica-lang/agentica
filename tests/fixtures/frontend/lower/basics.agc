def add(a: Int, b: Int) -> Int
  return a + b
end

def scale(x: Float, k: Float) -> Float
  return -x * k / 2.0 - 1.5 + x
end

def join(a: String, b: String) -> String
  return a + "-" + b
end

def sign(n: Int) -> String
  if n < 0
    return "neg"
  elsif n == 0
    return "zero"
  elsif n >= 10 and n <= 20 or n == 99
    return "mid"
  else
    return "pos"
  end
end

def main() -> Void
  total = add(1, 2) * 3 - 4 / 2 % 5
  flag = !(total > 3) or not (total != 2)
  x = scale(2.5, 4.0)
  if x <= 1.0 and x > -1.0
    puts("#{total} #{flag} #{x} #{join("a", "b")} #{sign(total)}")
  end
  r = 1..5
  s = 1...5
  puts("#{r} #{s} #{r.size}")
  puts(-total)
end
