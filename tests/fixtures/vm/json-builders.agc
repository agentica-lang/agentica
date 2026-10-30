struct Point
  y: Int
  x: Float
  label: String
end

struct Shape
  name: String
  points: List[Point]
  tags: Map[String, Bool]
  extra: Json
  missing: Nil
end

def main() -> Void
  p = Point(y: 2, x: -1.5, label: "a\"b")
  s = Shape(name: "tri", points: [p, Point(y: 0, x: 0.0, label: "é")], tags: {"z": true, "a": false}, extra: JSON.null(), missing: nil)
  puts(JSON.encode(p))
  puts(JSON.from(p))
  puts(JSON.encode(s))
  puts(JSON.from(s))
  puts(JSON.encode([1, 2, 3]))
  puts(JSON.encode({"b": [1.0], "a": [], "\n": [2.5]}))
  puts(JSON.from({"b": [1.0], "a": [], "\n": [2.5]}))
  puts(JSON.encode("tab\there"))
  puts(JSON.encode(nil))
  puts(JSON.encode(true))
  puts(JSON.encode(-42))
  puts(JSON.encode(1000000000000000000000.0))
  empty: Map[String, Json] = {}
  no_items: List[Json] = []
  puts(JSON.object(empty))
  puts(JSON.array(no_items))
  o = JSON.object({"k": JSON.from(1), "j": JSON.array([JSON.from("x"), JSON.null()])})
  puts(o)
  puts(JSON.null?(JSON.null()))
  puts(JSON.null?(o))
  puts(JSON.null?(Result.unwrap!(JSON.get(o, "j")).at(1).unwrap_or(o)))
  puts(JSON.encode(JSON.from(s)) == JSON.from(s).to_s)
end
