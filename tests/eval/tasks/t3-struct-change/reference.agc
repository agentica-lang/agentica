struct Item
  name: String
  price: Int
  quantity: Int
end

def line_total(item: Item) -> Int
  return item.price * item.quantity
end

def describe(item: Item) -> String
  return item.name + ": " + item.price.to_s + " x " + item.quantity.to_s + " = " + line_total(item).to_s
end

def main() -> Void
  total = 0
  while not IO.eof?()
    parts = String.split(IO.gets!().strip, " ")
    item = Item(name: parts[0], price: parts[1].to_i!, quantity: parts[2].to_i!)
    puts(describe(item))
    total = total + line_total(item)
  end
  puts("total: " + total.to_s)
end
