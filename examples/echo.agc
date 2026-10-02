def main() -> Nil
  while not IO.eof?()
    puts(IO.gets!())
  end
end
