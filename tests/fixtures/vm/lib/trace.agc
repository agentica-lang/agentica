export def safe_div(a: Int, b: Int) -> Int
  return a / b
end

export def each_div(xs: List[Int]) -> List[Int]
  return xs.map do |x|
    safe_div(100, x)
  end
end
