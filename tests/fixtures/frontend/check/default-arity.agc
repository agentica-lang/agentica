def join(xs: List[String], sep: String = ", ", tail: String = "") -> String
  return xs.join(sep) + tail
end

def main() -> Void
  puts(join())
end
