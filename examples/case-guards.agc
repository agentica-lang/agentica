enum Shape
  Dot
  Circle(Int)
  Pair(Int, Int)
end

enum Reading
  Value(Int)
  Missing
end

# A guard (`if condition`) is an extra test on an arm; it can use the names of its pattern.
def size(shape: Shape) -> String
  case shape
    Shape.Circle(r) if r > 100 -> return "big circle"
    Shape.Circle(0) -> return "empty circle"
    Shape.Circle(_) -> return "circle"
    Shape.Pair(a, b) if a == b -> return "twin"
    Shape.Pair(_, _) -> return "pair"
    Shape.Dot -> return "dot"
  end
end

# A pattern inside a pattern: a literal, a name, `_` or another variant, also under ok(...) and error(...).
# An arm with such a part does not cover its variant, so `ok(_)` and `error(_)` end the case.
def describe(r: Result[Reading]) -> String
  case r
    ok(Reading.Value(0)) -> return "zero"
    ok(Reading.Value(n)) if n < 0 -> return "negative #{n}"
    ok(Reading.Value(n)) -> return "value #{n}"
    ok(_) -> return "missing"
    error("timeout") -> return "timed out"
    error(_) -> return "failed"
  end
end

def main() -> Void
  puts(size(Shape.Circle(500)))
  puts(size(Shape.Circle(0)))
  puts(size(Shape.Pair(2, 2)))
  puts(size(Shape.Dot))
  puts(describe(ok(Reading.Value(-3))))
  puts(describe(ok(Reading.Value(8))))
  puts(describe(ok(Reading.Missing)))
  puts(describe(error("timeout")))
end
