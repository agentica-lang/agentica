import "library/models" as First
import "library/../library/models" as Second
import "library/outer" as Outer
def main() -> Void
  value: Second.Value = Outer.make(42)
  IO.inspect(First.read(value))
  IO.inspect(Second.read(First.Value(n: 7)))
end

