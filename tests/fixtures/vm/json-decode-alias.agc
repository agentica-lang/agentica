# JSON.decode, JSON.schema and .codec of fields and payloads whose types are aliases: of a list, of a struct, of a
# JSON.Field, a generic one, inside a List and a generic struct, and a type parameter named like an alias.
type Names = List[String]

type Pairs[T] = Map[String, List[T]]

type Point = Spot

type Maybe = JSON.Field[Int]

struct Spot
  x: Int
end

struct Team
  names: Names
  scores: Pairs[Int]
  home: Point
  spots: List[Point]
  note: Maybe
end

struct Box[T]
  v: Pairs[T]
end

struct Shadow[Names]
  v: Names
end

enum Shape
  Dots(Names)
end

def main() -> Void
  text = "{\"names\":[\"a\"],\"scores\":{\"x\":[1,2]},\"home\":{\"x\":1},\"spots\":[{\"x\":2}],\"note\":5}"
  puts(JSON.decode(text, Team))
  puts(JSON.decode("{\"names\":[1],\"scores\":{},\"home\":{\"x\":1},\"spots\":[]}", Team).ok?)
  puts(JSON.decode("{\"tag\":\"Dots\",\"values\":[[\"p\"]]}", Shape))
  puts(JSON.decode("{\"v\":{\"a\":[1]}}", Box[Int]))
  puts(JSON.decode("{\"v\":3}", Shadow[Int]))
  puts(JSON.schema(Team))
  puts(Team.codec.decode("{\"names\":[],\"scores\":{},\"home\":{\"x\":0},\"spots\":[]}").ok?)
end
