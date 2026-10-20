# ch.lazy: the values of a channel until it is closed and drained. A second terminal goes on where the first stopped,
# since a channel cannot be read twice. Each wait for a value obeys the timeout; a timeout ends the terminal with an
# error. A task parked in a terminal on an empty channel can be cancelled (Task.map's timeout here).
struct Feed
  ch: Channel[Int]
  count: Int
end

def produce(feed: Feed) -> Void
  for i in 1..feed.count
    Result.unwrap!(feed.ch.send(i, 60000))
  end
  feed.ch.close
end

def stall(ch: Channel[Int]) -> Void
  Result.unwrap!(ch.send(1, 60000))
  Task.sleep(1000)
  Result.unwrap!(ch.send(2, 60000))
end

def main() -> Void
  numbers: Channel[Int] = Channel.new(2)
  Task.spawn(&produce, Feed(ch: numbers, count: 8))
  values = numbers.lazy(60000)
  puts("first(2): #{values.first(2)}")
  puts("the rest, squared: #{values.map do |n| n * n end.filter do |n| n % 2 == 0 end.to_a}")
  puts("closed and drained: #{values.to_a}")
  five: Channel[Int] = Channel.new(8)
  Task.spawn(&produce, Feed(ch: five, count: 5))
  puts("take_while: #{five.lazy(60000).take_while do |n| n < 3 end.to_a}")
  puts("the value take_while rejected is gone: #{five.lazy(60000).to_a}")
  pairs: Channel[Int] = Channel.new(4)
  Task.spawn(&produce, Feed(ch: pairs, count: 5))
  stopped = pairs.lazy(60000).each_slice(2).each do |pair|
    puts("  pair #{pair}")
    if pair.size < 2
      return error("an odd one out: #{pair}")
    end
    ok()
  end
  puts("an error from the block: #{stopped}")
  slow: Channel[Int] = Channel.new(1)
  Task.spawn(&stall, slow)
  puts("a timeout: #{slow.lazy(20).map do |n| n * 10 end.to_a}")
  empty: Channel[String] = Channel.new(1)
  waits = Task.map([1], 1, 50) do |n|
    empty.lazy(60000).map do |s| s.upcase end.to_a
  end
  puts("a cancel while parked: #{waits[0]}")
  Result.unwrap!(empty.send("after", 60000))
  empty.close
  puts("the channel still works: #{empty.lazy(0).to_a}")
end
