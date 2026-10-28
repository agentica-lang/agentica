# A JsonField that comes from a type argument is a direct field after substitution: Box[JsonField[Int]] encodes like
# Plain, the same struct with `value: JsonField[Int]` written out, whose decode and schema are in json-field.agc
# (JSON.decode and JSON.schema take no generic instance).
struct Box[T]
  value: T
  tag: String
end

struct Plain
  value: JsonField[Int]
  tag: String
end

struct Outer[T]
  inner: Box[T]
end

def same(generic: Box[JsonField[Int]], plain: Plain) -> Void
  text = JSON.encode(generic)
  puts(text)
  puts(JSON.encode(JSON.from(generic)))
  puts(text == JSON.encode(plain))
end

def main() -> Void
  same(Box(value: JsonField.Absent, tag: "a"), Plain(value: JsonField.Absent, tag: "a"))
  same(Box(value: JsonField.Null, tag: "n"), Plain(value: JsonField.Null, tag: "n"))
  same(Box(value: JsonField.Value(7), tag: "v"), Plain(value: JsonField.Value(7), tag: "v"))
  nest: Box[Box[JsonField[Int]]] = Box(value: Box(value: JsonField.Absent, tag: "in"), tag: "out")
  puts(JSON.encode(nest))
  outer: Outer[JsonField[Int]] = Outer(inner: Box(value: JsonField.Null, tag: "o"))
  puts(JSON.encode(outer))
  puts(JSON.encode(JSON.from(outer)))
end
