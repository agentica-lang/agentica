# The vectors of tests/fixtures/list-float32-vectors.py (Python's struct 'f'), read from stdin: a List[Float32] of given
# bits, then the list operations on it, each as the size and a digest of the bits of its result.
def word(x: Float32) -> Int
  return 1 if x != x

  x.to_bits.to_i
end

def digest(xs: List[Float32]) -> String
  acc = 0
  for x in xs
    acc = (acc * 31 + word(x) % 1000003) % 1000003
  end
  return "#{xs.size} #{acc}"
end

def float32(token: String) -> Float32 = Float32.from_bits(token.to_i!.wrap_uint32)

def pushed(xs: List[Float32]) -> List[Float32]
  built: List[Float32] = []
  for x in xs
    built = built.push(x)
  end
  return built
end

def finite(x: Float32) -> Bool = x - x == 0.0

def json_round_trip(xs: List[Float32]) -> String
  case JSON.decode(JSON.encode(xs.select do |x| finite(x) end), List[Float32])
    ok(back) -> digest(back)
    error(e) -> "error #{e}"
  end
end

def products(xs: List[Float32]) -> List[Float32]
  n = xs.size
  return (0...n).to_a.map do |i| xs[i] * xs[(i * 7 + 3) % n] end
end

def total(xs: List[Float32]) -> List[Float32]
  zero: Float32 = 0.0
  return [xs.reduce(zero) do |acc, x| acc + x end]
end

def operated(op: String, args: List[String], xs: List[Float32]) -> String
  got = "unknown vector"
  case op
    "push" -> got = digest(pushed(xs))
    "map" -> got = digest(xs.map do |x| x end)
    "reverse" -> got = digest(xs.reverse)
    "filter" -> got = digest(xs.select do |x| finite(x) end)
    "json" -> got = json_round_trip(xs)
    "sort_by" -> got = digest(xs.sort_by do |x| x.to_f end)
    "take" -> got = digest(xs.take(args[0].to_i!))
    "drop" -> got = digest(xs.drop(args[0].to_i!))
    "swap" -> got = digest(xs.drop(args[0].to_i!).concat(xs.take(args[0].to_i!)))
    "set" -> got = digest(xs.set(args[0].to_i!, float32(args[1])))
    "repeat" -> got = digest(List.repeat(float32(args[0]), args[1].to_i!))
    "product" -> got = digest(products(xs))
    "sum" -> got = digest(total(xs))
    _ -> got = "unknown vector"
  end
  got
end

def main() -> Void
  _ = IO.gets()
  xs: List[Float32] = []
  count = 0
  failed = 0
  running = true
  while running
    case IO.gets()
      ok(line) ->
        parts = line.split(" : ")
        head = parts[0].split(" ")
        if head[0] == "in"
          xs = head.drop(2).map do |token| float32(token) end
        else
          got = operated(head[0], head.drop(1), xs)
          if got != parts[1]
            puts("#{line}: got #{got}")
            failed += 1
          end
          count += 1
        end
      error(_) -> running = false
    end
  end

  puts("#{count - failed} of #{count} vectors ok")
end
