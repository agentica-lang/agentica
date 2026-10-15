def main() -> Void
  puts(Time.monotonic_ns())
  Task.sleep(20)
  puts(Time.monotonic_ns())
end
