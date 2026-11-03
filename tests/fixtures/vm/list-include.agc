# List#include? (member?) for Int, Float, String and Bool items, compared with ==.
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

  puts(ints.include?(2) and !words.include?("kiwi"))
end
