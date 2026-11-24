# The vectors of tests/fixtures/sized-vectors.py (Python ints), read from stdin: Int.to_<type> of each value,
# and to_int
# back.

def shown(text: String, back: Int) -> String
  return "ok #{text}" if text == back.to_s

  "to_int gives #{back} for #{text}"
end

def converted(name: String, n: Int) -> String
  case name
    "int8" ->
      case n.to_int8
        ok(v) -> shown("#{v}", v.to_int)
        error(_) -> "error"
      end

    "int16" ->
      case n.to_int16
        ok(v) -> shown("#{v}", v.to_int)
        error(_) -> "error"
      end

    "int32" ->
      case n.to_int32
        ok(v) -> shown("#{v}", v.to_int)
        error(_) -> "error"
      end

    "uint8" ->
      case n.to_uint8
        ok(v) -> shown("#{v}", v.to_int)
        error(_) -> "error"
      end

    "uint16" ->
      case n.to_uint16
        ok(v) -> shown("#{v}", v.to_int)
        error(_) -> "error"
      end

    "uint32" ->
      case n.to_uint32
        ok(v) -> shown("#{v}", v.to_int)
        error(_) -> "error"
      end

    _ -> "unknown type #{name}"
  end
end

def check(line: String) -> Int
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
