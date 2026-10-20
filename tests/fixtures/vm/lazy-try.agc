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
  return Lazy.produce(1) do |n|
    puts("  produce after #{n}")
    try number(n) + 1
  end.first(5)
end

def main() -> Void
  words = ["1", "2", "x", "4"]
  mapped = words.lazy.map do |s|
    puts("  map #{s}")
    try parse(s)
  end.to_a
  puts("map: #{mapped}")
  puts("all good: #{["1", "2"].lazy.map do |s| try parse(s) * 10 end.to_a}")
  nums = (1..6).lazy
  puts("filter: #{nums.filter do |n| try number(n) > 1 end.to_a}")
  puts("take_while: #{nums.take_while do |n| try number(n) < 5 end.to_a}")
  puts("drop_while: #{nums.drop_while do |n| try number(n) < 5 end.to_a}")
  puts("flat_map: #{nums.flat_map do |n| [n, try number(n)] end.to_a}")
  puts("with_index: #{nums.with_index do |n, i| try number(n + i) end.to_a}")
  puts("chunk_while: #{nums.chunk_while do |a, b| try number(b) > a end.to_a}")
  puts("produce: #{produced()}")
  puts("reduce: #{nums.reduce(0) do |sum, n| sum + try number(n) end}")
  puts("find: #{nums.find do |n| try number(n) > 4 end}")
  each = nums.each do |n|
    puts("  each #{try number(n)}")
    ok()
  end
  puts("each: #{each}")
  puts("after a slice: #{nums.each_slice(2).map do |pair| try number(pair.size + 1) end.first(2)}")
  puts("first stops before the failure: #{nums.map do |n| try number(n) end.first(2)}")
  ch: Channel[Int] = Channel.new(8)
  for n in [1, 2, 3, 4]
    ch.send(n, 1000)
  end
  ch.close
  puts("channel: #{ch.lazy(0).map do |n| try number(n) end.to_a}")
  puts("the value after it is still there: #{ch.lazy(0).to_a}")
end
