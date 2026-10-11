def down(n: Int) -> Int
  ys = [n].map do |x|
    down(x + 1) + 1
  end
  return ys[0]
end

def main() -> Void
  puts("start")
  puts(down(0))
end
