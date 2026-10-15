export def make() -> Fn[Int, Int]
  return &double
end

def double(n: Int) -> Int
  return n * 2
end

