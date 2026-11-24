# The vectors of tests/fixtures/float32-vectors.py (fractions.Fraction), read from stdin: JSON numbers decoded into a
# Float32 field, the text of Float32 bits, Int.to_float32, Float.to_float32 and the operators on two Float32s. A
# division by zero (`x`) is not run: it halts (tests/test_spec_float32.py).
struct Box
  x: Float32
end

def float32(bits: Int) -> Float32 = Float32.from_bits(bits.to_uint32!)

def bits(x: Float32) -> String = x.to_bits.to_s

def outcome(decoded: Result[Box]) -> String
  case decoded
    ok(box) -> bits(box.x)
    error(_) -> "error"
  end
end

# The bits of the Float32 field decoded from the document, from its text and from its JSON.Value, which must agree.
def decoded(document: String) -> String
  from_text = outcome(JSON.decode(document, Box))
  from_value = outcome(JSON.decode(JSON.parse(document).unwrap!, Box))
  return from_text if from_text == from_value

  "the text gives #{from_text} and its JSON.Value #{from_value}"
end

def check_text(n: Int, want: String) -> String
  x = float32(n)
  shown = x.to_s
  return shown if shown != want or want.include?("inf") or want.include?("nan")
  return "#{shown} reads back as #{decoded("{\"x\": #{shown}}")}" if decoded("{\"x\": #{shown}}") != "#{n}"

  shown
end

def operated(a: Float32, b: Float32, divided: Bool) -> String
  quotient = "x"
  if divided
    quotient = bits(a / b)
  end

  "#{bits(a + b)} #{bits(a - b)} #{bits(a * b)} #{quotient} #{a < b} #{a <= b} #{a == b}"
end

def check(line: String) -> Int
  fields = line.split(" ")
  want = fields.drop(2).join(" ")
  got = ""
  case fields[0]
    "json" -> got = decoded("{\"x\": #{fields[1]}}")
    "text" -> got = check_text(fields[1].to_i!, want)
    "int" -> got = bits(fields[1].to_i!.to_float32)
    "float" -> got = bits(Float.from_bits(fields[1].to_i!).to_float32)
    "ops" -> got = operated(float32(fields[1].to_i!), float32(fields[2].to_i!), fields[6] != "x")
    _ -> got = "unknown vector"
  end

  if fields[0] == "ops"
    want = fields.drop(3).join(" ")
  end

  return 0 if got == want

  puts("#{line}: got #{got}")
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

  puts("#{count - failed} of #{count} vectors ok")
end
