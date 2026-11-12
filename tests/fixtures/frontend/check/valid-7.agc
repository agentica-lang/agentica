def text(n: Int) -> String
  return n.to_s
end


def keep(n: Int) -> Bool
  return n > 0
end


def join(acc: String, n: Int) -> String
  return acc + n.to_s
end


def collect(acc: List[Int], n: Int) -> List[Int]
  return List.append(acc, n)
end


def ignore(n: Int) -> Void
end


def bad(acc: String, n: Int) -> Int
  return n
end

def main() -> Void
  _a = List.map([], &text)
  _b = List.filter([], &keep)
  _c = List.reduce([], "", &join)
  _d = List.reduce([1], "", &join)
  _e = List.reduce([1], [], &collect)
end

