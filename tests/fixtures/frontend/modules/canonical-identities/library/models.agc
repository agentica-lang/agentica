export struct Value
  n: Int
end

export def read(value: Value) -> Int
  return value.n
end

def main() -> Void
  puts("must not run")
end

