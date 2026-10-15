## The `--ai` text form of a diagnostic (`format-diagnostic-ai` of src/diagnostic.rkt): compact, for an agent. The
## plain form is diagnostic_plain.agc and the JSON form diagnostic_json.agc. vm/diag.c prints the same forms for
## runtime errors, so a change here is a change there.
##
## It reads the text of the file the problem is in, to show one line of it. A line is cut at "\n" and loses one
## trailing "\r".

import Problems from "check_failure"
import Diag from "diagnostic"

## The compact form for an agent: `check failed: 1 error`, then the code, one `name: value` line for each part the
## problem has (message, place, function, source line, callee, expected, actual, labels, help).
export def ai(problem: Problems.Problem, text: String) -> String
  start = problem.span.start
  line = trim(source_line(source_lines(text), start.line))
  out = [
    "check failed: 1 error",
    "",
    "[#{problem.code}]",
    "  message: #{problem.message}",
    "  at: #{problem.file}:#{start.line}:#{start.column}",
  ]
  out = field(out, "in", problem.signature)
  out = out.push("  source: #{line}")
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

def source_lines(text: String) -> List[String]
  return text.split("\n")
end

# The line (from 1), or "" outside the text, without one trailing "\r".
def source_line(lines: List[String], number: Int) -> String
  if number < 1 or number > lines.size
    return ""
  end
  line = lines[number - 1]
  if line.ends_with?("\r")
    return line.slice(0, line.length - 1)
  end
  return line
end

# Without the whitespace around it (space, tab, line feed, vertical tab, form feed and carriage return), as Racket's
# string-trim does.
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
