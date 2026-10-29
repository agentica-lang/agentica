# A seed of make vm-libfuzz-run: every Bytes builtin on small and large values (a doubled value of 1 MiB, a join of many
# parts, whole-input and empty cuts), equality and the hash keys, and the error paths a mutated operand reaches
# (a list item outside 0..255).
def main() -> Void
  big = "0123456789abcdef".bytes
  i = 0
  while i < 16
    big = big + big
    i += 1
  end
  puts(big.length)

  parts: List[Bytes] = []
  i = 0
  while i < 200
    parts = parts.push(big.take(i))
    i += 1
  end
  joined = Bytes.concat(parts)
  puts(joined.length)

  list = big.slice(1000, 300).to_a
  back = Bytes.from_list(list).unwrap!
  puts(back == big.slice(1000, 300))
  puts(back.drop(100).length + back.take(100).length + back.drop(1000).length)
  puts(big.slice(0, big.length) == big)
  puts(big.drop(big.length).empty?)
  puts(Bytes.from_list(list.push(256)).message)

  keys = Set.new([big, big + "".bytes, back, "".bytes, Bytes.concat([])])
  puts(keys.size)
  table: Map[Bytes, Int] = {}
  table = table.put(back, 1).put(back.take(300), 2)
  puts(table.size)

  total = 0
  for byte in back
    total += byte
  end
  puts(total)
  puts("#{back} #{back.inspect.length}")
  puts(back[299])
end
