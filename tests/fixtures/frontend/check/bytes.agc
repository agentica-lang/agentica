def joined(a: Bytes, b: Bytes) -> Bytes
  return a + b
end

def same(a: Bytes, b: Bytes) -> Bool
  return a == b
end

def differ(a: Bytes, b: Bytes) -> Bool
  return a != b
end

def total(data: Bytes) -> Int
  sum = data[0]
  for byte in data
    sum += byte
  end
  for _ in data
    sum += 1
  end
  return sum
end

def main() -> Void
  puts(total("ab".bytes))
  puts(same(joined("a".bytes, "b".bytes), "ab".bytes))
  puts(differ("a".bytes, "b".bytes))
  "ab".bytes.each do |byte| puts(byte) end
end
