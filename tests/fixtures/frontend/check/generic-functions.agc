struct Box[T]
  value: T
end

def first_or[T](xs: List[T], fallback: T) -> T
  if xs.length == 0
    return fallback
  end

  return xs[0]
end

def max_by[T](xs: List[T], key: Fn[T, Int]) -> Result[T]
  if xs.length == 0
    return error("empty list")
  end

  return ok(xs[0])
end

def wrap[T, R](x: T, body: Fn[T, Result[R]]) -> Result[Box[R]]
  inner = try body.call(x)
  return ok(Box(value: inner))
end

def main() -> Void
  puts(first_or(["ana"], "none"))
  puts(first_or([], 0))
  best = max_by([1, 2]) do |n|
    n
  end
  puts(best.unwrap_or(0))
  boxed = wrap(2) do |n|
    ok(n.to_s)
  end
  puts(boxed.unwrap_or(Box(value: "")).value)
  pick: Fn[List[Int], Int, Int] = &first_or
  puts(pick.call([], 3))
end
