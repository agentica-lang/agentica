enum Op
  Add(Int)
  Sub(Int)
  Mul(Int)
  Mod(Int)
  Neg
  Twice
end

def scale() -> Int
  return 1
end

def apply(acc: Int, op: Op) -> Int
  result = acc
  case op
    Op.Add(n) -> result = acc + n
    Op.Sub(n) -> result = acc - n
    Op.Mul(n) -> result = acc * n
    Op.Mod(n) -> result = acc % n
    Op.Neg -> result = -acc
    Op.Twice -> result = acc * 2
  end
  return result
end

def bucket(value: Int) -> Int
  result = 0
  case value % 4
    0 -> result = 3
    1 -> result = 5
    2 -> result = 7
    _ -> result = 11
  end
  return result
end

def main() -> Void
  program = [Op.Add(7), Op.Mul(13), Op.Twice, Op.Sub(5), Op.Mod(1000003), Op.Neg, Op.Add(1000003), Op.Mul(3), Op.Mod(999983)]
  rounds = 5000 * scale()
  acc = 1
  checksum = 0
  round = 0
  while round < rounds
    for op in program
      acc = apply(acc, op)
    end
    checksum = (checksum + bucket(acc) * acc) % 1000000007
    round += 1
  end
  puts("case #{rounds}: acc #{acc}, checksum #{checksum}")
end
