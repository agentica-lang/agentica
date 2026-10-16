enum Option
  Some(Int)
  None
end

def main() -> Void
  zero = 0
  IO.warn("before")
  case Option.Some(6)
    Option.Some(n) if 12 / n == 2 -> puts("half")
    _ -> puts("other")
  end
  case Option.Some(6)
    Option.Some(n) if n / zero == 2 -> puts("never")
    _ -> puts("other")
  end
end
