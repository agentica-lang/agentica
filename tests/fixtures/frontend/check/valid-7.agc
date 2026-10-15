def text(n: Int) -> String
  return String.from_int(n)
end


def keep(n: Int) -> Bool
  return n > 0
end


def join(acc: String, n: Int) -> String
  return acc + String.from_int(n)
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
  a = List.map([], &text)
  b = List.filter([], &keep)
  c = List.reduce([], "", &join)
  d = List.reduce([1], "", &join)
  e = List.reduce([1], [], &collect)
end

