# A terminal on a channel that a task feeds forever never ends: --max-steps stops the run, parked or not.
def feed(ch: Channel[Int]) -> Void
  i = 0
  while true
    Result.unwrap!(ch.send(i, 60000))
    i += 1
  end
end

def main() -> Void
  ch: Channel[Int] = Channel.new(4)
  Task.spawn(&feed, ch)
  puts(ch.lazy(60000).map do |n| n + 1 end.to_a)
end
