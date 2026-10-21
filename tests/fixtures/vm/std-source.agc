# Std.source reads the std/ sources that the binary carries, by their path in stdlib/.

def first_line(path: String) -> String
  case Std.source(path)
    ok(text) -> return text.split("\n")[0]
    error(_) -> return "error"
  end
end

def size(path: String) -> Result[Int]
  text = try Std.source(path)
  return ok(text.length())
end

def main() -> Void
  puts(first_line("queue.agc"))
  puts(first_line("prelude/list.agc").starts_with?("##"))
  puts(first_line("bdd/gherkin.agc").length() > 0)
  # Only the exact path in stdlib/ names a source.
  for path in ["nope.agc", "queue", "std/queue.agc", "./queue.agc", "/queue.agc", "stdlib/queue.agc", ""]
    puts("#{path}: #{first_line(path)}")
  end
  # Tasks on any scheduler read the same text.
  sizes = Task.map(["http.agc", "http.agc", "http.agc", "http.agc", "toml.agc", "toml.agc"], 6, 10000, &size)
  http = size("http.agc").unwrap_or(0)
  toml = size("toml.agc").unwrap_or(0)
  puts(http > 0 && toml > 0)
  expected = [http, http, http, http, toml, toml]
  same = 0
  for k in 0...sizes.length()
    if sizes[k].unwrap_or(-1) == expected[k]
      same = same + 1
    end
  end
  puts(same)
end
