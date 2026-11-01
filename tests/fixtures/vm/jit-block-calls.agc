# Block calls in hot loops: under --jit always (vm-jit-test, vm-gc-stress-jit) compiled code starts each one and calls
# its block natively, a block that makes block calls of its own included, with captured values, a named function as
# the block, and enough allocation (map and filter build lists, sort_by sorts) for the collector to run in the middle
# of a call.
def halve(x: Int) -> Int
  return x / 2
end

def rows(n: Int, shift: Int) -> List[List[Int]]
  return (0...n).to_a.map do |i| (0...4).to_a.map do |j| i * 4 + j + shift end end
end

def main() -> Void
  total = 0
  i = 0
  while i < 3000
    grid = rows(i % 5 + 1, i)
    sums = grid.map do |row| row.filter do |x| x % 2 == 0 end.reduce(0) do |acc, x| acc + x end end
    sorted = sums.sort_by do |s| 0 - s end
    halves = sorted.map(&halve)
    if halves.any? do |h| h > i end
      total += 1
    end
    if halves.all? do |h| h >= 0 end
      total += 2
    end
    (i % 3).times do |k| k + i end
    1.upto(i % 4) do |k| k * i end
    count = (0...(i % 6)).to_a.reduce(0) do |acc, k| acc + k end
    total = (total + halves.first + count + sums.size) % 1000003
    i += 1
  end
  puts(total)
  puts(rows(2, 1))
  puts(rows(3, 0).map do |row| row.sort_by do |x| 0 - x end end)
end
