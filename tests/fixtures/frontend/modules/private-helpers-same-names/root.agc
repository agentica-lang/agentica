import "a" as A
import "b" as B
def main() -> Void
  IO.inspect(List.map([1, 2], &A.apply))
  IO.inspect(List.map([1, 2], &B.apply))
end

