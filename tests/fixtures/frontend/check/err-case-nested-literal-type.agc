enum Option
  Some(Int)
  None
end

def main() -> Void
  case Option.Some(1)
    Option.Some("one") -> puts(1)
    _ -> puts(2)
  end
end
