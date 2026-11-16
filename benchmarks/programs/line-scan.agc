struct Counter
  calls: Int
  depth: Int
end

def scale() -> Int
  return 1
end

def kind_of(i: Int) -> String
  return "CallExpr" if i % 12 == 2
  "DeclRefExpr"
end

def line_of(i: Int) -> String
  case i % 6
    0 -> "{"
    1 -> "  \"id\": \"0x#{i}\","
    2 -> "  \"kind\": \"#{kind_of(i)}\","
    3 -> "  \"inner\": ["
    4 -> "  ]"
    _ -> "}"
  end
end

# The shape of a scan of clang's JSON AST dump (#1223): builtins against literals once per line, in a compiled loop.
def calls_in(lines: List[String]) -> Int
  n = 0
  for line in lines
    text = line.strip
    if text.start_with?("\"kind\": \"CallExpr\"") or text == "}"
      n += 1
    end
  end
  n
end

# The same file read again line by line into a state record that each line copies.
def step(state: Counter, line: String) -> Counter
  return state.with(depth: state.depth + 1) if line.end_with?("{")
  return state.with(calls: state.calls + 1) if line.strip.start_with?("\"kind\": \"CallExpr\"")
  state
end

def main() -> Void
  count = 300000 * scale()
  directory = System.env("TMPDIR").unwrap_or("/tmp")
  path = Path.join([directory, "agentica-bench-line-scan-#{System.pid}.json"]).unwrap!
  (0...count).to_a.map(&line_of).lazy.write_lines(path).unwrap!
  lines = File.foreach(path).to_a.unwrap!
  found = 0
  for _ in 0...5
    found += calls_in(lines)
  end
  counted = File.foreach(path).reduce(Counter(calls: 0, depth: 0), &step).unwrap!
  Path.remove(path).unwrap!
  puts("line-scan #{lines.size} #{found} #{counted.calls} #{counted.depth}")
end
