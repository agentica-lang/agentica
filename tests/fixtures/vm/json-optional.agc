# Optional in typed JSON: none is null and some(x) is x, anywhere a type is; decode reads null or a missing key as
# none. What decode returns encodes back to the same text. some(none) has no JSON form of its own: it is null, so it
# decodes as none. A field default of none fills a field the constructor leaves out.
struct Address
  city: String
  zip: Optional[String] = none
end

struct User
  name: String
  age: Optional[Int]
  home: Optional[Address]
  tags: List[Optional[String]]
  limits: Map[String, Optional[Float]]
  deep: Optional[Optional[Int]]
end

def show(text: String) -> Void
  case JSON.decode(text, User)
    ok(user) ->
      again = JSON.encode(user)
      puts("#{user}")
      puts("#{again} #{JSON.encode(JSON.decode(again, User).unwrap!) == again}")
    error(message) -> puts("error #{message}")
  end
end

def main() -> Void
  user = User(
    name: "ann",
    age: some(30),
    home: some(Address(city: "Bcn")),
    tags: [some("a"), none],
    limits: {"cpu": some(1.5), "mem": none},
    deep: some(some(7)),
  )
  text = JSON.encode(user)
  puts(text)
  show(text)
  show("{\"name\":\"bo\",\"tags\":[],\"limits\":{}}")
  show("{\"name\":\"bo\",\"age\":null,\"home\":{\"city\":\"x\",\"zip\":\"1\"},\"tags\":[null],\"limits\":{},\"deep\":null}")
  show("{\"name\":\"bo\",\"age\":\"30\",\"tags\":[],\"limits\":{}}")
  show("{\"name\":\"bo\",\"tags\":[3],\"limits\":{}}")
  lost = user.with(deep: some(none))
  puts(JSON.encode(lost))
  puts(JSON.decode(JSON.encode(lost), User).unwrap!.deep)
  present: Optional[Int] = some(4)
  missing: Optional[Int] = none
  puts("#{JSON.encode(present)} #{JSON.encode(missing)} #{JSON.encode([present, missing])}")
  puts(JSON.from(missing).null?)
  puts(JSON.schema(Address))
  codec = JSON.codec(Address)
  puts(codec.decode("{\"city\":\"y\"}"))
end
