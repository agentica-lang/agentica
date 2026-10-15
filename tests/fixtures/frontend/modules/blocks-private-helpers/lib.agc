struct Pair
  n: Int
end

export def doubled(xs: List[Int]) -> List[Int]
  pairs = xs.map do |x| Pair(n: twice(x)) end
  return pairs.map do |p: Pair| p.n end
end

def twice(n: Int) -> Int
  return n * 2
end

