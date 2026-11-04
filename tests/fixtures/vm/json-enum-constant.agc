# JSON of an enum and of a struct named only in constants: the decodable types of the bytecode come from the type
# names of constants too, not only from the functions.
SCHEMA = JSON.schema(Leaf)
LEAF = JSON.decode("{\"tag\":\"L\",\"values\":[4]}", Leaf)
POINT = JSON.decode("{\"x\":1}", Point)

enum Leaf
  L(Int)
  M
end

struct Point
  x: Int
end

def main() -> Void
  puts(SCHEMA)
  puts(LEAF)
  puts(POINT)
end
