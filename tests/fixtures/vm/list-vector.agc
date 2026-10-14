def pushed(n: Int) -> List[Int]
  xs: List[Int] = []
  i = 0
  while i < n
    xs = xs.push((i * 37) % 101)
    i += 1
  end
  return xs
end

def digest(xs: List[Int]) -> Int
  acc = 0
  for x in xs
    acc = (acc * 31 + x) % 1000003
  end
  return acc
end

def edges(xs: List[Int]) -> String
  if xs.size == 0
    return "empty"
  end
  return "#{xs[0]}..#{xs[xs.size - 1]}"
end

def show(name: String, xs: List[Int]) -> Void
  puts("#{name} size #{xs.size} edges #{edges(xs)} digest #{digest(xs)}")
end

def main() -> Void
  built: List[List[Int]] = []
  for n in [31, 32, 33, 1056, 1057]
    fresh = pushed(n)
    built = built.push(fresh)
    show("pushed", fresh)
  end
  marks = [0, 30, 31, 32, 1023, 1024, 1055, 1056]
  for row in built
    changed = row
    for m in marks
      if m < row.size
        changed = changed.set(m, 500 + m % 100)
      end
    end
    show("set", changed)
    show("old", row)
  end
  for row in built
    show("take 32", row.take(32))
    show("take 33", row.take(33))
    show("drop 31", row.drop(31))
    show("drop 32", row.drop(32))
    show("reverse", row.reverse)
  end
  big = (0...32769).to_a
  show("range", big)
  top = big.set(32768, 7).set(32767, 8).set(32, 9).set(0, 10)
  show("set range", top)
  show("old range", big)
  show("take 32768", big.take(32768))
  show("take 33", big.take(33))
  show("drop 32768", big.drop(32768))
  show("drop 32", big.drop(32))
  zero: List[Int] = []
  for part in [zero, [1], pushed(32), pushed(33)]
    show("concat right #{part.size}", big.concat(part))
    show("concat left #{part.size}", part.concat(big))
  end
  show("reverse", big.reverse)
  show("reverse twice", big.reverse.reverse)
  scrambled = big.map do |x| (x * 7919) % 32771 end
  show("map", scrambled)
  show("sorted", scrambled.sort)
  show("scrambled again", scrambled)
  multiples = big.filter do |x| x % 3 == 0 end
  show("filter", multiples)
  total = 0
  for x in big
    total += x
  end
  puts("sum #{total}")
  puts("boundary #{big[32767]} #{big[32768]} #{big.at(32)} #{built[4][1056]}")
  puts("before out of range")
  puts(big[32769])
end
