# Two tasks read one shared file handle: each line goes to exactly one of them. Each task reads its first line, then
# waits until both have one, so both get lines whatever the interleaving (a line already in the buffer is read
# without an I/O job, so one task could otherwise read all 60 first).
def read_all(input: FileHandle, ready: Channel[Int], go: Channel[Int]) -> List[Int]
  got: List[Int] = []
  running = true
  first = true
  while running
    case File.read_line(input, 60000)
      ok(line) -> got = got.append(Result.unwrap!(line.to_int))
      error(_) -> running = false
    end
    if first
      first = false
      Result.unwrap!(ready.send(1, 60000))
      Result.unwrap!(go.recv(60000))
    end
  end
  return got
end

def main() -> Void
  path = Result.unwrap!(Path.join([System.args()[0], "lines.txt"]))
  text = (1..60).to_a.map do |i|
    i.to_s
  end
  Result.unwrap!(File.write_text(path, String.join(text, "\n"), 60000))
  input = Result.unwrap!(File.open(path, "read", 60000))
  ready: Channel[Int] = Channel.new(2)
  go: Channel[Int] = Channel.new(2)
  a = Task.spawn do
    read_all(input, ready, go)
  end
  b = Task.spawn do
    read_all(input, ready, go)
  end
  Result.unwrap!(ready.recv(60000))
  Result.unwrap!(ready.recv(60000))
  Result.unwrap!(go.send(1, 60000))
  Result.unwrap!(go.send(1, 60000))
  ra = Task.await(a)
  rb = Task.await(b)
  IO.inspect(ra.size > 0 and rb.size > 0)
  both = ra.concat(rb).sort
  IO.inspect(both.size)
  IO.inspect(both.at(0))
  IO.inspect(both.at(59))
  IO.inspect(both.reduce(0) do |acc, x|
    acc + x
  end)
  IO.inspect(File.close(input, 60000))
end
