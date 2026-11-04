# Checks the number helpers against the vectors of math-vectors.stdin (made by tests/fixtures/math-vectors.py). A Float
# travels as its 64-bit pattern, so each result compares exactly, sign of zero and NaN included.
def report(line: String, got: String, want: String) -> Int
  if got == want
    return 0
  end
  puts("mismatch: #{line}: got #{got}, want #{want}")
  return 1
end

def float_of(field: String) -> Float
  return Float.from_bits(field.to_i!)
end

def bits_of(x: Float) -> String
  return x.to_bits.to_s
end

def ints_of(field: String) -> List[Int]
  return field.split(",").map do |text| text.to_i! end
end

def floats_of(field: String) -> List[Float]
  return field.split(",").map do |text| float_of(text) end
end

def check(line: String) -> Int
  f = line.split(" ")
  kind = f[0]
  if kind == "abs"
    return report(line, f[1].to_i!.abs.to_s, f[2])
  elsif kind == "pow"
    return report(line, f[1].to_i!.pow(f[2].to_i!).to_s, f[3])
  elsif kind == "gcd"
    return report(line, f[1].to_i!.gcd(f[2].to_i!).to_s, f[3])
  elsif kind == "clamp"
    return report(line, f[1].to_i!.clamp(f[2].to_i!, f[3].to_i!).to_s, f[4])
  elsif kind == "fabs"
    return report(line, bits_of(float_of(f[1]).abs), f[2])
  elsif kind == "floor"
    return report(line, float_of(f[1]).floor.to_s, f[2])
  elsif kind == "ceil"
    return report(line, float_of(f[1]).ceil.to_s, f[2])
  elsif kind == "round"
    return report(line, float_of(f[1]).round.to_s, f[2])
  elsif kind == "sqrt"
    return report(line, bits_of(Math.sqrt(float_of(f[1]))), f[2])
  elsif kind == "fclamp"
    return report(line, bits_of(float_of(f[1]).clamp(float_of(f[2]), float_of(f[3]))), f[4])
  elsif kind == "min"
    return report(line, ints_of(f[1]).min.unwrap!.to_s, f[2])
  elsif kind == "max"
    return report(line, ints_of(f[1]).max.unwrap!.to_s, f[2])
  elsif kind == "fmin"
    return report(line, bits_of(floats_of(f[1]).min.unwrap!), f[2])
  elsif kind == "fmax"
    return report(line, bits_of(floats_of(f[1]).max.unwrap!), f[2])
  end
  puts("mismatch: unknown vector: #{line}")
  return 1
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
      error(_) ->
        running = false
    end
  end
  if failed == 0
    puts("#{count} vectors ok")
  else
    puts("#{failed} of #{count} vectors failed")
  end
end
