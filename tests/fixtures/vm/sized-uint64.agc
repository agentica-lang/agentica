# The vectors of tests/fixtures/sized-uint64.py (Python ints), read from stdin: the operators, the bit and wrapping
# methods, the conversions, sorting and the widenings of UInt64. An operation that halts is `-` in a vector and is not
# run: tests/test_spec_sized.py has those cases.

def operand(text: String) -> UInt64 = text.to_i!.wrap_uint64

def show(value: UInt64) -> String = "#{value}"

def differs(what: String, got: List[String], want: List[String]) -> Int
  return 0 if got == want

  puts("#{what}: got #{got}, want #{want}")
  1
end

def arith(parts: List[String]) -> Int
  a = operand(parts[1])
  b = operand(parts[2])
  want = parts.drop(3)
  got = ["-", "-", "-", "-", "-", "#{a < b}", "#{a <= b}", "#{a == b}", "#{a != b}", "#{a > b}", "#{a >= b}"]
  if want[0] != "-"
    got = got.set(0, show(a + b))
  end

  if want[1] != "-"
    got = got.set(1, show(a - b))
  end

  if want[2] != "-"
    got = got.set(2, show(a * b))
  end

  if want[3] != "-"
    got = got.set(3, show(a / b))
  end

  if want[4] != "-"
    got = got.set(4, show(a % b))
  end

  differs(parts.take(3).join(" "), got, want)
end

def bits(parts: List[String]) -> Int
  a = operand(parts[1])
  b = operand(parts[2])
  got = [
    show(a.bit_and(b)),
    show(a.bit_or(b)),
    show(a.bit_xor(b)),
    show(a.wrapping_add(b)),
    show(a.wrapping_sub(b)),
    show(a.wrapping_mul(b)),
  ]

  differs(parts.take(3).join(" "), got, parts.drop(3))
end

def shift(parts: List[String]) -> Int
  a = operand(parts[1])
  count = parts[2].to_i!
  got = [show(a.shift_left(count)), show(a.shift_right(count))]
  differs(parts.take(3).join(" "), got, parts.drop(3))
end

def convert(parts: List[String]) -> Int
  a = operand(parts[1])
  as_int = "-"
  case a.to_i
    ok(n) -> as_int = n.to_s
    error(_) -> as_int = "-"
  end

  got = [as_int, a.to_f.to_bits.to_s, show(a.bit_not.bit_not)]
  differs(parts.take(2).join(" "), got, [parts[2], parts[3], parts[1].to_i!.wrap_uint64.to_s])
end

def wrap(parts: List[String]) -> Int
  n = parts[1].to_i!
  checked = "-"
  case n.to_uint64
    ok(value) -> checked = show(value)
    error(_) -> checked = "-"
  end

  differs("wrap #{n}", [show(n.wrap_uint64), checked], [parts[2], parts[3]])
end

def widen(parts: List[String]) -> Int
  n = parts[1].to_i!
  got = [show(n.to_uint32!.to_uint64), show(n.to_uint64!)]
  if n < 65536
    got = got.push(show(n.to_uint16!.to_uint64))
  end

  if n < 256
    got = got.push(show(n.to_uint8!.to_uint64))
  end

  differs("widen #{n}", got, List.repeat(parts[1], got.size))
end

def order(parts: List[String]) -> Int
  split = parts.index("|").unwrap!
  given = parts.take(split).drop(1).map do |text: String| operand(text) end
  expected = parts.drop(split + 1).map do |text: String| show(operand(text)) end
  by_sort = given.sort.map do |value: UInt64| show(value) end
  keyed = given.sort_by do |value: UInt64| value end
  by_key = keyed.map do |value: UInt64| show(value) end
  differs("order", by_sort, expected) + differs("order by key", by_key, expected)
end

def order8(parts: List[String]) -> Int
  split = parts.index("|").unwrap!
  given = parts.take(split).drop(1).map do |text: String| text.to_i!.to_int8! end
  got = given.sort.map do |value: Int8| value.to_i.to_s end
  differs("order8", got, parts.drop(split + 1))
end

def check(line: String) -> Int
  parts = line.split(" ")
  case parts[0]
    "arith" -> arith(parts)
    "bits" -> bits(parts)
    "shift" -> shift(parts)
    "convert" -> convert(parts)
    "wrap" -> wrap(parts)
    "widen" -> widen(parts)
    "order" -> order(parts)
    "order8" -> order8(parts)
    "not" -> differs(line, [show(operand(parts[1]).bit_not)], [parts[2]])
    _ ->
      puts("unknown vector: #{line}")
      1
  end
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
