# File.foreach: the lines of a file through a Lazy. The file opens when a terminal starts and closes before it
# returns, on every path: the end, a step that had enough, an error from the block, a failed try, a read error, and a
# crash or cancel of the task (the task's end closes it). tests/test_vm_lazy_io.py watches the closes in the trace.
def at(dir: String, name: String) -> String
  return Result.unwrap!(Path.join([dir, name]))
end

def put(dir: String, name: String, text: String) -> String
  path = at(dir, name)
  Result.unwrap!(File.write_text(path, text, 60000))
  return path
end

def lines(path: String) -> Lazy[String]
  return File.foreach(path, 1024, 60000)
end

def parse_all(path: String) -> Result[Void]
  return lines(path).map do |line| line.strip end.each do |line|
    n = try String.to_int(line)
    puts("  #{n} + 1 = #{n + 1}")
    ok()
  end
end

def stop_at_two(path: String) -> Result[Void]
  return lines(path).filter do |line| line != "" end.each do |line|
    puts("  saw #{line}")
    if line == "2"
      return error("stopped at #{line}")
    end
    ok()
  end
end

def divide(path: String) -> Result[List[Int]]
  return lines(path).map do |line| 1 / (line.length - line.length) end.to_a
end

def park(path: String, gate: Channel[Int]) -> Result[Void]
  return lines(path).map do |line| line end.each do |line|
    puts("  parked on #{line}")
    gate.recv(60000)
    ok()
  end
end

def main() -> Void
  dir: String = System.args()[0]
  numbers = put(dir, "numbers.txt", "1\n2\n\n3\n")
  words = put(dir, "words.txt", "7\nx\n9\n")
  long = put(dir, "long.txt", String.join(List.repeat("z", 2000), ""))
  bad = at(dir, "bad.bin")
  out = Result.unwrap!(File.open(bad, "write", 60000))
  Result.unwrap!(File.write_bytes(out, [97, 10, 255, 10], 60000))
  Result.unwrap!(File.close(out, 60000))
  recipe = lines(numbers).map do |line| line.length end
  puts("a recipe opens nothing: #{recipe.first(0)}")
  puts("to the end: #{lines(numbers).map do |line| "<#{line}>" end.to_a}")
  puts("twice, read twice: #{recipe.reduce(0) do |sum, n| sum + n end} #{recipe.reduce(0) do |sum, n| sum + n end}")
  puts("first stops early: #{lines(numbers).first(2)}")
  puts("find stops early: #{lines(numbers).find do |line| line == "2" end}")
  puts("slices: #{lines(numbers).each_slice(3).to_a}")
  puts("an error from the block: #{stop_at_two(numbers)}")
  puts("a failed try: #{parse_all(words)}")
  puts("invalid UTF-8: #{lines(bad).map do |line| line end.to_a}")
  puts("a line over the buffer: #{lines(long).map do |line| line end.to_a}")
  puts("a missing file: #{lines(at(dir, "missing.txt")).take(1).to_a}")
  puts("a bad timeout: #{File.foreach(numbers, 1024, 0).take(1).to_a}")
  puts("a crash in a task: #{Task.await(Task.spawn(&divide, numbers)).ok?}")
  gate: Channel[Int] = Channel.new(1)
  cancelled = Task.map([numbers], 1, 50) do |path|
    park(path, gate)
  end
  puts("a cancel while parked: #{cancelled[0]}")
  puts("and the file opens again: #{lines(numbers).first(1)}")
end
