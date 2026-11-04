def main() -> Void
  puts("start")
  [1, 2, 3].each do |x: Int|
    _k = x
    while true
      _k += 1
    end
  end
  puts("done")
end
