# The program of tests/test_cli_coverage.py: a branch that never runs, a function that is never called, blocks that
# builtins call (each, times, a range, map), a file it imports (counted) and a std/ module (left out).
import Queue from "std/queue"
import Helper from "helper"

def classify(n: Int) -> String
  if n < 0
    return "negative"
  end

  return Helper.size_of(n)
end

def unused() -> Int
  return 7
end

def main() -> Void
  for n in [1, 20, 300]
    puts(classify(n))
  end

  [1, 2].each do |x|
    y = x * 2
    puts(y)
  end

  3.times do |k|
    m = k * 10
    puts(m)
  end

  (1..3).each do |k|
    m = k + 10
    puts(m)
  end

  doubled = [1, 2, 3, 4].map do |x|
    y = x + 1
    y * 2
  end

  puts(doubled.length)
  puts(Queue.size(Queue.push(Queue.new(), "a")))
end
