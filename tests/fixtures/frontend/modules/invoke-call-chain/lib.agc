def make() -> Fn[Int, Int]
  return &double
end

private

def double(n: Int) -> Int
  return n * 2
end
