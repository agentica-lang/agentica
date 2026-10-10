def pick(xs: List[String], i: Int) -> String
  return xs[i - 4]
end

def main() -> Void
  names = ["Ana", "Bo", "Cy"]
  puts(pick(names, 6))
  IO.warn("before #{names}")
  puts(pick(names, 3))
end
