# JSON.encode and JSON.from on a type parameter: each instantiation writes the JSON of the type bound to T, through a
# generic that calls another generic, as the same value written out without generics does.
struct User
  name: String
  tags: List[String]
  age: Optional[Int]
end

struct Box[T]
  value: T
end

def to_json[T](value: T) -> String
  return JSON.encode(value)
end

def boxed[T](value: T) -> Json
  return JSON.from(Box(value: value))
end

def both[T](value: T) -> Void
  puts(to_json(value))
  puts(JSON.encode(boxed(value)))
  puts(to_json(value) == JSON.encode(value))
end

def main() -> Void
  user = User(name: "ada", tags: ["x", "y"], age: none)
  both(user)
  both([1, 2, 3])
  both({"k": some(user)})
end
