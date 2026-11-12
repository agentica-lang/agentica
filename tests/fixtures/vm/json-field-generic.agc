# A JSON.Field that comes from a type argument is a direct field after substitution: Box[JSON.Field[Int]] encodes like
# Plain, the same struct with `value: JSON.Field[Int]` written out, whose decode and schema are in json-field.agc
# (JSON.decode and JSON.schema take no generic instance).
struct Box[T]
  value: T
  tag: String
end

struct Plain
  value: JSON.Field[Int]
  tag: String
end

struct Outer[T]
  inner: Box[T]
end

def same(generic: Box[JSON.Field[Int]], plain: Plain) -> Void
  text = JSON.encode(generic)
  puts(text)
  puts(JSON.encode(JSON.from(generic)))
  puts(text == JSON.encode(plain))
end

def main() -> Void
  same(Box(value: JSON.Field.Absent, tag: "a"), Plain(value: JSON.Field.Absent, tag: "a"))
  same(Box(value: JSON.Field.Null, tag: "n"), Plain(value: JSON.Field.Null, tag: "n"))
  same(Box(value: JSON.Field.Value(7), tag: "v"), Plain(value: JSON.Field.Value(7), tag: "v"))
  nest: Box[Box[JSON.Field[Int]]] = Box(value: Box(value: JSON.Field.Absent, tag: "in"), tag: "out")
  puts(JSON.encode(nest))
  outer: Outer[JSON.Field[Int]] = Outer(inner: Box(value: JSON.Field.Null, tag: "o"))
  puts(JSON.encode(outer))
  puts(JSON.encode(JSON.from(outer)))
end
