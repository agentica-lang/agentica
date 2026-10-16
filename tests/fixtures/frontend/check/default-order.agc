def join(sep: String = ", ", xs: List[String]) -> String
  return xs.join(sep)
end

def main() -> Void
  puts(join([]))
end
