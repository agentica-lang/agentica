def ping(n: Int) -> Int
  if n == 0
    return 1 / n
  end
  return 1 + pong(n - 1)
end

def pong(n: Int) -> Int
  if n == 0
    return 1 / n
  end
  return 1 + ping(n - 1)
end

def main() -> Void
  Test.run([
    Test.test("one frame cut") do
      Test.eq(ping(19), 1)
    end,
    Test.test("two frames cut") do
      Test.eq(ping(20), 1)
    end
  ])
end
