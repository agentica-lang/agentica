struct Item
  name: String
  price: Int
end

def describe(item: Item) -> String
  return item.name + ": " + String.from_int(item.price)
end

def main() -> Void
  total = 0
  while not IO.eof?()
    parts = String.split(String.trim(IO.gets!()), " ")
    item = Item(name: parts[0], price: String.to_int!(parts[1]))
    puts(describe(item))
    total = total + item.price
  end
  puts("total: " + String.from_int(total))
end
