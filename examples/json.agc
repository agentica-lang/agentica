struct User
  name: String
  age: Int
end

def greet(text: String) -> Result[String]
  root = try JSON.parse(text)
  member = try JSON.get(root, "name")
  name = try JSON.string(member)
  return ok("hello, " + name)
end

def main() -> Void
  text = JSON.encode(User(age: 25, name: "Ana"))
  puts(text)
  puts(Result.unwrap!(greet(text)))
  puts(Result.unwrap_or(greet("{}"), "missing name"))
end
