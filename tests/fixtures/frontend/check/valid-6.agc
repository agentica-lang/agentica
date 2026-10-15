struct Box
  value: Result[List[Int]]
end


def consume(value: Result[Map[String, Int]]) -> Void
end


def make() -> Result[List[Int]]
  return ok([])
end


def main() -> Void
  inferred = ok(1)
  r: Result[Int] = error("bad")
  r = ok(2)
  r = error("again")
  nested: Result[Result[Bool]] = ok(ok(false))
  box = Box(value: error("bad"))
  consume(ok({}))
  xs: List[Result[Int]] = [error("bad"), ok(1)]
  map: Map[String, Result[Int]] = {"k": error("bad")}
  inferred_list = [ok(1), error("bad")]
  a: Int = Result.unwrap!(error("bad"))
  b = Result.unwrap_or(error("bad"), 7)
  c: List[Int] = Result.unwrap_or(ok([]), [])
end

