def load() -> Result[Int]
  return ok(1)
end

def run() -> Result[Void]
  total = (try load()) + 1
  return ok()
end

def main() -> Void
  puts(run().ok?)
end
