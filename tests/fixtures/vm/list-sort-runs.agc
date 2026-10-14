struct Row
  key: Int
  tag: String
end

def tag_of(row: Row) -> String
  return row.tag
end

def digest(xs: List[Int]) -> Int
  acc = 0
  for x in xs
    acc = (acc * 31 + x) % 1000003
  end
  return acc
end

def show(name: String, xs: List[Int]) -> Void
  last = xs.size - 1
  puts("#{name} size #{xs.size} edges #{xs[0]}..#{xs[last]} digest #{digest(xs)}")
end

def main() -> Void
  n = 3000
  scrambled = (0...n).to_a.map do |i| (i * 7919 + 13) % 1009 end
  ordered = scrambled.sort
  show("scrambled", scrambled)
  show("sorted", ordered)
  show("sorted again", ordered.sort)
  show("descending", ordered.reverse.sort)
  strict = (0...n).to_a.reverse
  show("strictly descending", strict.sort)
  show("strictly ascending", strict.reverse.sort)
  show("by negation", scrambled.sort_by do |x| 0 - x end)
  rows = [Row(key: 3, tag: "a"), Row(key: 3, tag: "b"), Row(key: 2, tag: "c"), Row(key: 2, tag: "d"), Row(key: 1, tag: "e"),
          Row(key: 1, tag: "f")]
  puts(rows.sort_by do |r| r.key end.map(&tag_of))
  puts(rows.reverse.sort_by do |r| r.key end.map(&tag_of))
  puts(rows.sort_by do |r| 0 - r.key end.map(&tag_of))
  distinct = [Row(key: 3, tag: "a"), Row(key: 2, tag: "b"), Row(key: 1, tag: "c")]
  puts(distinct.sort_by do |r| r.key end.map(&tag_of))
  puts(distinct.reverse.sort_by do |r| r.key end.map(&tag_of))
  words = scrambled.take(40).map do |x| "w#{x % 7}" end
  puts(words.sort.join(","))
  puts(words.sort_by do |w| w.length end.join(","))
  halves = scrambled.take(25).map do |x| x.to_f / 2.0 end
  puts(halves.sort)
  puts(halves.reverse.sort.reverse.take(5))
  nan = Float.from_bits(9221120237041090560)
  negzero = Float.from_bits(0 - 9223372036854775807 - 1)
  mixed = [3.5, nan, negzero, 0.0, -1.0, nan, 0.0, negzero, 2.0]
  puts(mixed.sort)
  puts(mixed.sort_by do |f| f end)
  puts(mixed.reverse.sort)
  puts([9.5, 4.25, 1.0, -0.5, -7.0].sort)
  puts([9.5, 4.25, 1.0, -0.5, -7.0].sort_by do |f| f end)
  puts([nan, 5.0, 1.0].sort)
  puts([nan, nan].sort)
  puts([negzero, 0.0].sort)
  puts([0.0, negzero].sort)
  least = 0 - 9223372036854775807 - 1
  most = 9223372036854775807
  puts([most, 0, -1, least, 5, least, most].sort)
  puts([most, 3, 0, -3, least].sort)
  puts([most, 3, 0, -3, least].sort_by do |x| x end)
  puts([least, -3, 0, 3, most].reverse.sort_by do |x| x end)
  falling = ["😀", "ÿ", "é", "z", "a", "Z", ""]
  puts(falling.sort)
  puts(falling.sort_by do |w| w end)
  shuffled = ["é", "z", "ÿ", "a", "😀", "Z", "", "é"]
  puts(shuffled.sort)
  puts(shuffled.sort_by do |w| w end)
  puts(shuffled.sort_by do |w| w.length end)
end
