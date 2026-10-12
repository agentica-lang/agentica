def reader(n: Int) -> List[String]
  lines: List[String] = []
  running = true
  while running
    case gets()
      ok(line) -> lines = lines.append(line)
      error(message) -> running = false
    end
  end
  return lines
end

def count(n: Int) -> Int
  total = 0
  for i in 0...n
    total = total + 1
  end
  return total
end

def main() -> Void
  r = Task.spawn(&reader, 0)
  c = Task.spawn(&count, 5000)
  IO.inspect(Task.await(c))
  IO.inspect(Task.await(r))
  IO.inspect(IO.eof?())
end
