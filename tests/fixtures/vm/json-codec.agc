struct User
  name: String
  age: Int
end

enum Mode
  On
  Off
end

struct Schema
  table: String
  codec: Codec[User]
end

def body_as[T](body: String, codec: Codec[T]) -> Result[T]
  return codec.decode(body)
end

def show[T](codec: Codec[T], value: T) -> String
  return codec.encode(value)
end

def tree[T](codec: Codec[T], value: T) -> JSON.Value
  return codec.from(value)
end

def all_of[T](codec: Codec[T], bodies: List[String]) -> Result[List[T]]
  found: List[T] = []
  for body in bodies
    found = found.push(try codec.decode(body))
  end

  return ok(found)
end

def fields_of[T](codec: Codec[T]) -> List[String]
  return codec.members.map do |member| "#{member.name}: #{member.type}" end
end

def codec_said(text: String) -> Codec[User]
  puts(text)
  return User.codec
end

def text_said(text: String) -> String
  puts(text)
  return "{\"name\":\"c\",\"age\":3}"
end

def main() -> Void
  user = body_as("{\"name\":\"a\",\"age\":1}", User.codec).unwrap!
  IO.inspect(user)
  puts(show(User.codec, user))
  json = tree(User.codec, user)
  puts(JSON.encode(json))
  schema = Schema(table: "users", codec: User.codec)
  IO.inspect(schema.codec.decode(json))
  IO.inspect(all_of(schema.codec, ["{\"name\":\"b\",\"age\":2}", "{\"name\":\"c\",\"age\":3}"]))
  puts(all_of(schema.codec, ["{\"name\":\"b\",\"age\":2}", "{\"name\":\"b\"}"]).message)
  puts(body_as("{\"name\":1,\"age\":2}", User.codec).message)
  puts(body_as("[", User.codec).message)
  IO.inspect(fields_of(User.codec))
  IO.inspect(fields_of(schema.codec) == User.members.map do |member| "#{member.name}: #{member.type}" end)
  IO.inspect(fields_of(Mode.codec))
  IO.inspect(Mode.codec.decode(Mode.codec.encode(Mode.Off)))
  IO.inspect(codec_said("receiver").decode(text_said("argument")))
end
