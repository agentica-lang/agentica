def main() -> Void
  print("prompt> ")
  IO.flush()
  puts(gets())
  puts(IO.read_bytes(2).inspect)
  puts(IO.eof?())
  IO.warn("before")
  line = IO.gets!()
  puts(line)
end
