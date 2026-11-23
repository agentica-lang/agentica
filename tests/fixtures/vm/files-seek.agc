def main() -> Void
  dir: String = System.args()[0]
  path = Path.join([dir, "seek.txt"]).unwrap!
  out = File.open(path, "write").unwrap!
  IO.inspect(File.write(out, "zero\none\ntwo\n"))
  IO.inspect(File.seek(out, 0))
  IO.inspect(File.close(out))
  input = File.open(path).unwrap!
  IO.inspect(File.read_line(input))
  IO.inspect(File.seek(input, 9))
  IO.inspect(File.read_line(input))
  IO.inspect(File.seek(input, 0))
  IO.inspect(File.read_bytes(input, 4))
  IO.inspect(File.seek(input, 13))
  IO.inspect(File.read_bytes(input, 4))
  IO.inspect(File.seek(input, 1000))
  IO.inspect(File.read_bytes(input, 4))
  IO.inspect(File.read_line(input))
  IO.inspect(File.seek(input, 5))
  IO.inspect(File.read_line(input))
  IO.inspect(File.close(input))
  IO.inspect(File.seek(input, 0))
  IO.inspect(File.seek(input, 0 - 1))
end
