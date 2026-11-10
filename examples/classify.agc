def classify(age: Int) -> String
  if age >= 18
    "adult"
  elsif age >= 13
    "teen"
  else
    "child"
  end
end

def classify_text(text: String) -> Result[String]
  age = try String.to_int(text)
  ok(classify(age))
end

def main() -> Void
  puts(Result.unwrap!(classify_text("25")))
end
