def main() -> Void
  wall = Time.now_ms
  puts(wall > 1700000000000)
  first = Time.monotonic_ms()
  second = Time.monotonic_ms()
  puts(second >= first)
  later = Time.now_ms()
  puts(later >= wall - 1000)
end
