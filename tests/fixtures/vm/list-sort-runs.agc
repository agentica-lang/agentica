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
end
