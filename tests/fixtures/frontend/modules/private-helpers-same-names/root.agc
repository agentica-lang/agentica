import A from "a"
import B from "b"
def main() -> Void
  IO.inspect(List.map([1, 2], &A.apply))
  IO.inspect(List.map([1, 2], &B.apply))
end

