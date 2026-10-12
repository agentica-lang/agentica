def read_all(input: FileHandle) -> List[Int]
  got: List[Int] = []
  running = true
  while running
    case File.read_line(input, 60000)
      ok(line) -> got = got.append(Result.unwrap!(line.to_int))
      error(message) -> running = false
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
  a = Task.spawn(&read_all, input)
  b = Task.spawn(&read_all, input)
  both = Task.await(a).concat(Task.await(b)).sort
  IO.inspect(both.size)
  IO.inspect(both.at(0))
  IO.inspect(both.at(59))
  IO.inspect(both.reduce(0) do |acc, x|
    acc + x
  end)
  IO.inspect(File.close(input, 60000))
end
