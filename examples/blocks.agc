# Blocks are functions written at the call site. They capture the values
# they can see when they are created.
struct Item
  name: String
  price: Float
  stock: Int
end

def apply_discount(items: List[Item], rule: Fn[Item, Float]) -> List[Item]
  return items.map do |item|
    Item(name: item.name, price: rule.call(item), stock: item.stock)
  end
end

def main() -> Void
  items = [
    Item(name: "tea", price: 4.0, stock: 3),
    Item(name: "coffee", price: 9.5, stock: 0),
    Item(name: "cocoa", price: 6.0, stock: 12)
  ]
  rate = 0.5
  cheaper = apply_discount(items) do |item|
    if item.stock > 10
      return item.price * rate
    end
    item.price
  end
  in_stock = cheaper.filter do |item| item.stock > 0 end
  by_price = in_stock.sort_by do |item| item.price end
  by_price.each do |item|
    puts("#{item.name}: #{item.price}")
  end
  total = in_stock.reduce(0) do |sum, item| sum + item.stock end
  puts("units: #{total}")
  empty = items.any? do |item| item.stock == 0 end
  puts("any empty: #{empty}")
end
