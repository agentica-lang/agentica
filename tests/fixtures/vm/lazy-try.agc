# A failed try in any block of a Lazy method ends the pipeline: the terminal returns its error, no later item is
# pulled, and a try that succeeds gives its value. The puts in the blocks show which items ran.
def parse(text: String) -> Result[Int]
  return text.to_i
end

def number(n: Int) -> Result[Int]
  if n == 3
    return error("no #{n}")
  end
  return ok(n)
end

def produced() -> Result[List[Int]]
  numbers = Lazy.produce(1) do |n|
    puts("  produce after #{n}")
    try number(n) + 1
  end
  return numbers.first(5)
end

def main() -> Void
  words = ["1", "2", "x", "4"]
  parsed = words.lazy.map do |s|
    puts("  map #{s}")
    try parse(s)
  end
  mapped = parsed.to_a
  puts("map: #{mapped}")
  puts("all good: #{["1", "2"].lazy.map { |s| try parse(s) * 10 }.to_a}")
  nums = (1..6).lazy
  puts("filter: #{nums.filter { |n| try number(n) > 1 }.to_a}")
  puts("take_while: #{nums.take_while { |n| try number(n) < 5 }.to_a}")
  puts("drop_while: #{nums.drop_while { |n| try number(n) < 5 }.to_a}")
  puts("flat_map: #{nums.flat_map { |n| [n, try number(n)] }.to_a}")
  puts("with_index: #{nums.with_index { |n, i| try number(n + i) }.to_a}")
  puts("chunk_while: #{nums.chunk_while { |a, b| try number(b) > a }.to_a}")
  puts("produce: #{produced()}")
  puts("reduce: #{nums.reduce(0) do |sum, n| sum + try number(n) end}")
  puts("find: #{nums.find do |n| try number(n) > 4 end}")
  each = nums.each do |n|
    puts("  each #{try number(n)}")
    ok()
  end
  puts("each: #{each}")
  puts("after a slice: #{nums.each_slice(2).map { |pair| try number(pair.size + 1) }.first(2)}")
  puts("first stops before the failure: #{nums.map { |n| try number(n) }.first(2)}")
  ch: Channel[Int] = Channel.new(8)
  for n in [1, 2, 3, 4]
    _ = ch.send(n, 1000)
  end
  ch.close
  puts("channel: #{ch.lazy(0).map { |n| try number(n) }.to_a}")
  puts("the value after it is still there: #{ch.lazy(0).to_a}")
end
