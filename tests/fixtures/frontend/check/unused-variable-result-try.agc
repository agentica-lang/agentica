def load() -> Result[Int]
  return ok(1)
end

def run() -> Result[Void]
  result = load()
  return ok()
end

def main() -> Void
  puts(run().ok?)
end
