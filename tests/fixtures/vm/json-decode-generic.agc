# JSON.decode, JSON.schema and codec of generic struct instances: each instance decodes with the field types of its
# arguments, as a field, a list item or the whole target, and what JSON.encode writes reads back equal.
struct Box[T]
  value: T
end

struct Pair[A, B]
  first: A
  second: B
end

struct Tree[T]
  label: T
  kids: List[Tree[T]]
end

struct Order
  id: Box[Int]
  tags: Box[List[String]]
  pair: Pair[Box[Int], Optional[String]]
  tree: Tree[String]
  note: Box[JSON.Field[String]]
end

def main() -> Void
  order = Order(
    id: Box(value: 7),
    tags: Box(value: ["a", "b"]),
    pair: Pair(first: Box(value: 1), second: none),
    tree: Tree(label: "root", kids: [Tree(label: "leaf", kids: [])]),
    note: Box(value: JSON.Field.Absent),
  )
  text = JSON.encode(order)
  puts(text)
  back = JSON.decode(text, Order)
  puts(back)
  puts(back == ok(order))
  puts(JSON.decode("{\"value\":3}", Box[Int]))
  puts(JSON.decode("{\"value\":null}", Box[JSON.Field[Int]]))
  puts(JSON.decode("[{\"value\":\"x\"},{\"value\":\"y\"}]", List[Box[String]]))
  puts(JSON.decode("{\"value\":\"x\"}", Box[Int]))
  puts(JSON.decode("{\"first\":{\"value\":true},\"second\":\"s\"}", Pair[Box[Int], Optional[String]]))
  puts(JSON.decode("{\"label\":\"r\",\"kids\":[{\"label\":2,\"kids\":[]}]}", Tree[String]))
  puts(JSON.encode(JSON.schema(Order)))
  puts(JSON.encode(JSON.schema(Box[Int])))
  codec = Box[String].codec
  puts(codec.decode("{\"value\":\"c\"}"))
end
