# The Bytes type through the front end: the builtins, the operators, for/each, and use as a Map key or a Set item.
def total(data: Bytes) -> Int
  sum = 0
  for byte in data
    sum += byte
  end
  return sum
end

def main() -> Void
  data = "héllo".bytes
  puts(data.length)
  puts(data.size)
  puts(data[1])
  puts(data.at(2))
  puts(total(data))
  puts(data.to_a)
  puts("#{data}")
  puts(data.inspect)

  puts(data == "héllo".bytes)
  puts(data != "héllo".bytes)
  puts(data == "hello".bytes)
  puts(data != "hello".bytes)
  puts("".bytes == Bytes.concat([]))

  joined = "ab".bytes + "cd".bytes + "".bytes
  puts(joined.to_a)
  puts(Bytes.concat(["ab".bytes, "cd".bytes, "ef".bytes]).to_a)

  puts(joined.slice(1, 2).to_a)
  puts(joined.slice(4, 0).empty?)
  puts(joined.take(2).to_a)
  puts(joined.take(99).length)
  puts(joined.drop(3).to_a)
  puts(joined.drop(99).empty?)

  made = Bytes.from_list([0, 127, 128, 255]).unwrap!
  puts(made.to_a)
  puts(Bytes.from_list([1, 256, 3]).message)
  puts(Bytes.from_list([1, -1]).message)
  puts(Bytes.from_list([]).unwrap!.length)

  joined.each do |byte|
    puts(byte + 1)
  end

  for _ in "".bytes
    puts("never")
  end

  seen: Map[Bytes, Int] = {}
  seen = seen.put("key".bytes, 1)
  seen = seen.put("key".bytes, 2)
  puts(seen.size)
  puts(seen["key".bytes])
  puts(seen.has_key?("other".bytes))
  items = Set.new(["a".bytes, "a".bytes, "b".bytes])
  puts(items.size)
  puts(items.include?("b".bytes))

  nested = [made]
  puts(nested.inspect)
  Test.eq("abc".bytes, "abc".bytes)
end
