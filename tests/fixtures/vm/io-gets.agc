def main() -> Void
  print("name? ")
  running = true
  count = 0
  while running
    case gets()
      ok(line) -> puts("#{count}: #{line.inspect}")
      error(message) ->
        puts(message)
        running = false
    end
    count = count + 1
  end
  puts(IO.gets().inspect)
  puts(IO.eof?())
  puts(IO.read().inspect)
end
