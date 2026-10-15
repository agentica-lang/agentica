enum Shape
  Dot
  Circle(Float)
  Rect(Float, Float)
end

def area(shape: Shape) -> Float
  case shape
    Shape.Dot -> return 0.0
    Shape.Circle(r) -> return r * r * 3.0
    Shape.Rect(w, _) -> return w
  end
end

def describe(n: Int) -> String
  case n
    1 -> return "one"
    -2 -> return "minus two"
    -9223372036854775808 -> return "min"
    9223372036854775808 -> return "beyond"
    _ -> return "many"
  end
end

def word(s: String) -> Int
  case s
    "a" -> return 1
    "b" ->
      puts("b")
      return 2
    _ -> return 0
  end
end

def flag(b: Bool, f: Float, x: Nil) -> Void
  case b
    true -> puts("yes")
    false -> puts("no")
    _ -> puts("?")
  end
  case f
    1.5 -> puts("one and a half")
    -0.5 -> puts("negative half")
    _ -> puts("float")
  end
  case x
    nil -> puts("nil")
    _ -> puts("other")
  end
end

def check(r: Result[Int]) -> String
  case r
    ok(n) -> return "ok #{n}"
    error(message) -> return message
  end
end

def check_void(r: Result[Void]) -> Void
  case r
    Result.Ok(_) -> puts("fine")
    Result.Err(m) -> puts(m)
  end
end

def main() -> Void
  puts(area(Shape.Rect(1.0, 2.0)))
  puts(describe(1) + word("b").to_s + check(ok(1)))
  flag(true, 1.5, nil)
  check_void(ok())
end
