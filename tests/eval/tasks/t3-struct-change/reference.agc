struct Item
  name: String
  price: Int
  quantity: Int
end

def line_total(item: Item) -> Int
  return item.price * item.quantity
end

def describe(item: Item) -> String
  return item.name + ": " + String.from_int(item.price) + " x " + String.from_int(item.quantity) + " = " + String.from_int(line_total(item))
end

def main() -> Void
  total = 0
  while not IO.eof?()
    parts = String.split(String.trim(IO.gets!()), " ")
    item = Item(name: parts[0], price: String.to_int!(parts[1]), quantity: String.to_int!(parts[2]))
    puts(describe(item))
    total = total + line_total(item)
  end
  puts("total: " + String.from_int(total))
end
