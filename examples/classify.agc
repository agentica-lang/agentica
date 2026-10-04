def classify(age: Int) -> String
  if age >= 18
    return "adult"
  elsif age >= 13
    return "teen"
  else
    return "child"
  end
end

def classify_text(text: String) -> Result[String]
  age = try String.to_int(text)
  return ok(classify(age))
end

def main() -> Void
  puts(Result.unwrap!(classify_text("25")))
end
