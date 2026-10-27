## A struct with a JsonField field in an imported module, for json-field.agc.
export struct Rename
  title: JsonField[String]
end

## What the patch does to the title.
export def title_text(patch: Rename) -> String
  case patch.title
    JsonField.Value(title) -> return "rename to #{title}"
    JsonField.Null -> return "clear the title"
    JsonField.Absent -> return "keep the title"
  end
end
