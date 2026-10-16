enum Option
  Some(Int)
  None
end

def main() -> Void
  case Option.Some(1)
    Option.Some(n) if n > 0 -> puts(n)
    Option.None -> puts(0)
  end
end
