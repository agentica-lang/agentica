def main() -> Void
  text = IO.read()
  puts("[#{text}]")
  puts(IO.eof?())
end
