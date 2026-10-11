import "lib/geometry.agc" as Geo

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

def main() -> Void
  text = "{\"label\":\"root\",\"extra\":[1,{\"x\":null}],\"kids\":[{\"label\":\"a\",\"kids\":[],\"leaves\":{},\"grid\":[],\"spots\":{},\"mine\":{\"x\":-1}},{\"label\":\"b\",\"kids\":[{\"label\":\"c\",\"kids\":[],\"leaves\":{\"z\":{\"name\":\"zed\",\"weight\":-0.0,\"on\":false}},\"grid\":[[]],\"spots\":{},\"mine\":{\"x\":0}}],\"leaves\":{},\"grid\":[[1,2],[3]],\"spots\":{\"\":[]},\"mine\":{\"x\":9223372036854775807}}],\"leaves\":{\"b\":{\"name\":\"bee\",\"weight\":2,\"on\":true},\"a\":{\"name\":\"ay\",\"weight\":1.5e3,\"on\":false},\"a\":{\"name\":\"last\",\"weight\":100000000000000000000000,\"on\":true}},\"grid\":[[-9223372036854775808]],\"spots\":{\"home\":[{\"x\":1,\"y\":2,\"z\":3}],\"\\u00e9t\\u00e9\":[]},\"mine\":{\"x\":7}}"
  tree = Result.unwrap!(JSON.decode(text, Tree))
  IO.inspect(tree)
  puts(tree.kids[1].kids[0].leaves["z"].weight)
  puts(tree.leaves.keys)
  puts(tree.spots["home"][0])
  IO.inspect(JSON.decode("{}", Empty))
  IO.inspect(JSON.decode(" {\"x\": 5} ", Point))
  IO.inspect(JSON.decode("{\"x\":1,\"y\":2}", Geo.Point))
  again = Result.unwrap!(JSON.decode(JSON.encode(tree), Tree))
  puts(JSON.encode(again) == JSON.encode(tree))
  puts(JSON.decode("{\"name\":\"n\",\"weight\":1e308,\"on\":true}", Leaf))
end
