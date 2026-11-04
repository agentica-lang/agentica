def fetch(n: Int) -> Result[Int]
  return ok(n)
end

def main() -> Void
  [1, 2].each do |n|
    fetch(n)
  end
end
