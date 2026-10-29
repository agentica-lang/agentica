struct Nums
  ints: List[Int]
  floats: List[Float]
end

def bits_digest(xs: List[Float]) -> Int
  acc = 0
  for x in xs
    b = Float.to_bits(x) % 1000003
    if b < 0
      b = b + 1000003
    end
    acc = (acc * 31 + b) % 1000003
  end
  return acc
end

def int_digest(xs: List[Int]) -> Int
  acc = 0
  for x in xs
    b = x % 1000003
    if b < 0
      b = b + 1000003
    end
    acc = (acc * 31 + b) % 1000003
  end
  return acc
end

def show_floats(name: String, xs: List[Float]) -> Void
  puts("#{name} size #{xs.size} digest #{bits_digest(xs)}")
end

def show_ints(name: String, xs: List[Int]) -> Void
  puts("#{name} size #{xs.size} digest #{int_digest(xs)}")
end

def float_bits(xs: List[Float]) -> List[Int]
  return xs.map do |x| Float.to_bits(x) end
end

def sum_of(xs: List[Int]) -> Int
  total = 0
  for x in xs
    total += x
  end
  return total
end

def larger(a: Int, b: Int) -> Int
  if b > a
    return b
  end
  return a
end

def main() -> Void
  lowest = 0 - 9223372036854775807 - 1
  highest = 9223372036854775807
  extremes = [highest, 0, lowest, 0 - 1, 1, lowest + 1, highest - 1]
  puts(extremes)
  puts(extremes.sort)
  puts(extremes.sort.reverse)
  puts(extremes.reverse.sort)
  puts(extremes.set(2, 5).push(lowest).take(6).concat([highest]))
  puts(extremes.drop(3).concat(extremes.take(3)))
  puts("#{extremes.size} #{extremes[0]} #{extremes[2]} #{extremes.reduce(lowest) do |a, x| larger(a, x) end}")

  nan = Float.from_bits(9221120237041090560)
  infinity = Float.from_bits(9218868437227405312)
  neg_infinity = Float.from_bits(0 - 4503599627370496)
  negzero = Float.from_bits(0 - 9223372036854775807 - 1)
  tiny = Float.from_bits(1)
  biggest = Float.from_bits(9218868437227405311)
  specials = [negzero, 0.0, nan, infinity, neg_infinity, tiny, biggest, 1.5, 0.0 - 2.25]
  puts(specials)
  puts(float_bits(specials))
  puts(float_bits(specials.sort))
  puts(float_bits(specials.reverse.sort))
  puts(float_bits(specials.sort_by do |f| f end))
  puts(float_bits(specials.reverse))
  puts(float_bits(specials.set(0, 0.0).set(1, negzero)))
  puts(float_bits(specials.push(negzero).take(4)))
  puts(float_bits(specials.drop(4).concat(specials.take(4))))
  puts(float_bits(List.repeat(negzero, 5)))
  puts(float_bits(specials.map do |f| f end))
  puts(float_bits(specials.filter do |f| f == f end))
  puts("#{[negzero]} #{[0.0, negzero].sort} #{[negzero, 0.0].sort} #{[nan, 1.0].sort}")
  puts(specials.any? do |f| f != f end)
  puts(specials.all? do |f| f == f end)

  for n in [0, 1, 2, 31, 32, 33, 63, 64, 65, 1023, 1024, 1025, 1056, 1057]
    ints = (0...n).to_a.map do |i| (i * 7919 + 13) % 1009 - 500 end
    floats = ints.map do |i| i.to_f * 0.25 end
    show_ints("ints #{n}", ints)
    show_floats("floats #{n}", floats)
    show_ints("sorted ints #{n}", ints.sort)
    show_floats("sorted floats #{n}", floats.sort)
    show_ints("by key #{n}", ints.sort_by do |i| 0 - i end)
    show_floats("floats by key #{n}", floats.sort_by do |f| 0.0 - f end)
    show_ints("reversed #{n}", ints.reverse)
    show_floats("reversed floats #{n}", floats.reverse)
    show_ints("take #{n}", ints.take(33))
    show_ints("drop #{n}", ints.drop(32))
    show_floats("floats take #{n}", floats.take(64))
    show_floats("floats drop #{n}", floats.drop(33))
    show_ints("concat #{n}", ints.concat(ints.reverse))
    show_floats("floats concat #{n}", floats.concat(floats.take(32)))
    show_ints("repeat #{n}", List.repeat(7, n))
    show_floats("floats repeat #{n}", List.repeat(2.5, n))
    puts("sum #{n} #{sum_of(ints)}")
  end

  pushed: List[Int] = []
  floats_pushed: List[Float] = []
  i = 0
  while i < 100
    pushed = pushed.push(i * i - 2000)
    floats_pushed = floats_pushed.push(i.to_f / 8.0)
    i += 1
  end
  show_ints("pushed", pushed)
  show_floats("floats pushed", floats_pushed)
  puts(pushed.take(10))
  puts(floats_pushed.drop(90))
  puts(pushed.set(50, 0 - 1)[50])
  puts(pushed[50])
  puts("#{pushed.reduce(0) do |a, x| a + x end} #{floats_pushed.reduce(0.0) do |a, x| a + x end}")

  nums = Nums(ints: pushed.take(40), floats: [0.5, negzero, 10000000000.0, 0.0 - 3.75])
  text = JSON.encode(nums)
  puts(text)
  back = Result.unwrap!(JSON.decode(text, Nums))
  puts(back.ints.size)
  puts(float_bits(back.floats))
  show_ints("decoded", back.ints)
  puts(Result.unwrap!(JSON.parse("[1, 2, 3, 4.5]")))

  bytes = [104, 195, 169, 108, 108, 111, 32, 119, 195, 182, 114, 108, 100]
  puts(String.from_bytes(Bytes.from_list(bytes.reverse.reverse).unwrap!))
  puts(String.from_bytes(Bytes.from_list(bytes.take(3)).unwrap!))
  puts(String.from_bytes(Bytes.from_list([255, 104]).unwrap!))
  puts((1..70).to_a.size)
  puts(((0...40).to_a.map do |x| x * x end).reverse.take(3))
  [3, 4, 5].each do |x| puts(x * 2) end
end
