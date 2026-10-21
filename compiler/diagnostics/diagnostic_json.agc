## A diagnostic as the JSON object `--json` writes.  The keys are `code`, `message`, `file` and `range` (`start` and
## `end`, each with a `line` and a `column`), then, only when the diagnostic has them, `key_path` (the place in
## agentica.toml or agentica.lock of a problem that has no source span: `range` is then the start of the file; a
## problem about such a file as a whole has no `key_path` and a `range` at line 0, column 0), `expected`, `actual`,
## `callee`, `function` (the signature of the function being checked), `help` and `labels` (a `range` and a `text`
## each). The BDD driver sends it to the runner as the text of a file that did not compile.

import Model from "diagnostic_model"
import Problems from "problem"

## The JSON object of the problem.
export def json(problem: Problems.Problem) -> Json
  return object(Model.of_problem(problem))
end

## The JSON object of a diagnostic.
export def object(diagnostic: Model.Diagnostic) -> Json
  fields: Map[String, Json] = {
    "code": JSON.from(diagnostic.code),
    "message": JSON.from(diagnostic.message),
    "file": JSON.from(diagnostic.file),
    "range": range(diagnostic.range),
  }
  fields = note(fields, "key_path", diagnostic.key_path)
  fields = note(fields, "expected", diagnostic.expected)
  fields = note(fields, "actual", diagnostic.actual)
  fields = note(fields, "callee", diagnostic.callee)
  fields = note(fields, "function", diagnostic.function)
  fields = note(fields, "help", diagnostic.help)
  if diagnostic.labels.size > 0
    labels = diagnostic.labels.map do |label: Model.Label|
      JSON.object({"range": range(label.range), "text": JSON.from(label.text)})
    end
    fields = fields.put("labels", JSON.array(labels))
  end
  return JSON.object(fields)
end

## The JSON object of a range: `start` and `end`, each with a `line` and a `column`.
export def range(part: Model.Region) -> Json
  return JSON.object({"start": position(part.start), "end": position(part.stop)})
end

# A note that the diagnostic does not have is the empty text.
def note(fields: Map[String, Json], key: String, text: String) -> Map[String, Json]
  if text == ""
    return fields
  end
  return fields.put(key, JSON.from(text))
end

def position(at: Model.Position) -> Json
  return JSON.object({"line": JSON.from(at.line), "column": JSON.from(at.column)})
end
