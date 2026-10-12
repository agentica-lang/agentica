def reader(input: FileHandle) -> Int
  count = 0
  running = true
  while running
    case File.read_line(input, 60000)
      ok(line) -> count = count + 1
      error(message) -> running = message != "filesystem: file handle is closed"
    end
  end
  return count
end

def main() -> Void
  path = Result.unwrap!(Path.join([System.args()[0], "close-reader.txt"]))
  Result.unwrap!(File.write_text(path, "a\nb\n", 60000))
  input = Result.unwrap!(File.open(path, "read", 60000))
  task = Task.spawn(&reader, input)
  Task.sleep(50)
  IO.inspect(File.close(input, 60000))
  IO.inspect(Task.await(task) <= 2)
end
