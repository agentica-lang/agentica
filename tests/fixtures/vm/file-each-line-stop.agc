def at(dir: String, name: String) -> String
  return Result.unwrap!(Path.join([dir, name]))
end

def put(dir: String, name: String, text: String) -> String
  path = at(dir, name)
  Result.unwrap!(File.write_text(path, text, 60000))
  return path
end

def put_bytes(dir: String, name: String, bytes: List[Int]) -> String
  path = at(dir, name)
  out = Result.unwrap!(File.open(path, "write", 60000))
  Result.unwrap!(File.write_bytes(out, bytes, 60000))
  Result.unwrap!(File.close(out, 60000))
  return path
end

def open_files() -> Int
  return Result.unwrap!(Dir.list("/proc/self/fd", 60000)).length
end

def double(n: Int) -> Int
  return n * 2
end

def stop_at_two(path: String) -> Result[Void]
  return File.each_line(path, 1024, 60000) do |line|
    puts("  saw #{line}")
    if line == "2"
      return error("stopped at #{line}")
    end
    ok()
  end
end

def parse_each(path: String) -> Result[Void]
  return File.each_line(path, 1024, 60000) do |line|
    n = try String.to_int(line)
    puts("  #{n} + 1 = #{n + 1}")
    ok()
  end
end

def read_other(path: String, other: String) -> Result[Void]
  return File.each_line(path, 1024, 60000) do |line|
    puts("  outer #{line}")
    inner = File.each_line(other, 1024, 60000) do |text|
      puts("    inner #{text}")
      ok()
    end
    try inner
    ok()
  end
end

def wait_each(path: String) -> Result[Void]
  return File.each_line(path, 1024, 60000) do |line|
    n = try String.to_int(line)
    Task.sleep(1)
    puts("  #{n} doubled by a task: #{Task.await(Task.spawn(&double, n))}")
    ok()
  end
end

def report(label: String, before: Int, result: Result[Void]) -> Void
  puts("#{label}: #{result}, descriptors #{open_files() - before}")
end

def main() -> Void
  dir: String = System.args()[0]
  numbers = put(dir, "numbers.txt", "1\n2\n3\n")
  words = put(dir, "words.txt", "7\nx\n9\n")
  letters = put(dir, "letters.txt", "a\nb\n")
  before = open_files()
  report("an error from the block stops the call", before, stop_at_two(numbers))
  report("try returns the error of String.to_int", before, parse_each(words))
  report("try with all lines numeric", before, parse_each(numbers))
  report("a call inside the block", before, read_other(letters, numbers))
  report("a block that waits on other tasks", before, wait_each(numbers))
  report("invalid UTF-8 ends the call", before, File.each_line(put_bytes(dir, "bad.bin", [97, 10, 255, 10]), 1024, 60000) do |line|
    puts("  saw #{line}")
    ok()
  end)
  long = String.join(List.repeat("z", 2000), "")
  report("a line over the buffer ends the call", before, File.each_line(put(dir, "long.txt", long), 1024, 60000) do |line|
    ok()
  end)
  report("a missing file", before, File.each_line(at(dir, "missing.txt"), 1024, 60000) do |line|
    ok()
  end)
  early = Task.spawn(&stop_at_two, numbers)
  report("the same call in a task", before, Task.await(early))
end
