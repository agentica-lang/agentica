struct Leaf
  name: String
  weight: Float
  on: Bool
end

struct Box
  count: Int
  leaf: Leaf
  items: List[Leaf]
  tags: Map[String, Int]
  rows: List[List[Int]]
  self: List[Box]
end

def show(text: String) -> Void
  r = JSON.decode(text, Box)
  case r
    ok(b) -> IO.inspect(b)
    error(m) -> puts(m)
  end
end

def main() -> Void
  good = "\"count\":1,\"leaf\":{\"name\":\"n\",\"weight\":1,\"on\":true},\"items\":[],\"tags\":{},\"rows\":[],\"self\":[]"
  show("{" + good + "}")
  show("[1]")
  show("null")
  show("")
  show("{")
  show("{} x")
  show("{\"a\":\"\t\"}")
  show("{\"a\":1e400}")
  show("{}")
  show("{\"count\":1.0}")
  show("{\"count\":9223372036854775808}")
  show("{\"count\":-9223372036854775809}")
  show("{\"count\":\"1\"}")
  show("{\"count\":1,\"leaf\":[]}")
  show("{\"count\":1,\"leaf\":{\"name\":1}}")
  show("{\"count\":1,\"leaf\":{\"name\":\"n\",\"weight\":\"1\"}}")
  show("{\"count\":1,\"leaf\":{\"name\":\"n\",\"weight\":1" + "0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000}}")
  show("{\"count\":1,\"leaf\":{\"name\":\"n\",\"weight\":1,\"on\":0}}")
  show("{\"count\":1,\"leaf\":{\"name\":\"n\",\"weight\":1}}")
  show("{\"count\":1,\"leaf\":{\"name\":\"n\",\"weight\":1,\"on\":true},\"items\":{}}")
  show("{\"count\":1,\"leaf\":{\"name\":\"n\",\"weight\":1,\"on\":true},\"items\":[{\"name\":\"a\",\"weight\":1,\"on\":true},{\"name\":\"b\",\"weight\":1,\"on\":null}]}")
  show("{\"count\":1,\"leaf\":{\"name\":\"n\",\"weight\":1,\"on\":true},\"items\":[],\"tags\":[]}")
  show("{\"count\":1,\"leaf\":{\"name\":\"n\",\"weight\":1,\"on\":true},\"items\":[],\"tags\":{\"ok\":1,\"a\\\"\\n\\u00e9\":true}}")
  show("{\"count\":1,\"leaf\":{\"name\":\"n\",\"weight\":1,\"on\":true},\"items\":[],\"tags\":{},\"rows\":[[1],[2,\"x\"]]}")
  show("{" + good + ",\"self\":[{" + good + "},{\"count\":2}]}")
  show("{" + good + ",\"self\":[{" + good + ",\"self\":[{\"count\":2,\"leaf\":null}]}]}")
end
