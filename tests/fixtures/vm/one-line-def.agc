# One-line defs: `def name(params) -> Type = value` returns the value, as the def with `return value` does.

## The two values as a list.
export def pair[T](x: T, y: T) -> List[T] = [x, y]

def double(x: Int) -> Int = x * 2

def greet(name: String, greeting: String = "hi") -> String = "#{greeting} #{name}" # a trailing comment

def next_of(text: String) -> Result[Int] = ok(try text.to_i + 1)

def total(xs: List[Int]) -> Int = xs.map do |x| double(x) end.sum

def inside(a: Int, b: Int) -> Int = (
  a +
  b
)

def main() -> Void
  puts(pair("a", "b"))
  puts(double(21))
  puts(greet("ann"))
  puts(greet("bob", "hello"))
  puts(next_of("41"))
  puts(next_of("x"))
  puts(total([1, 2, 3]))
  puts(inside(1, 2))
end
