def stop(code: Int) -> Void
  puts("stop #{code}")
  System.exit(code)
end

def main() -> Void
  stop(256)
  puts("not reached")
end
