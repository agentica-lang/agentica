def key(items: List[Int]) -> Bytes
  return Bytes.from_list(items).unwrap!
end

def main() -> Void
  empty = key([])
  zero = key([0])
  zeros = key([0, 0])
  a = key([97])
  a_zero = key([97, 0])
  ab = key([97, 98])
  high = key([255])
  t: ATS[Bytes, Int] = ATS.new()
  t.put(ab, 1)
  t.put(a, 2)
  t.put(empty, 3)
  t.put(zeros, 4)
  t.put(high, 5)
  t.put(a_zero, 6)
  t.put(ab, 10)
  IO.inspect(t.size)
  IO.inspect(t.keys)
  IO.inspect([t.has_key?(zero), t.has_key?(zeros), t.has_key?(key([97, 98, 0])), t.has_key?(key([98]))])
  IO.inspect(t.get(empty))
  IO.inspect(t.get(zero))
  IO.inspect(t.put_new(zero, 7))
  IO.inspect(t.put_new(a, 99))
  IO.inspect(t.add(a, 40))
  IO.inspect(t.add(key([0, 97]), -3))
  t.delete(a)
  t.delete(key([97, 98, 99]))
  IO.inspect(t.has_key?(a))
  t.put(a, 8)
  copy: Map[Bytes, Int] = t.to_map
  IO.inspect(copy)
  IO.inspect([copy[a_zero], copy[empty], copy.size])
  IO.inspect(t.keys.map do |k| OpenSSL.Digest.hexencode(k) end)
  IO.inspect(t.get("ab".bytes))
end
