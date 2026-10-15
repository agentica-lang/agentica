import Geo from "lib/geometry"

struct Point
  x: Int
end

struct Empty
end

struct Leaf
  name: String
  weight: Float
  on: Bool
end

struct Tree
  label: String
  kids: List[Tree]
  leaves: Map[String, Leaf]
  grid: List[List[Int]]
  spots: Map[String, List[Geo.Point]]
  mine: Point
end

struct A
  b: List[B]
end

struct B
  a: Map[String, A]
  e: Empty
end

def main() -> Void
  puts(JSON.encode(JSON.schema(Point)))
  puts(JSON.encode(JSON.schema(Geo.Point)))
  puts(JSON.encode(JSON.schema(Empty)))
  puts(JSON.schema(Leaf))
  puts(JSON.encode(JSON.schema(Tree)))
  puts(JSON.encode(JSON.schema(A)))
  puts(JSON.encode(JSON.schema(B)))
  IO.inspect(JSON.schema(Point))
  keys = Result.unwrap!(JSON.get(JSON.schema(Tree), "$defs"))
  puts(JSON.encode(Result.unwrap!(JSON.get(keys, "Leaf"))))
end
