struct Box
  value: Result[List[Int]]
end


def consume(value: Result[Map[String, Int]]) -> Void
end


def make() -> Result[List[Int]]
  return ok([])
end


def main() -> Void
  _inferred = ok(1)
  _r: Result[Int] = error("bad")
  _r = ok(2)
  _r = error("again")
  _nested: Result[Result[Bool]] = ok(ok(false))
  _box = Box(value: error("bad"))
  consume(ok({}))
  _xs: List[Result[Int]] = [error("bad"), ok(1)]
  _map: Map[String, Result[Int]] = {"k": error("bad")}
  _inferred_list = [ok(1), error("bad")]
  _a: Int = Result.unwrap!(error("bad"))
  _b = Result.unwrap_or(error("bad"), 7)
  _c: List[Int] = Result.unwrap_or(ok([]), [])
end

