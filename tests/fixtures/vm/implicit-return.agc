# The last expression of a def is its value (#1287): in the body, in each branch of a last `if` with `else`, and in
# each arm of a last `case`, at any depth. `return` still leaves early. The peers of
# tests/test_spec_implicit_return.py print the same lines.

type Nothing = Void

enum Shape
  Square(Int)
  Rect(Int, Int)
  Pair(Shape, Shape)
end

def area(shape: Shape) -> Int
  case shape
    Shape.Square(side) -> side * side
    Shape.Rect(width, height) -> width * height
    Shape.Pair(left, right) -> area(left) + area(right)
  end
end

def label(n: Int) -> String
  return "none" if n == 0
  if n == 1
    "one"
  elsif n < 0
    case n
      -1 -> "minus one"
      _ ->
        if n < -100
          "far below"
        else
          "below"
        end
    end
  else
    "#{n} items"
  end
end

def fib(n: Int) -> Int
  return n if n < 2
  fib(n - 1) + fib(n - 2)
end

def twice[T](item: T) -> List[T]
  pair = [item, item]
  pair
end

def parsed(text: String) -> Result[Int]
  value = try text.to_i
  ok(value + 1)
end

def shown(result: Result[Int]) -> String
  case result
    ok(value) -> "ok #{value}"
    error(_) -> "error"
  end
end

def square(n: Int) -> Int = n * n

def say(text: String) -> Nothing
  line = "say #{text}"
  puts(line)
end

def main() -> Void
  puts(area(Shape.Square(3)))
  puts(area(Shape.Pair(Shape.Rect(2, 5), Shape.Square(1))))
  for n in [0, 1, -1, -5, -500, 7]
    puts(label(n))
  end

  puts(fib(15))
  puts(twice("ab").join(","))
  puts(shown(parsed("41")))
  puts(shown(parsed("x")))
  puts(square(12))
  say("done")
end
