def main() -> Void
  puts(IO.gets!().inspect)
  rest = IO.read()
  puts(rest.inspect)
  puts(IO.read().inspect)
  puts(IO.read_bytes(4).inspect)
  puts(IO.eof?())
  puts(IO.gets())
end
