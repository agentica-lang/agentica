# List#index for every item type that has ==, compared with ==, and List#find_index with a block.
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

  ints = [3, 1, 2, 1]
  puts(ints.index(1))
  puts(ints.index(3))
  puts(ints.index(9))
  puts(empty.index(1))

  words = ["pear", "fig"]
  puts(words.index("fig"))
  puts(words.index("Fig"))

  floats = [0.5, -0.0, nan]
  puts(floats.index(0.0))
  puts(floats.index(nan))

  puts([true, false].index(false))
  puts([Point(x: 1, y: 2), Point(x: 3, y: 4)].index(Point(x: 3, y: 4)))
  puts([Shape.Dot, Shape.Circle(2)].index(Shape.Circle(2)))
  puts([[1, 2], [3]].index([3]))
  puts([some(1), none].index(none))

  puts(ints.find_index do |n| n < 3 end)
  puts(ints.find_index do |n| n > 3 end)
  puts(empty.find_index do |n| n > 0 end)
  calls = ints.find_index do |n|
    puts("saw #{n}")
    n == 1
  end

  puts(calls.unwrap_or(-1))
  puts(words.find_index do |w| w.length == 3 end.unwrap!)
end
