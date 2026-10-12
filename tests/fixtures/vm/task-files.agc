def writer(dir: String) -> Result[Void]
  path = Result.unwrap!(Path.join([dir, "task.txt"]))
  return File.write_text(path, "from a task", 60000)
end

def spin(n: Int) -> Int
  total = 0
  for i in 0...n
    total = total + 1
  end
  return total
end

def main() -> Void
  dir = System.args()[0]
  w = Task.spawn(&writer, dir)
  s = Task.spawn(&spin, 20000)
  IO.inspect(Task.await(w))
  IO.inspect(Task.await(s))
  IO.inspect(File.read_text(Result.unwrap!(Path.join([dir, "task.txt"])), 60000))
end
