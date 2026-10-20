## The `--ai` text form of a diagnostic (compact, for an agent). The plain form is diagnostic_plain.agc and the JSON
## form diagnostic_json.agc. vm/diag.c prints the same forms for runtime errors, so a change here is a change there.
##
## It reads the text of the file the problem is in, to show one line of it. A line is cut at "\n" and loses one
## trailing "\r".

import Problems from "../check/check_failure"
import Diag from "diagnostic"
import Plain from "diagnostic_plain"

## The compact form for an agent: `check failed: 1 error`, then the code, one `name: value` line for each part the
## problem has (message, place, function, source line, callee, expected, actual, labels, help). A problem at a key of a
## manifest or a lock has `key` in place of the line and column and the source line, and a problem about the whole file
## has the file name alone.
export def ai(problem: Problems.Problem, text: String) -> String
  start = problem.span.start
  line = trim(Plain.line_text(text.split("\n"), start.line))
  out = ["check failed: 1 error", "", "[#{problem.code}]", "  message: #{problem.message}"]
  if Problems.at_source?(problem)
    out = out.push("  at: #{problem.file}:#{start.line}:#{start.column}")
    out = field(out, "in", problem.signature)
    out = out.push("  source: #{line}")
  else
    out = out.push("  at: #{problem.file}")
    out = field(out, "key", problem.key_path)
  end
  out = field(out, "callee", problem.callee)
  out = field(out, "expected", problem.expected)
  out = field(out, "actual", problem.actual)
  for label in problem.labels
    out = out.push("  label: #{label.span.start.line}:#{label.span.start.column} #{label.text}")
  end
  out = field(out, "help", hint_text(problem.help))
  return out.join("\n")
end

def hint_text(help: Diag.Help) -> String
  case help
    Diag.Help.Hint(text) -> return text
    Diag.Help.NoHelp -> return ""
  end
end

def field(out: List[String], name: String, value: String) -> List[String]
  if value == ""
    return out
  end
  return out.push("  #{name}: #{value}")
end

# Without the whitespace around it (space, tab, line feed, vertical tab, form feed and carriage return).
def trim(text: String) -> String
  characters = text.split("")
  first = 0
  last = characters.size
  while first < last and space?(characters[first])
    first += 1
  end
  while last > first and space?(characters[last - 1])
    last -= 1
  end
  return text.slice(first, last - first)
end

def space?(character: String) -> Bool
  code = String.code(character)
  return code == 32 or (code >= 9 and code <= 13)
end
