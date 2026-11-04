def sign(n: Int) -> String
  if n < 0
    return "negative"
  else
    return "not negative"
  end
  puts("done")
end

def main() -> Void
  puts(sign(1))
end
