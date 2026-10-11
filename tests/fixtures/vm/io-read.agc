def main() -> Void
  first = gets!()
  puts("first #{first.inspect}")
  puts("eof? #{IO.eof?()}")
  puts(IO.read_bytes(0))
  puts(IO.read_bytes(3))
  puts(IO.read_bytes(-1))
  puts(IO.read_bytes(1048577))
  puts(IO.read_bytes(-9223372036854775807 - 1))
  puts(IO.read_bytes(1048576))
  puts(IO.gets!())
end
