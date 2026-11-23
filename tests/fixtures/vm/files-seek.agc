def main() -> Void
  dir: String = System.args()[0]
  path = Path.join([dir, "seek.txt"]).unwrap!
  out = File.open(path, "write").unwrap!
  IO.inspect(File.seek(out, 0))
  IO.inspect(File.close(out))
  input = File.open(path).unwrap!
  IO.inspect(File.close(input))
  IO.inspect(File.seek(input, 0))
  input = File.open(path).unwrap!
  IO.inspect(File.seek(input, 0 - 1))
end
