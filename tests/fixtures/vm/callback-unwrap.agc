def check(x: Int) -> Result[Int]
  if x > 2
    return error("too big: #{x}")
  end
  return ok(x)
end

def main() -> Void
  keys = [1, 2, 3].sort_by do |x|
    check(x).unwrap!
  end
  puts(keys)
end
