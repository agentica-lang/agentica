def classify(n: Int) -> Int
  if n < 0
    return -1
  elsif n == 0
    return 0
  elsif n < 10
    return 1
  else
    return 2
  end
end

def main() -> Void
  puts(classify(-3))
  puts(classify(0))
  puts(classify(7))
  puts(classify(42))
  i = 0
  total = 0
  while i < 12
    i += 1
    if i % 3 == 0
      next
    end
    if i > 10
      break
    end
    j = 0
    while true
      j += 1
      if j > 2
        break
      end
      total += i * j
    end
  end
  puts(total)
  puts(i)
  while false
    puts("never")
  end
  puts("done")
end
