def main() -> Void
  xs: List[List[Int]] = List.append([], [])
  ys: List[List[Int]] = List.repeat([], 2)
  zs: List[Int] = List.reverse([])
  rs: List[Result[Int]] = List.repeat(error("bad"), 0)
  a = List.concat([], [1])
  b: List[List[Int]] = List.concat([], [[]])
  c: List[Int] = List.concat([], [])
  d: List[Int] = List.take([], 0)
  e: List[Int] = List.drop([], 2)
  f: Result[Int] = List.at([error("bad")], 0)
  filled = List.append([], 1)
  replaced: List[List[Int]] = List.set(ys, 0, [])
  m: Map[String, List[Int]] = {}
  r: Result[List[Int]] = Map.get(m, "x")
  value: List[Int] = Map.get(m, "x", [])
  inferred = Map.get({}, "x", 1)
  missing: Result[Int] = Map.get({}, "x")
  nested: Result[Int] = Map.get({}, "x", error("bad"))
  deleted: Map[String, Int] = Map.delete({}, "x")
  values: List[List[Int]] = Map.values(m)
end

