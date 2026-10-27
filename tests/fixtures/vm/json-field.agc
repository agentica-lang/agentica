import Patch from "lib/json_patch"

struct UpdateUser
  name: JsonField[String]
  age: JsonField[Int]
end

def describe_age(age: JsonField[Int]) -> String
  text = ""
  case age
    JsonField.Absent -> text = "age: keep"
    JsonField.Null -> text = "age: clear"
    JsonField.Value(n) -> text = "age: set to #{n}"
  end
  return text
end

def show(text: String) -> Result[Void]
  update = try JSON.decode(text, UpdateUser)
  puts(describe_age(update.age))
  name = ""
  case update.name
    JsonField.Value(n) -> name = "set to #{n}"
    _ -> name = "keep"          # this API treats null like absent
  end
  puts("name: #{name}")
  puts(JSON.encode(update))
  return ok()
end

def main() -> Void
  for text in ["{}", "{\"age\": null}", "{\"name\": \"Ana\", \"age\": 30}"]
    Result.unwrap!(show(text))
  end
  reply = UpdateUser(name: JsonField.Value("Bo"), age: JsonField.Null)
  puts(JSON.encode(reply))
  puts(JSON.encode(JSON.from(reply)))
  puts(JSON.encode(JSON.from(UpdateUser(name: JsonField.Absent, age: JsonField.Absent))))
  puts(reply)
  puts(JSON.encode(JSON.schema(UpdateUser)))
  for text in ["{}", "{\"title\": null}", "{\"title\": \"Notes\"}"]
    patch = Result.unwrap!(JSON.decode(Result.unwrap!(JSON.parse(text)), Patch.Rename))
    puts("#{Patch.title_text(patch)} #{JSON.encode(patch)}")
  end
  puts(JSON.encode(JSON.schema(Patch.Rename)))
end
