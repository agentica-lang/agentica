# A Bytes.Builder that leaves its block through a channel is closed: a write after the build ended fails.
def main() -> Void
  channel: Channel[Bytes.Builder] = Channel.new(1)
  data = Bytes.build do |out|
    out.write("a")
    _ = channel.send(out, 1000)
  end
  puts(data.length)
  late = channel.recv(1000).unwrap!
  late.write("b")
  puts("not reached")
end
