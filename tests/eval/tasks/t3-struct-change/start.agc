struct Item
  name: String
  price: Int
end

def describe(item: Item) -> String
  return item.name + ": " + item.price.to_s
end

def main() -> Void
  total = 0
  while not IO.eof?()
    parts = String.split(IO.gets!().strip, " ")
    item = Item(name: parts[0], price: parts[1].to_i!)
    puts(describe(item))
    total = total + item.price
  end
  puts("total: " + total.to_s)
end
