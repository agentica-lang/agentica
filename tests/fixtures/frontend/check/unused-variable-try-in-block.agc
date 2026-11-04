def load() -> Result[Int]
  return ok(1)
end

def apply(xs: List[Int], block: Fn[Int, Result[Int]]) -> Result[Int]
  return block.call(xs[0])
end

def run() -> Result[Void]
  out = apply([1]) do |i|
    y = try load()
    ok(y + i)
  end
  return ok()
end

def main() -> Void
  puts(run().ok?)
end
