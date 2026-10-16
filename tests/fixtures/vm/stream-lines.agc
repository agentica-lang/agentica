def identity(line: String) -> String
  return line
end

def main() -> Void
  dir = System.args()[0]
  path = Result.unwrap!(Path.join([dir, "lines.txt"]))
  Result.unwrap!(File.write_text(path, "one\ntwo\nthree\n", 5000))
  stream = Stream.lines(path, 1024, 5000).map(&identity).take(2)
  puts(stream.to_list(2))
  puts(stream.each do |line|
    puts(line)
    ok()
  end)
  Result.unwrap!(Path.remove(dir, 5000))
end
