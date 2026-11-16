# Conditions of if, elsif, unless-style not, while and case guards built from and, or and not jump from each operand:
# an operand runs only when the ones before it did not decide, and every combination takes the same branch as the
# Bool would. `hot` runs the conditions in a loop, so the JIT compiles the same jumps.
def seen(name: String, value: Bool) -> Bool
  puts(name)
  value
end

def branch(a: Bool, b: Bool, c: Bool) -> String
  if (seen("a", a) and seen("b", b)) or not seen("c", c)
    "first"
  elsif !(a or b) and !not c
    "second"
  else
    "third"
  end
end

def guard(n: Int, a: Bool, b: Bool) -> String
  case n
    0 if a and not b -> "zero-a"
    0 if not (a or b) -> "zero-none"
    _ if a or b and n > 1 -> "other"
    _ -> "rest"
  end
end

def hot(limit: Int) -> Int
  count = 0
  i = 0
  while i < limit and not (i > 5000 and i % 7 == 3)
    if i % 2 == 0 or (i % 3 == 0 and not (i % 5 == 0))
      count += 1
    end
    i += 1
  end
  count * 10000 + i
end

def main() -> Void
  flags = [true, false]
  for a in flags
    for b in flags
      for c in flags
        puts("#{a} #{b} #{c}: #{branch(a, b, c)}")
      end
    end
  end

  for n in [0, 1, 2]
    for a in flags
      for b in flags
        puts("#{n} #{a} #{b}: #{guard(n, a, b)}")
      end
    end
  end

  puts(hot(10000))
end
