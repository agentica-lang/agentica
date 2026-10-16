type Names = List[String]

def count(names: Names) -> Int
  return names.size
end

def main() -> Void
  names: Names = ["red", "blue"]
  puts(count(names))
end
