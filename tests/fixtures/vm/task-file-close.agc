def one_line(input: FileHandle) -> Bool
  return Result.ok?(File.read_line(input, 60000))
end

def main() -> Void
  path = Result.unwrap!(Path.join([System.args()[0], "close.txt"]))
  Result.unwrap!(File.write_text(path, "a\nb\nc\n", 60000))
  first = Result.unwrap!(File.open(path, "read", 60000))
  late = Task.spawn(&one_line, first)
  IO.inspect(File.close(first, 60000))
  IO.inspect(Task.await(late))
  second = Result.unwrap!(File.open(path, "read", 60000))
  early = Task.spawn(&one_line, second)
  Task.sleep(20)
  IO.inspect(File.close(second, 60000))
  IO.inspect(Task.await(early))
end
