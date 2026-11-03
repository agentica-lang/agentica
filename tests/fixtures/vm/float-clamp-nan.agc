def main() -> Void
  big = 1.0e308 * 10.0
  puts(0.5.clamp(0.0, big))
  puts(0.5.clamp(big - big, 1.0))
  puts("not reached")
end
