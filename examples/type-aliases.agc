type Names = List[String]

def count(names: Names) -> Int = names.size

def main() -> Void
  names: Names = ["red", "blue"]
  puts(count(names))
end
