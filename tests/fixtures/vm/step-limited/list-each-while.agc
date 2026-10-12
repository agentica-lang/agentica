def main() -> Void
  puts("start")
  [1, 2, 3].each do |x: Int|
    k = x
    while true
      k += 1
    end
  end
  puts("done")
end
