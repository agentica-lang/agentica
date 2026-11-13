## A struct with a JSON.Field field in an imported module, for json-field.agc.
export struct Rename
  title: JSON.Field[String]
end

## What the patch does to the title.
export def title_text(patch: Rename) -> String
  case patch.title
    JSON.Field.Value(title) -> return "rename to #{title}"
    JSON.Field.Null -> return "clear the title"
    JSON.Field.Absent -> return "keep the title"
  end
end
