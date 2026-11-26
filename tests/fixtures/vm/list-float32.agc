# A List[Float32] is stored packed, 4 bytes per item, and behaves as a list of tagged values did: text forms, JSON,
# equality, and the list operations, at the lengths around the 32-way trie boundaries. The bits of every item against a
# Python peer are in tests/fixtures/vm/list-float32-vectors.agc.
struct Reading
  samples: List[Float32]
end

def bits(x: Float32) -> Int = x.to_bits.to_i

def digest(xs: List[Float32]) -> Int
  acc = 0
  for x in xs
    acc = (acc * 31 + bits(x) % 1000003) % 1000003
  end
  return acc
end

def show(name: String, xs: List[Float32]) -> Void
  puts("#{name} size #{xs.size} digest #{digest(xs)}")
end

def ramp(n: Int) -> List[Float32]
  return (0...n).to_a.map do |i| i.to_float32 / 8.0 end
end

def specials() -> List[Float32]
  bit_patterns = [2147483648, 0, 2143289344, 2139095040, 4286578688, 8388608, 1, 2139095039, 8388607, 3212836864]
  return bit_patterns.map do |b| Float32.from_bits(b.wrap_uint32) end
end

def main() -> Void
  xs: List[Float32] = [1.5, -0.25, 1e-45, 16777217.0, 0.1, 3.4028235e38]
  puts(xs)
  puts(xs.inspect)
  puts("#{xs}")
  puts(xs.to_s)
  puts(xs.reverse)
  puts([xs[0] + xs[1], xs[4] * xs[4], xs[3] - 1.0, xs[5] * 2.0, xs[1] / 3.0])

  odd = specials()
  puts(odd)
  puts(odd.map do |x| bits(x) end)
  puts(odd == odd)
  puts(odd.take(2) == [0.0, -0.0])
  puts(odd.drop(5) == odd.drop(5))
  puts(odd.reverse.reverse.map do |x| bits(x) end)

  [0, 1, 2, 31, 32, 33, 64, 65, 1024, 1056, 1057, 1058, 40000].each do |n|
    list = ramp(n)
    pushed: List[Float32] = []
    for x in list
      pushed = pushed.push(x)
    end
    show("ramp #{n}", list)
    puts(list == pushed)
    puts(digest(list.reverse) == digest(pushed.reverse))
    if n > 3
      cut = n / 3
      show("take", list.take(cut))
      show("drop", list.drop(cut))
      show("join", list.drop(cut).concat(list.take(cut)))
      show("set", list.set(cut, -1.5).set(n - 1, 0.25))
      show("evens", list.select do |x| bits(x) % 3 == 0 end)
      puts("#{list.first} #{list.last} #{list[cut]} #{list.include?(list[cut])} #{list.include?(-3.0)}")
      zero: Float32 = 0.0
      puts(list.reduce(zero) do |acc, x| acc + x end)
    end
  end

  scaled: List[Float32] = List.repeat(0.1, 70)
  show("repeat", scaled)
  puts(scaled.map do |x| x * 3.0 end == List.repeat(0.3, 70))
  puts(scaled.sort_by do |x| -x.to_f end == scaled)

  json = JSON.encode(Reading(samples: ramp(40)))
  puts(json)
  puts(JSON.decode(json, Reading).unwrap!.samples == ramp(40))
  puts(JSON.encode(xs.take(5)))
  puts(JSON.decode("[0.1, 2.5, 1e39]", List[Float32]))
  puts(JSON.decode("[0.1, 2.5, 7.0e-46]", List[Float32]))
end
