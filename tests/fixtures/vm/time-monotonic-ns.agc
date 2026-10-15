def main() -> Void
  first = Time.monotonic_ns()
  second = Time.monotonic_ns()
  puts(second >= first)
  ms_before = Time.monotonic_ms()
  ns = Time.monotonic_ns()
  ms_after = Time.monotonic_ms()
  puts(ns / 1000000 >= ms_before)
  puts(ns / 1000000 <= ms_after)
  start = Time.monotonic_ns()
  Task.sleep(20)
  puts(Time.monotonic_ns() - start >= 15000000)
end
