def numbers_of(field: String) -> List[Int]
  if field == "-"
    return []
  end
  return field.split(",").map do |part| part.to_i! end
end

def text_of(codes: List[Int]) -> String
  return codes.reduce("") do |acc, code| acc + String.from_code(code) end
end

# One vector: text.bytes must give the expected bytes, text.bytesize their count, and String.from_bytes the String
# back.
def check(line: String) -> Int
  f = line.split(";")
  text = text_of(numbers_of(f[0]))
  want = numbers_of(f[1])
  bytes = text.bytes
  if bytes.to_a.inspect == want.inspect && text.bytesize == want.size && String.from_bytes(bytes).unwrap! == text
    return 0
  end
  puts("mismatch: " + line)
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
