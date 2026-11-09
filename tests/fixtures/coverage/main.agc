# The program of tests/test_cli_coverage.py: a branch that never runs, a function that is never called, a block, a
# file it imports (counted) and a std/ module (left out).
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

  puts(Queue.size(Queue.push(Queue.new(), "a")))
end
