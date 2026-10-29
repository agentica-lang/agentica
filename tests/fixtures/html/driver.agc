## Test driver of tests/test_std_html.py: reads one JSON case per line of stdin, runs one function of std/html and
## prints the result as one JSON string per line.

import HTML from "std/html"

struct Case
  op: String
  text: String
end

def run_case(c: Case) -> String
  case c.op
    "escape" -> return HTML.escape(c.text)
    "unescape" -> return HTML.unescape(c.text)
    _ -> return "unknown op #{c.op}"
  end
end

def main() -> Void
  while true
    line = IO.gets()
    if !line.ok?
      return
    end
    case JSON.decode(line.unwrap!, Case)
      ok(c) -> puts(JSON.encode(run_case(c)))
      error(message) -> puts(JSON.encode("bad case: #{message}"))
    end
  end
end
