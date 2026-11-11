# Lazy (docs/future/27-iteration-and-concurrency.md 27.4): every source, step and terminal once. The steps run only in
# a terminal, one item at a time, and an endless source ends as soon as take, take_while, first or find has enough.
def double(x: Int) -> Int
  return x * 2
end

def stop_at_four(x: Int) -> Result[Void]
  if x > 3
    return error("stopped at #{x}")
  end
  puts("each #{x}")
  return ok()
end

def main() -> Void
  xs = [1, 2, 3, 4, 5, 6, 7]
  naturals = Lazy.produce(1) do |n| n + 1 end
  puts(xs.lazy.map(&double).to_a)
  puts((1..10).lazy.filter do |x| x % 2 == 0 end.first(3))
  puts((1...4).lazy.to_a)
  puts(naturals.take(5).to_a)
  puts(naturals.each_slice(3).first(2))
  puts(xs.lazy.each_slice(3).to_a)
  puts(xs.lazy.each_cons(3).to_a)
  puts([1, 2, 4, 5, 7].lazy.chunk_while do |a, b| b == a + 1 end.to_a)
  puts(xs.lazy.with_index do |x, i| "#{i}:#{x}" end.to_a)
  puts(xs.lazy.flat_map do |x| [x, x] end.take(5).to_a)
  puts(xs.lazy.drop(2).drop_while do |x| x < 5 end.to_a)
  puts(naturals.take_while do |x| x < 4 end.to_a)
  puts(naturals.take(4).reduce(0) do |acc, x| acc + x end)
  puts(naturals.find do |x| x * x > 50 end)
  puts(xs.lazy.find do |x| x > 50 end)
  puts(naturals.each(&stop_at_four))
  puts(naturals.take(1).flat_map do |x| [x, x, x] end.to_a)
  puts(naturals.take(5).each_slice(2).to_a)
  puts(xs.lazy.take(0).to_a)
  puts(xs.lazy.each_cons(9).to_a)
  # A recipe runs again from its source for each terminal.
  squares = naturals.map do |n| n * n end
  puts(squares.first(3))
  puts(squares.first(4))
  IO.inspect(squares)
end
