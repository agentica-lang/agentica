# The vectors of tests/fixtures/sized-vectors.py (Python ints), read from stdin: Int.to_<type> of each value and to_i
# back, and the operators of each type on two values. A result that must halt (`x`) is not run: the fixtures
# sized-add-overflow, sized-sub-below-zero and sized-divide-minimum halt on the three kinds.

OPERATORS = ["add", "sub", "mul", "div", "mod", "lt", "le", "gt", "ge", "eq", "ne", "neg"]

def shown(text: String, back: Int) -> String
  return "ok #{text}" if text == back.to_s

  "to_i gives #{back} for #{text}"
end

def converted(name: String, n: Int) -> String
  case name
    "int8" ->
      case n.to_int8
        ok(v) -> shown("#{v}", v.to_i)
        error(_) -> "error"
      end

    "int16" ->
      case n.to_int16
        ok(v) -> shown("#{v}", v.to_i)
        error(_) -> "error"
      end

    "int32" ->
      case n.to_int32
        ok(v) -> shown("#{v}", v.to_i)
        error(_) -> "error"
      end

    "uint8" ->
      case n.to_uint8
        ok(v) -> shown("#{v}", v.to_i)
        error(_) -> "error"
      end

    "uint16" ->
      case n.to_uint16
        ok(v) -> shown("#{v}", v.to_i)
        error(_) -> "error"
      end

    "uint32" ->
      case n.to_uint32
        ok(v) -> shown("#{v}", v.to_i)
        error(_) -> "error"
      end

    _ -> "unknown type #{name}"
  end
end

def operate_int8(op: String, x: Int, y: Int) -> String
  a = x.to_int8!
  b = y.to_int8!
  case op
    "add" -> (a + b).to_s
    "sub" -> (a - b).to_s
    "mul" -> (a * b).to_s
    "div" -> (a / b).to_s
    "mod" -> (a % b).to_s
    "lt" -> (a < b).to_s
    "le" -> (a <= b).to_s
    "gt" -> (a > b).to_s
    "ge" -> (a >= b).to_s
    "eq" -> (a == b).to_s
    "ne" -> (a != b).to_s
    "neg" -> (-a).to_s
    _ -> "no operator #{op}"
  end
end

def operate_int16(op: String, x: Int, y: Int) -> String
  a = x.to_int16!
  b = y.to_int16!
  case op
    "add" -> (a + b).to_s
    "sub" -> (a - b).to_s
    "mul" -> (a * b).to_s
    "div" -> (a / b).to_s
    "mod" -> (a % b).to_s
    "lt" -> (a < b).to_s
    "le" -> (a <= b).to_s
    "gt" -> (a > b).to_s
    "ge" -> (a >= b).to_s
    "eq" -> (a == b).to_s
    "ne" -> (a != b).to_s
    "neg" -> (-a).to_s
    _ -> "no operator #{op}"
  end
end

def operate_int32(op: String, x: Int, y: Int) -> String
  a = x.to_int32!
  b = y.to_int32!
  case op
    "add" -> (a + b).to_s
    "sub" -> (a - b).to_s
    "mul" -> (a * b).to_s
    "div" -> (a / b).to_s
    "mod" -> (a % b).to_s
    "lt" -> (a < b).to_s
    "le" -> (a <= b).to_s
    "gt" -> (a > b).to_s
    "ge" -> (a >= b).to_s
    "eq" -> (a == b).to_s
    "ne" -> (a != b).to_s
    "neg" -> (-a).to_s
    _ -> "no operator #{op}"
  end
end

def operate_uint8(op: String, x: Int, y: Int) -> String
  a = x.to_uint8!
  b = y.to_uint8!
  case op
    "add" -> (a + b).to_s
    "sub" -> (a - b).to_s
    "mul" -> (a * b).to_s
    "div" -> (a / b).to_s
    "mod" -> (a % b).to_s
    "lt" -> (a < b).to_s
    "le" -> (a <= b).to_s
    "gt" -> (a > b).to_s
    "ge" -> (a >= b).to_s
    "eq" -> (a == b).to_s
    "ne" -> (a != b).to_s
    _ -> "no operator #{op}"
  end
end

def operate_uint16(op: String, x: Int, y: Int) -> String
  a = x.to_uint16!
  b = y.to_uint16!
  case op
    "add" -> (a + b).to_s
    "sub" -> (a - b).to_s
    "mul" -> (a * b).to_s
    "div" -> (a / b).to_s
    "mod" -> (a % b).to_s
    "lt" -> (a < b).to_s
    "le" -> (a <= b).to_s
    "gt" -> (a > b).to_s
    "ge" -> (a >= b).to_s
    "eq" -> (a == b).to_s
    "ne" -> (a != b).to_s
    _ -> "no operator #{op}"
  end
end

def operate_uint32(op: String, x: Int, y: Int) -> String
  a = x.to_uint32!
  b = y.to_uint32!
  case op
    "add" -> (a + b).to_s
    "sub" -> (a - b).to_s
    "mul" -> (a * b).to_s
    "div" -> (a / b).to_s
    "mod" -> (a % b).to_s
    "lt" -> (a < b).to_s
    "le" -> (a <= b).to_s
    "gt" -> (a > b).to_s
    "ge" -> (a >= b).to_s
    "eq" -> (a == b).to_s
    "ne" -> (a != b).to_s
    _ -> "no operator #{op}"
  end
end

def operated(name: String, op: String, a: Int, b: Int) -> String
  case name
    "int8" -> operate_int8(op, a, b)
    "int16" -> operate_int16(op, a, b)
    "int32" -> operate_int32(op, a, b)
    "uint8" -> operate_uint8(op, a, b)
    "uint16" -> operate_uint16(op, a, b)
    "uint32" -> operate_uint32(op, a, b)
    _ -> "unknown type #{name}"
  end
end

# The result of every operator that does not halt, against the expected one.
def check_operators(line: String) -> Int
  f = line.split(" ")
  failed = 0
  for i in 0...12
    want = f[4 + i]
    got = want
    if want != "x"
      got = operated(f[1], OPERATORS[i], f[2].to_i!, f[3].to_i!)
    end

    next if got == want

    puts("mismatch: #{line}: #{OPERATORS[i]} got #{got}")
    failed += 1
  end

  failed
end

def check(line: String) -> Int
  return check_operators(line) if line.start_with?("ops ")

  f = line.split(" ")
  want = f.drop(3).join(" ")
  got = converted(f[1], f[2].to_i!)
  return 0 if got == want

  puts("mismatch: #{line}: got #{got}")
  1
end

def main() -> Void
  _ = IO.gets()
  count = 0
  failed = 0
  running = true
  while running
    case IO.gets()
      ok(line) ->
        failed += check(line)
        count += 1
      error(_) -> running = false
    end
  end

  if failed == 0
    puts("#{count} vectors ok")
  else
    puts("#{failed} of #{count} vectors failed")
  end
end
