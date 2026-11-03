# List#include? (member?) for every item type that has ==, compared with ==.
struct Point
  x: Int
  y: Int
end

enum Shape
  Dot
  Circle(Int)
end

def main() -> Void
  nan = Float.from_bits(9221120237041090560)
  empty: List[Int] = []

  ints = [3, 1, 2]
  puts(ints.include?(1))
  puts(ints.include?(9))
  puts(ints.member?(2))
  puts(empty.include?(1))

  words = ["pear", "fig"]
  puts(words.include?("fig"))
  puts(words.include?("Fig"))
  puts(words.include?(""))

  floats = [0.5, -0.0, nan]
  puts(floats.include?(0.5))
  puts(floats.include?(0.0))
  puts(floats.include?(nan))

  puts([true, true].include?(false))
  puts([true, false].member?(false))

  points = [Point(x: 1, y: 2), Point(x: 3, y: 4)]
  puts(points.include?(Point(x: 3, y: 4)))
  puts(points.include?(Point(x: 3, y: 5)))

  shapes = [Shape.Dot, Shape.Circle(2)]
  puts(shapes.include?(Shape.Circle(2)))
  puts(shapes.member?(Shape.Circle(3)))

  nested = [[1, 2], [3]]
  puts(nested.include?([3]))
  puts(nested.include?([2]))
  puts([{"a": 1}].include?({"a": 1}))
  puts([ok(1), error("x")].include?(error("x")))
  puts([some(1)].include?(none))
  puts([1..3].include?(1..3))
  puts([[nan]].include?([nan]))

  puts(ints.include?(2) and !words.include?("kiwi"))
end
