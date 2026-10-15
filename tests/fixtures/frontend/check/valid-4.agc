struct Item
  name: String
end

def main() -> Void
  s = " a b "
  n: Int = s.length
  m: Int = s.size
  parts: List[String] = s.strip.split(" ")
  joined: String = parts.join(",")
  i: Result[Int] = s.to_i
  j: Int = "4".to_i!
  f: Result[Float] = s.to_f
  b: Bool = s.include?("a") && s.start_with?(" ") && s.end_with?(" ")
  t: String = s.to_s
  xs = [1]
  xs = xs.push(2)
  k: Int = xs.length + xs.size
  ys: List[Int] = xs.map(&identity)
  text: String = 7.to_s + 2.5.to_s
  g: Float = 7.to_f
  h: Result[Int] = 2.5.to_i
  map = {"a": 1}
  has: Bool = map.has_key?("a")
  v: Int = map.get("b", 0)
  r: Result[Int] = ok(1)
  good: Bool = r.ok?
  item = Item(name: "x")
  up: String = item.name.upcase
end

def identity(n: Int) -> Int
  return n
end

