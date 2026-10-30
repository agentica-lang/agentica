enum Option[T]
  Some(T)
  None
end

enum Shape
  Circle(Float)
  Rect(Int, Int)
  Dot
end

enum Chain
  Link(Int, Chain)
  End
end

struct Box
  label: String
  shape: Shape
end

def area(s: Shape) -> Float
  case s
    Shape.Circle(r) -> return r * r * 3.0
    Shape.Rect(w, h) ->
      return 0.5
    Shape.Dot -> return 0.0
  end
end

def describe(o: Option[String]) -> String
  case o
    Option.Some(text) -> return "some #{text}"
    Option.None -> return "none"
  end
end

def count(n: Int) -> String
  out = ""
  case n
    0 -> out = "zero"
    -1 -> out = "minus one"
    9223372036854775808 -> out = "never"
    -9223372036854775808 -> out = "min"
    _ -> out = "many"
  end
  return out
end

def sign(x: Float) -> String
  case x
    -0.0 -> return "negative zero"
    0.0 -> return "zero"
    1.5 -> return "one and a half"
    _ -> return "other"
  end
end

def word(s: String) -> String
  case s
    "" -> return "empty"
    "λ" -> return "lambda"
    _ -> return "word"
  end
end

def flag(b: Bool, n: Nil) -> String
  out = ""
  case b
    true -> out = "yes"
    _ -> out = "no"
  end
  case n
    nil -> out = out + " nil"
    _ -> out = out + " other"
  end
  return out
end

def main() -> Void
  shapes = [Shape.Circle(2.0), Shape.Rect(3, 4), Shape.Dot, Shape.Dot()]
  puts(shapes)
  for s in shapes
    case s
      Shape.Circle(_) -> puts("circle")
      Shape.Rect(w, _) ->
        puts("rect #{w}")
        if w > 2
          next
        end
        puts("unreached")
      Shape.Dot -> puts("dot")
    end
    puts(area(s))
  end
  present = Option.Some("x")
  nested = Option.Some(Option.Some([1, 2]))
  absent: Option[Int] = Option.None
  puts(present)
  puts(nested)
  puts(absent)
  puts("#{present} #{absent.inspect} #{nested.to_s}")
  puts(describe(present))
  puts(describe(Option.None()))
  puts(count(0))
  puts(count(-1))
  puts(count(5))
  puts(count(-9223372036854775807 - 1))
  puts(sign(-0.0))
  puts(sign(0.0))
  puts(sign(3.0 / 2.0))
  puts(sign(2.0))
  puts(word(""))
  puts(word("λ"))
  puts(word("x"))
  puts(flag(true, nil))
  puts(flag(false, nil))
  box = Box(shape: Shape.Rect(1, 2), label: "b")
  puts(box)
  case box.shape
    Shape.Rect(a, b) -> puts(a + b)
    _ -> puts("not a rect")
  end
  case present
    Option.Some(x) -> puts("inner #{x}")
    Option.None -> puts("none")
  end
  case nested
    Option.Some(x) -> puts("again #{x}")
    Option.None -> puts("none")
  end
  chain = Chain.End
  i = 0
  while i < 40
    chain = Chain.Link(i, chain)
    i += 1
  end
  puts(chain)
  depth = 0
  walking = true
  while walking
    case chain
      Chain.Link(_, rest) ->
        depth += 1
        chain = rest
      Chain.End -> walking = false
    end
  end
  puts(depth)
  for n in [1, 2, 3]
    case n
      2 -> break
      _ -> puts("n #{n}")
    end
  end
end
