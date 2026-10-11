def at(dir: String, name: String) -> String
  return Result.unwrap!(Path.join([dir, name]))
end

def main() -> Void
  dir: String = System.args()[0]
  mib = (1..17).to_a.reduce("abcdefgh") do |text, _n|
    text + text
  end
  big = at(dir, "big.txt")
  out = Result.unwrap!(File.open(big, "write", 60000))
  IO.inspect([File.write(out, mib, 60000), File.write(out, mib, 60000), File.write(out, "\nend", 60000), File.write(out, mib + "x", 60000)])
  File.close(out, 60000)
  IO.inspect(File.read_text(big, 60000))
  input = Result.unwrap!(File.open(big, "read", 60000))
  sizes = [1000000, 1000000, 1000000, 1000000].map do |n|
    File.read_bytes(input, n, 60000).unwrap_or([-1]).size
  end
  IO.inspect(sizes)
  File.close(input, 60000)
  input = Result.unwrap!(File.open(big, "read", 60000))
  IO.inspect(File.read_line(input, 60000))
  IO.inspect(File.read_line(input, 60000).unwrap_or("?").length)
  IO.inspect(File.read_line(input, 60000))
  IO.inspect(File.read_line(input, 60000))
  File.close(input, 60000)
  exact = at(dir, "exact.txt")
  IO.inspect([File.write_text(exact, mib + "!", 60000), File.write_text(exact, mib, 60000)])
  IO.inspect(File.read_text(exact, 60000).unwrap_or("?").length)
  IO.inspect(File.append_text(exact, "\n", 60000))
  IO.inspect(File.read_text(exact, 60000))
  input = Result.unwrap!(File.open(exact, "read", 60000))
  IO.inspect(File.read_line(input, 60000).unwrap_or("?").length)
  IO.inspect(File.read_line(input, 60000))
end
