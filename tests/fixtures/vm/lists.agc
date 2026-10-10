def evens(limit: Int) -> List[Int]
  out: List[Int] = []
  i = 0
  while i < limit
    out = [i, i + 2]
    i += 4
  end
  return out
end

def total(xs: List[Int]) -> Int
  sum = 0
  for x in xs
    sum += x
  end
  return sum
end

def main() -> Void
  ints = [3, -1, 9223372036854775807]
  big = 10.0
  while big < big * 10.0
    big = big * 10.0
  end
  floats = [1.5, -0.0, 1.0 / 3.0, big, -big, big - big, 100000000000000000000.0 * 10.0]
  strings = ["plain", "quote \" and \\", "tab\tnew\nline", "", "λ 😀"]
  puts(ints)
  puts(floats)
  puts(strings)
  print([true, false])
  print("\n")
  IO.warn([nil])
  empty: List[String] = []
  puts(empty)
  nested = [[1, 2], [], [3]]
  deeper = [[["a"], []], [["b", "c"]]]
  puts(nested)
  puts(deeper)
  puts("ints #{ints}, deeper #{deeper}, empty #{empty}")
  puts(nested.to_s)
  puts(strings.inspect)
  puts(deeper.inspect)
  puts(strings[1])
  puts(strings[1].inspect)
  puts(nested[2][0] + ints[0])
  puts(deeper[1][0][1])
  puts(evens(10))
  puts(total([1, 2, 3, 4]))
  puts(total([]))
  for row in nested
    puts("row #{row}")
    for x in row
      if x == 2
        next
      end
      puts(x)
    end
  end
  seen = 0
  for s in strings
    seen += 1
    if s == ""
      break
    end
    print("#{s.inspect} ")
  end
  puts(seen)
  items = [10, 20, 30]
  for x in items
    items = [x]
    puts(x)
  end
  puts(items)
  for x in [1, 2]
  end
  for x in empty
    puts("never")
  end
  i = 0
  while i < 3
    puts(ints[i])
    i += 1
  end
  for row in [[1, 2], [3]]
    for v in row
      print("#{v} ")
    end
    puts("")
  end
  k = 0
  for n in [2, 1]
    while k < n
      print(n)
      k += 1
    end
    puts("")
  end
end
