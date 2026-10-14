def label(n: Int) -> String
  out = ""
  case n
    1_000 -> out = "thousand"
    -1_000 -> out = "minus thousand"
    _ -> out = "other"
  end
  return out
end

def main() -> Void
  budget = 1_000_000
  rate = 0.000_5
  big = 9_223_372_036_854_775_807
  puts(budget)
  puts(rate)
  puts(1_000.5_5)
  puts(big)
  puts(budget == 1000000)
  puts("#{1_000}")
  total = 0
  for i in 1_0..1_2
    total += i
  end
  puts(total)
  puts(label(1000))
  puts(label(-1_000))
  puts(label(5))
  puts(String.to_int("1_000"))
  puts(String.to_float("1_0.5"))
  puts(String.to_int!("1_000"))
end
