## Test driver of tests/test_std_mime.py: reads one JSON case per line of stdin, runs one function of std/mime and
## prints one JSON line with the result.

import MIME from "std/mime"

# `fallback` is used only when `has_fallback` is true, so a case can leave the default in place.
struct Case
  op: String
  text: String
  fallback: String
  has_fallback: Bool
end

# `text` is the type of `mime_type`; `flag` is the answer of `text?`.
struct Reply
  message: String
  text: String
  flag: Bool
end

def run_case(c: Case) -> Reply
  case c.op
    "mime_type" ->
      if c.has_fallback
        return Reply(message: "", text: MIME.mime_type(c.text, c.fallback), flag: false)
      end
      return Reply(message: "", text: MIME.mime_type(c.text), flag: false)
    "text?" -> return Reply(message: "", text: "", flag: MIME.text?(c.text))
    _ -> return Reply(message: "unknown op #{c.op}", text: "", flag: false)
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
      error(message) -> puts(JSON.encode(Reply(message: "bad case: #{message}", text: "", flag: false)))
    end
  end
end
