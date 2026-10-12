def echo(word: String) -> String
  p = Result.unwrap!(Process.spawn("cat", [], 5000))
  Result.unwrap!(Process.send(p, "#{word}\n", 5000))
  line = Result.unwrap!(Process.read_line(p, 5000))
  Process.close(p)
  return line
end

def drain(p: Process) -> Int
  total = 0
  reading = true
  while reading
    chunk = Result.unwrap!(Process.read_bytes(p, 65536, 5000))
    total += List.size(chunk)
    reading = List.size(chunk) > 0
  end
  return total
end

def main() -> Void
  a = Task.spawn(&echo, "alpha")
  b = Task.spawn(&echo, "beta")
  p = Result.unwrap!(Process.spawn("cat", [], 5000))
  reader = Task.spawn(&drain, p)
  data = String.join(List.repeat("abcdefgh", 65536), "")
  IO.inspect(Process.send(p, data, 5000))
  IO.inspect(Process.close_stdin(p, 5000))
  IO.inspect(Process.wait(p, 5000))
  puts(Task.await(reader))
  puts(Task.await(a))
  puts(Task.await(b))
end
