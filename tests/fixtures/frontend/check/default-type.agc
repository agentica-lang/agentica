def join(xs: List[String], sep: String = 1) -> String
  return xs.join(sep)
end

def main() -> Void
  puts(join([]))
end
