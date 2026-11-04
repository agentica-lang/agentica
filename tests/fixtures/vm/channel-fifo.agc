def main() -> Void
  numbers: Channel[Int] = Channel.new(20)
  for i in 1..12
    _ = numbers.send(i * i, 100)
  end
  line = ""
  for _ in 1..6
    case numbers.recv(100)
      ok(n) -> line = "#{line} #{n}"
      error(e) -> puts(e)
    end
  end
  puts(line)
  for i in 13..20
    _ = numbers.send(i * i, 100)
  end
  line = ""
  for _ in 7..20
    case numbers.recv(100)
      ok(n) -> line = "#{line} #{n}"
      error(e) -> puts(e)
    end
  end
  puts(line)
  words: Channel[String] = Channel.new(3)
  _ = words.send("one", 100)
  _ = words.send("two", 100)
  _ = words.send("three", 100)
  puts(words.recv(100).unwrap!)
  _ = words.send("four", 100)
  puts(words.recv(100).unwrap!)
  puts(words.recv(100).unwrap!)
  puts(words.recv(100).unwrap!)
end
