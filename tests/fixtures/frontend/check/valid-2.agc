def main() -> Void
  _xs: List[List[Int]] = List.append([], [])
  ys: List[List[Int]] = List.repeat([], 2)
  _zs: List[Int] = List.reverse([])
  _rs: List[Result[Int]] = List.repeat(error("bad"), 0)
  _a = List.concat([], [1])
  _b: List[List[Int]] = List.concat([], [[]])
  _c: List[Int] = List.concat([], [])
  _d: List[Int] = List.take([], 0)
  _e: List[Int] = List.drop([], 2)
  _f: Result[Int] = List.at([error("bad")], 0)
  _filled = List.append([], 1)
  _replaced: List[List[Int]] = List.set(ys, 0, [])
  m: Map[String, List[Int]] = {}
  _r: Optional[List[Int]] = Map.get(m, "x")
  _value: List[Int] = Map.get(m, "x", [])
  _inferred = Map.get({}, "x", 1)
  _missing: Optional[Int] = Map.get({}, "x")
  _nested: Result[Int] = Map.get({}, "x", error("bad"))
  _deleted: Map[String, Int] = Map.delete({}, "x")
  _values: List[List[Int]] = Map.values(m)
end

