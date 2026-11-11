def main() -> Void
  value: Optional[Int] = some(1)
  case value
    some(n), none -> puts("set or empty")
  end
end
