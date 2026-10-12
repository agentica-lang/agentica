def apply(x: Int, f: Fn[Int, Void]) -> Void
  f.call(x)
end

def main() -> Void
  puts("start")
  offset = 2
  apply(1) do |x: Int|
    k = x + offset
    while true
      k += 1
    end
  end
  puts("done")
end
