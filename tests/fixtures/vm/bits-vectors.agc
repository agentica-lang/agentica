def infinity() -> Float
  x = 10.0
  i = 0
  while i < 9
    x = x * x
    i += 1
  end
  return x
end

def pow2(exponent: Int) -> Float
  base = 2.0
  n = exponent
  if exponent < 0
    base = 0.5
    n = 0 - exponent
  end
  result = 1.0
  while n > 0
    if n % 2 == 1
      result = result * base
    end
    n = n / 2
    if n > 0
      base = base * base
    end
  end
  return result
end

def float_of(field: String) -> Float
  if field == "inf"
    return infinity()
  elsif field == "-inf"
    return 0.0 - infinity()
  elsif field == "nan"
    return infinity() - infinity()
  elsif field == "-0"
    return (0.0 - 1.0) * 0.0
  end
  parts = field.split("p")
  return Float.from_int(parts[0].to_i!) * pow2(parts[1].to_i!)
end

def float_text(x: Float) -> String
  if x != x
    return "nan"
  end
  return x.to_s
end

def report(line: String, got: String, want: String) -> Int
  if got == want
    return 0
  end
  puts("mismatch: #{line}: got #{got}, want #{want}")
  return 1
end

def check(line: String) -> Int
  f = line.split(" ")
  kind = f[0]
  if kind == "bit_and"
    return report(line, Int.bit_and(f[1].to_i!, f[2].to_i!).to_s, f[3])
  elsif kind == "bit_or"
    return report(line, Int.bit_or(f[1].to_i!, f[2].to_i!).to_s, f[3])
  elsif kind == "bit_xor"
    return report(line, Int.bit_xor(f[1].to_i!, f[2].to_i!).to_s, f[3])
  elsif kind == "bit_not"
    return report(line, Int.bit_not(f[1].to_i!).to_s, f[2])
  elsif kind == "shift_left"
    return report(line, Int.shift_left(f[1].to_i!, f[2].to_i!).to_s, f[3])
  elsif kind == "shift_right"
    return report(line, Int.shift_right(f[1].to_i!, f[2].to_i!).to_s, f[3])
  elsif kind == "shift_right_unsigned"
    return report(line, Int.shift_right_unsigned(f[1].to_i!, f[2].to_i!).to_s, f[3])
  elsif kind == "to_bits"
    return report(line, Float.to_bits(float_of(f[1])).to_s, f[2])
  elsif kind == "from_bits"
    return report(line, float_text(Float.from_bits(f[1].to_i!)), float_text(float_of(f[2])))
  elsif kind == "to_bits32"
    return report(line, Float.to_bits32(float_of(f[1])).to_s, f[2])
  elsif kind == "from_bits32"
    return report(line, float_text(Float.from_bits32(f[1].to_i!)), float_text(float_of(f[2])))
  end
  puts("mismatch: unknown vector: #{line}")
  return 1
end

def main() -> Void
  IO.gets()
  count = 0
  failed = 0
  running = true
  while running
    case IO.gets()
      ok(line) ->
        failed += check(line)
        count += 1
      error(message) ->
        running = false
    end
  end
  if failed == 0
    puts("#{count} vectors ok")
  else
    puts("#{failed} of #{count} vectors failed")
  end
end
