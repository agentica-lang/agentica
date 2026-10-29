def at(dir: String, name: String) -> String
  return Result.unwrap!(Path.join([dir, name]))
end

def put(dir: String, name: String, text: String) -> String
  path = at(dir, name)
  Result.unwrap!(File.write_text(path, text, 60000))
  return path
end

def put_bytes(dir: String, name: String, bytes: List[Int]) -> String
  path = at(dir, name)
  out = Result.unwrap!(File.open(path, "write", 60000))
  Result.unwrap!(File.write_bytes(out, Bytes.from_list(bytes).unwrap!, 60000))
  Result.unwrap!(File.close(out, 60000))
  return path
end

def run(ch: String, n: Int) -> String
  return String.join(List.repeat(ch, n), "")
end

def show(line: String) -> Result[Void]
  puts("  #{line.inspect}")
  return ok()
end

def measure(line: String) -> Result[Void]
  puts("  #{line.length}")
  return ok()
end

def dump(label: String, path: String, buffer: Int) -> Void
  puts(label)
  puts("  -> #{File.each_line(path, buffer, 60000, &show)}")
end

def sizes(label: String, path: String) -> Void
  puts(label)
  puts("  -> #{File.each_line(path, 1024, 60000, &measure)}")
end

def main() -> Void
  dir: String = System.args()[0]
  dump("small", put(dir, "small.txt", "alpha\nbeta\ngamma\n"), 1024)
  dump("no final newline", put(dir, "tail.txt", "one\ntwo"), 1024)
  dump("one line without a newline", put(dir, "single.txt", "only"), 1024)
  dump("crlf, a blank line and a lone carriage return", put(dir, "crlf.txt", "a\r\nb\r\n\r\nc\rd\r\n"), 1024)
  dump("blank lines", put(dir, "blank.txt", "\n\n"), 1024)
  dump("empty file", put(dir, "empty.txt", ""), 1024)
  dump("unicode", put(dir, "unicode.txt", "λx\n𝔸\n日本\n"), 1024)
  dump("the largest buffer", put(dir, "big-buffer.txt", "x\ny\n"), 16777216)
  puts("a block with no named function")
  File.each_line(at(dir, "small.txt"), 1024, 60000) do |line|
    puts("  #{line.upcase}")
    ok()
  end
  puts("lines that fill the buffer")
  fits = run("a", 1023) + "\n" + run("b", 1022) + "\r\n" + run("c", 1024)
  sizes("1023 + LF, 1022 + CRLF, 1024 without a newline", put(dir, "fits.txt", fits))
  sizes("1024 + LF is one byte too long", put(dir, "long-lf.txt", "x\n" + run("d", 1024) + "\nnever\n"))
  sizes("1023 + CRLF is one byte too long", put(dir, "long-crlf.txt", run("e", 1023) + "\r\nnever\n"))
  sizes("1025 without a newline", put(dir, "long-tail.txt", run("f", 1025)))
  puts("invalid UTF-8")
  bad = put_bytes(dir, "bad.bin", [111, 107, 10, 97, 255, 10, 110, 101, 118, 101, 114, 10])
  puts("  -> #{File.each_line(bad, 1024, 60000, &show)}")
  puts("open errors")
  dump("missing", at(dir, "missing.txt"), 1024)
  dump("directory", dir, 1024)
  puts("  -> #{File.each_line("", 1024, 60000, &show)}")
  puts("timeout")
  puts("  -> #{File.each_line(at(dir, "small.txt"), 1024, 0, &show)}")
  puts("  -> #{File.each_line(at(dir, "small.txt"), 1024, -5, &show)}")
end
