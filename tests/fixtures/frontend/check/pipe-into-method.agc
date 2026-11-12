def size_of(xs: List[Int]) -> Int = xs.size

def main() -> Void
  n = [1, 2] |> map(->(x) { x * 2 }) |> size_of()
  puts([n] |> sum())
end
