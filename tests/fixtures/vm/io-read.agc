def main() -> Void
  first = gets!()
  puts("first #{first.inspect}")
  puts("eof? #{IO.eof?()}")
  puts(IO.read_bytes(0).inspect)
  puts(IO.read_bytes(3).inspect)
  puts(IO.read_bytes(-1).inspect)
  puts(IO.read_bytes(1048577).inspect)
  puts(IO.read_bytes(-9223372036854775807 - 1).inspect)
  puts(IO.read_bytes(1048576).inspect)
  puts(IO.gets!())
end
