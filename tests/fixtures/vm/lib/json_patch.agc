## A struct with a JSON.Field field in an imported module, for json-field.agc.
struct Rename
  title: JSON.Field[String]
end

## What the patch does to the title.
def title_text(patch: Rename) -> String
  case patch.title
    JSON.Field.Value(title) -> return "rename to #{title}"
    JSON.Field.Null -> return "clear the title"
    JSON.Field.Absent -> return "keep the title"
  end
end
