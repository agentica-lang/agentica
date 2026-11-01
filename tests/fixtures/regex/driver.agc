## Test driver of tests/test_std_regex.py: reads one JSON case per line of stdin, runs one function of std/regex and
## prints one JSON line with the result.

import Regex from "std/regex"

# `text` is the subject (or the input of `escape`); `template` is used by `replace` only.
struct Case
  op: String
  pattern: String
  text: String
  template: String
end

# `message` is empty on success. `spans` holds one list per match: the start and stop of each group, groups[0] first.
# `text` is the result of `replace` and `escape`, `parts` the result of `split`, `found` the result of `match?`.
struct Reply
  success: Bool
  message: String
  spans: List[List[Int]]
  text: String
  parts: List[String]
  found: Bool
end

def spans_of(m: Regex.Match) -> List[Int]
  return m.groups.flat_map do |g| [g.start, g.stop] end
end

def failure(message: String) -> Reply
  return Reply(success: false, message: message, spans: [], text: "", parts: [], found: false)
end

def run_case(c: Case) -> Reply
  if c.op == "escape"
    return Reply(success: true, message: "", spans: [], text: Regex.escape(c.text), parts: [], found: false)
  end
  case Regex.compile(c.pattern)
    error(message) -> return failure(message)
    ok(re) -> return run_with(c, re)
  end
end

def run_with(c: Case, re: Regex.Regex) -> Reply
  done = Reply(success: true, message: "", spans: [], text: "", parts: [], found: false)
  case c.op
    "compile" -> return done
    "match?" -> return done.with(found: Regex.match?(c.text, re))
    "match" ->
      case Regex.match(c.text, re)
        ok(m) -> return done.with(spans: [spans_of(m)], text: m.text)
        error(message) -> return failure(message)
      end
    "find_all" -> return done.with(spans: Regex.find_all(c.text, re).map(&spans_of))
    "split" -> return done.with(parts: Regex.split(c.text, re))
    "replace" ->
      case Regex.replace(c.text, re, c.template)
        ok(text) -> return done.with(text: text)
        error(message) -> return failure(message)
      end
    _ -> return failure("unknown op #{c.op}")
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
      error(message) -> puts(JSON.encode(failure("bad case: #{message}")))
    end
  end
end
