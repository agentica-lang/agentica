def main() -> Void
  n = 0
  while n < 10
    n += 1
    if n == 3
      next
    end
    if n > 7
      break
    end
    puts(n)
  end
  xs = [3, 1, 2]
  total = 0
  for x in xs
    total += x
    for y in xs
      if y == x
        next
      end
      total += y
    end
  end
  for x in xs
  end
  names = Set.new(["b", "a"])
  for name in names
    puts(name)
  end
  for i in 1..3
    total += i
  end
  for i in 0...4
    if i == 2
      break
    end
    total += i
  end
  r = 2..4
  for i in r
    total += i
  end
  for i in 5...5
  end
  puts(total)
end
