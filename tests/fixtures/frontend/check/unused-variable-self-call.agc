def step(n: Int) -> Result[Int] = ok(n + 1)

def price(n: Int) -> Int = n * 2

def run() -> Result[Void]
  count = 0
  total = 0
  i = 0
  while i < 3
    count = try step(count)
    total = total + price(i)
    i = i + 1
  end

  ok()
end

def main() -> Void
  puts(run().ok?)
end
