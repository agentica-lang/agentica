def divide(path: String) -> Result[Void]
  return File.each_line(path, 1024, 60000) do |line|
    puts("dividing #{line}")
    zero = line.length - line.length
    puts("#{1 / zero}")
    ok()
  end
end

def main() -> Void
  path = Result.unwrap!(Path.join([System.args()[0], "lines.txt"]))
  Result.unwrap!(File.write_text(path, "first\nsecond\n", 60000))
  puts(Task.await(Task.spawn(&divide, path)))
  puts(divide(path))
  puts("never printed")
end
