struct User
  name: String
  age: Int
end

struct Schema
  table: String
  codec: JSON.Codec[User]
end

def body_as[T](body: String, codec: JSON.Codec[T]) -> Result[T]
  return codec.decode(body)
end

def show[T](codec: JSON.Codec[T], value: T) -> String
  return codec.encode(value)
end

def tree[T](codec: JSON.Codec[T], value: T) -> Json
  return codec.from(value)
end

def all_of[T](codec: JSON.Codec[T], bodies: List[String]) -> Result[List[T]]
  found: List[T] = []
  for body in bodies
    found = found.push(try codec.decode(body))
  end

  return ok(found)
end

def codec_said(text: String) -> JSON.Codec[User]
  puts(text)
  return JSON.codec(User)
end

def text_said(text: String) -> String
  puts(text)
  return "{\"name\":\"c\",\"age\":3}"
end

def main() -> Void
  user = body_as("{\"name\":\"a\",\"age\":1}", JSON.codec(User)).unwrap!
  IO.inspect(user)
  puts(show(JSON.codec(User), user))
  json = tree(JSON.codec(User), user)
  puts(JSON.encode(json))
  schema = Schema(table: "users", codec: JSON.codec(User))
  IO.inspect(schema.codec.decode(json))
  IO.inspect(all_of(schema.codec, ["{\"name\":\"b\",\"age\":2}", "{\"name\":\"c\",\"age\":3}"]))
  puts(all_of(schema.codec, ["{\"name\":\"b\",\"age\":2}", "{\"name\":\"b\"}"]).message)
  puts(body_as("{\"name\":1,\"age\":2}", JSON.codec(User)).message)
  puts(body_as("[", JSON.codec(User)).message)
  IO.inspect(codec_said("receiver").decode(text_said("argument")))
end
