struct Reading
  label: String
  value: Float
end

def square(n: Int) -> Int
  return n * n
end

def parse(text: String) -> Result[Int]
  n = try text.to_int
  return ok(n + 1)
end

def twice(n: Int) -> Result[Int]
  return ok(n * 2)
end

def main() -> Void
  scores: Map[String, Int] = {"a": 3, "b": 1}
  scores = scores.put("c", 2)
  keys = scores.keys.sort
  puts("#{keys} #{scores.size}")
  reading = Reading(label: "t", value: 1.5)
  text = JSON.encode(reading)
  decoded = JSON.decode(text, Reading)
  puts(decoded.message)
  json = JSON.from(scores)
  puts(JSON.encode(json))
  puts(JSON.schema(Reading))
  task = Task.spawn(&square, 4)
  puts(Task.await(task))
  Task.cancel(task)
  doubled = Task.map([1, 2], 2, 100) do |n|
    twice_n = try twice(n)
    ok(twice_n + 1)
  end
  puts(doubled)
  named: List[Result[Int]] = Task.map([3], 1, 100, &twice)
  puts(named)
  channel: Channel[Int] = Channel.new(2)
  Channel.send(channel, 1, 100)
  got = Channel.recv(channel, 10)
  puts(got.message)
  channel.close
  puts(channel.closed?)
  puts(IO.inspect(keys.size))
  puts("a".to_s + keys.inspect + 1.to_s)
  puts(Test.ok?(parse("1")))
  puts(Test.error?(parse("x")))
end
