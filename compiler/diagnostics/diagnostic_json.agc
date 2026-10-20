## A diagnostic as the JSON object `--json` writes.  The keys are `code`, `message`, `file` and `range` (`start` and
## `end`, each with a `line` and a `column`), then, only when the diagnostic has them, `key_path` (the place in
## agentica.toml or agentica.lock of a problem that has no source span: `range` is then the start of the file; a
## problem about such a file as a whole has no `key_path` and a `range` at line 0, column 0), `expected`, `actual`,
## `callee`, `function` (the signature of the function being checked), `help` and `labels` (a `range` and a `text`
## each). The BDD driver sends it to the runner as the text of a file that did not compile.

import Problems from "../check/check_failure"
import Diag from "diagnostic"
import Source from "../syntax/source"

## The JSON object of the problem.
export def json(problem: Problems.Problem) -> Json
  fields: Map[String, Json] = {
    "code": JSON.from(problem.code),
    "message": JSON.from(problem.message),
    "file": JSON.from(problem.file),
    "range": range(problem.span),
  }
  fields = note(fields, "key_path", problem.key_path)
  fields = note(fields, "expected", problem.expected)
  fields = note(fields, "actual", problem.actual)
  fields = note(fields, "callee", problem.callee)
  fields = note(fields, "function", problem.signature)
  fields = note(fields, "help", help_text(problem.help))
  if problem.labels.size > 0
    labels = problem.labels.map do |label: Problems.Label|
      JSON.object({"range": range(label.span), "text": JSON.from(label.text)})
    end
    fields = fields.put("labels", JSON.array(labels))
  end
  return JSON.object(fields)
end

def help_text(help: Diag.Help) -> String
  case help
    Diag.Help.Hint(text) -> return text
    Diag.Help.NoHelp -> return ""
  end
end

# A note that the diagnostic does not have is the empty text.
def note(fields: Map[String, Json], key: String, text: String) -> Map[String, Json]
  if text == ""
    return fields
  end
  return fields.put(key, JSON.from(text))
end

def range(span: Source.Span) -> Json
  return JSON.object({"start": position(span.start), "end": position(span.stop)})
end

def position(at: Source.Position) -> Json
  return JSON.object({"line": JSON.from(at.line), "column": JSON.from(at.column)})
end
