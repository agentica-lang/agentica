struct Counter
  next: Fn[Int, Int]
  tell: Fn[String, Void]
end

def succ(n: Int) -> Int
  return n + 1
end

def say(text: String) -> Void
  puts(text)
end

def main() -> Void
  counter = Counter(next: &succ, tell: &say)
  puts(counter.next(counter.next(1)))
  counter.tell("done")
end
