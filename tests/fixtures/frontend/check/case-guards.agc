enum Option
  Some(Int)
  None
end

enum Shape
  Circle(Int)
  Pair(Int, Option)
end

def describe(shape: Shape, r: Result[Option]) -> String
  case shape
    Shape.Circle(0) -> return "empty"
    Shape.Circle(n) if n > 100 -> return "big"
    Shape.Circle(_) -> return "circle"
    Shape.Pair(1, Option.Some(n)) if n > 5 -> return "pair #{n}"
    Shape.Pair(_, _) -> return "pair"
  end
end

def results(r: Result[Option]) -> Int
  case r
    ok(Option.Some(n)) -> return n
    ok(_) -> return 0
    error("boom") -> return -1
    error(_) if true -> return -2
    error(_) -> return -3
  end
end

def main() -> Void
  puts(describe(Shape.Circle(1), Result.Ok(Option.None)))
  puts(results(Result.Ok(Option.Some(2))))
end
