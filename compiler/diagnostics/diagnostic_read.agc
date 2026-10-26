## Reads a diagnostic back from the JSON object that diagnostic_json.agc writes, so the message of an error of
## `std/analysis` (which is that object) becomes data again. A key the writer leaves out, because the diagnostic has no
## such note, is the empty text.

import Model from "diagnostic_model"

## The diagnostic that the JSON text `text` holds, or why it is not one.
export def read(text: String) -> Result[Model.Diagnostic]
  root = try JSON.parse(text)
  labels: List[Model.Label] = []
  if has?(root, "labels")
    items = try JSON.list(try JSON.get(root, "labels"))
    for item in items
      labels = labels.push(Model.Label(range: try range_of(item), text: try string(item, "text")))
    end
  end

  return ok(
    Model.Diagnostic(
      code: try string(root, "code"),
      message: try string(root, "message"),
      file: try string(root, "file"),
      range: try range_of(root),
      key_path: try note(root, "key_path"),
      help: try note(root, "help"),
      expected: try note(root, "expected"),
      actual: try note(root, "actual"),
      callee: try note(root, "callee"),
      function: try note(root, "function"),
      labels: labels,
    ),
  )
end

def has?(object: Json, key: String) -> Bool
  return JSON.get(object, key).ok?
end

def string(object: Json, key: String) -> Result[String]
  return JSON.string(try JSON.get(object, key))
end

# A note the diagnostic does not have is left out of the object.
def note(object: Json, key: String) -> Result[String]
  if !has?(object, key)
    return ok("")
  end

  return string(object, key)
end

def range_of(object: Json) -> Result[Model.Region]
  range = try JSON.get(object, "range")
  return ok(Model.Region(start: try position(range, "start"), stop: try position(range, "end")))
end

def position(object: Json, key: String) -> Result[Model.Position]
  at = try JSON.get(object, key)
  line = try JSON.int(try JSON.get(at, "line"))
  column = try JSON.int(try JSON.get(at, "column"))
  return ok(Model.Position(line: line, column: column))
end
