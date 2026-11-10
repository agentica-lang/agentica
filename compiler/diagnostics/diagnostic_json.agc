## A diagnostic as the JSON object `--json` writes.  The keys are `code`, `message`, `file` and `range` (`start` and
## `end`, each with a `line` and a `column`), then, only when the diagnostic has them, `key_path` (the place in
## agentica.toml or agentica.lock of a problem that has no source span: `range` is then the start of the file; a
## problem about such a file as a whole has no `key_path` and a `range` at line 0, column 0), `expected`, `actual`,
## `callee`, `function` (the signature of the function being checked), `help` and `labels` (a `range` and a `text`
## each). The BDD driver sends it to the runner as the text of a file that did not compile.

import Model from "diagnostic_model"
import Problems from "problem"

## The JSON object of the problem.
export def json(problem: Problems.Problem) -> Json = object(Model.of_problem(problem))

## The JSON object of a warning: the object of the problem with `"warning": true`. A warning is not an error: the
## command goes on (a native module that was not built, io/native_build.agc).
export def warning(problem: Problems.Problem) -> Json
  return JSON.object(fields_of(Model.of_problem(problem)).put("warning", JSON.from(true)))
end

## The JSON object of a diagnostic.
export def object(diagnostic: Model.Diagnostic) -> Json = JSON.object(fields_of(diagnostic))

## The JSON object of a range: `start` and `end`, each with a `line` and a `column`.
export def range(part: Model.Region) -> Json = JSON.object({"start": position(part.start), "end": position(part.stop)})

## The `shape` of an answer from a program that does not check (docs/future/39-semantic-cli.md, 39.6): `partial` is
## true and `diagnostics` holds its problems. A complete answer leaves both keys out.
export def partial(shape: Map[String, Json], diagnostics: List[Model.Diagnostic]) -> Map[String, Json]
  return (
    shape.put("partial", JSON.from(true))
      .put("diagnostics", JSON.array(diagnostics.map do |found: Model.Diagnostic| object(found) end))
  )
end

# The fields of the object of a diagnostic.
def fields_of(diagnostic: Model.Diagnostic) -> Map[String, Json]
  fields: Map[String, Json] = {
    "code": JSON.from(diagnostic.code),
    "message": JSON.from(diagnostic.message),
    "file": JSON.from(diagnostic.file),
    "range": range(diagnostic.range),
  }

  fields = (
    fields
    |> note("key_path", diagnostic.key_path)
    |> note("expected", diagnostic.expected)
    |> note("actual", diagnostic.actual)
    |> note("callee", diagnostic.callee)
    |> note("function", diagnostic.function)
    |> note("help", diagnostic.help)
  )

  if diagnostic.labels.size > 0
    labels = diagnostic.labels.map do |label: Model.Label|
      JSON.object({"range": range(label.range), "text": JSON.from(label.text)})
    end

    fields = fields.put("labels", JSON.array(labels))
  end

  return fields
end

# A note that the diagnostic does not have is the empty text.
def note(fields: Map[String, Json], key: String, text: String) -> Map[String, Json]
  return fields if text == ""

  return fields.put(key, JSON.from(text))
end

def position(at: Model.Position) -> Json = JSON.object({"line": JSON.from(at.line), "column": JSON.from(at.column)})
