type Matrix[T] = List[List[T]]

type Grid = Matrix[Float]

type Index[K] = Map[K, Int]

def rows(m: Matrix[Int]) -> Int
  return m.size
end

def main() -> Void
  m: Matrix[Int] = [[1, 2], [3]]
  plain: List[List[Int]] = m
  grid: Grid = [[1.5]]
  index: Index[String] = {"a": 1}
  puts(rows(plain))
  puts(grid[0][0])
  puts(index["a"])
end
