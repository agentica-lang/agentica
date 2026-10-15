def twice(n: Int) -> Int
  return n * 2
end

struct Box
  items: List[Int]
  tags: Map[String, Json]
end

struct Hook
  run: Fn[Int, Int]
end

def main() -> Void
  h = Hook(run: &twice)
  r = Test.eq(h, h)
end

