struct S
  n: Int
end

def main() -> Void
  s = S(n: 1).with(n: Nope.Thing)
end

