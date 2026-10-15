import First from "library/models"
import Second from "library/../library/models"
import Outer from "library/outer"
def main() -> Void
  value: Second.Value = Outer.make(42)
  IO.inspect(First.read(value))
  IO.inspect(Second.read(First.Value(n: 7)))
end

