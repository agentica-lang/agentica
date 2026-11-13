def triple(x: Int) -> Int
  return x * 3
end

def twice(f: Fn[Int, Int], x: Int) -> Int
  return f.call(f.call(x))
end
