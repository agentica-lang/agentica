struct Tag
  name: String
end

struct Item
  id: Int
  price: Float
  fine: Bool
  title: String
  tags: List[Tag]
  attrs: Map[String, List[Int]]
  next: List[Header]
end

struct Plain
  note: String
  flags: Map[String, Bool]
end

struct Skipped
  items: List[Item]
  status: LogLevel
end

def main() -> Void
  item = JSON.decode("{}", Item)
  puts(item.ok?)
  plain = JSON.decode("{}", Plain)
  puts(plain.ok?)
  s = Skipped(items: [], status: LogLevel.Info)
  puts(JSON.encode(plain.unwrap!))
  puts(s.items.size)
end
