struct Item
  name: String
end

def main() -> Void
  s = " a b "
  _n: Int = s.length
  _m: Int = s.size
  parts: List[String] = s.strip.split(" ")
  _joined: String = parts.join(",")
  _i: Result[Int] = s.to_i
  _j: Int = "4".to_i!
  _f: Result[Float] = s.to_f
  _b: Bool = s.include?("a") && s.start_with?(" ") && s.end_with?(" ")
  _t: String = s.to_s
  xs = [1]
  xs = xs.push(2)
  _k: Int = xs.length + xs.size
  _ys: List[Int] = xs.map(&identity)
  _text: String = 7.to_s + 2.5.to_s
  _g: Float = 7.to_f
  _h: Result[Int] = 2.5.to_i
  map = {"a": 1}
  _has: Bool = map.has_key?("a")
  _v: Int = map.get("b", 0)
  r: Result[Int] = ok(1)
  _good: Bool = r.ok?
  item = Item(name: "x")
  _up: String = item.name.upcase
end

def identity(n: Int) -> Int
  return n
end

