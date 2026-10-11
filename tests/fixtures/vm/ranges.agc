def show(n: Int) -> Void
  print(n)
end

def main() -> Void
  for i in 0...3 do
    print(i)
  end
  for i in 1..3
    if i == 2
      next
    end
    print(i)
  end
  for i in 3..1
    print(i)
  end
  for i in 2...2
  end
  r = 9223372036854775806..9223372036854775807
  for i in r
    r = 1..1
    puts(" #{i}")
  end
  e = (-9223372036854775807)...(-9223372036854775808)
  for i in e
    print(i)
  end
  for i in (-9223372036854775808)...(-9223372036854775807)
    puts(i)
    break
  end
  3.times do |i|
    print(i)
  end
  0.times(&show)
  9223372036854775806.upto(9223372036854775807) do |i|
    puts(i)
  end
  (-9223372036854775807).downto(-9223372036854775808, &show)
  3.upto(1, &show)
  (1...4).each(&show)
  puts("")
  IO.inspect([1..5, 1...5, (-3)..(-1), (-9223372036854775808)...(-9223372036854775808)])
  puts([(1...5).size, (5..1).size, (0..9223372036854775806).size])
  puts([(1...5).last, (1..5).first, (2...2).first, e.last])
  puts([(1..5) == (1..5), (1..5) != (1...5), r.include?(1), (1...5).include?(5)])
  puts("#{1..2} #{(1...2).inspect} #{(1..2).to_s}")
  puts((0..6).to_a.filter do |n|
    n % 3 == 0
  end)
  puts(Range.to_a(5...5))
end
