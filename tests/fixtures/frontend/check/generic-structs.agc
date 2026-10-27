struct Box[T]
  value: T
  items: List[T] = []
end

struct Pair[A, B]
  first: A
  second: B
end

def unwrap(box: Box[Int]) -> Int
  return box.value
end

def main() -> Void
  box = Box(value: 1)
  puts(unwrap(box))
  pair = Pair(first: "x", second: box)
  puts(pair.second.value)
  empty: Box[List[String]] = Box(value: [])
  puts(empty.with(value: ["a"]).value.size)
end
