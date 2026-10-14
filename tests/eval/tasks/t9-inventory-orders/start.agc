struct Item
  name: String
  qty: Int
  price: Int
end

struct Shop
  items: Map[String, Item]
  spent: Map[String, Int]
  revenue: Int
end

def new_shop() -> Shop
  items: Map[String, Item] = {}
  spent: Map[String, Int] = {}
  return Shop(items: items, spent: spent, revenue: 0)
end

def words(line: String) -> List[String]
  return line.strip.split(" ").filter do |w| w != "" end
end

def parse_count(text: String) -> Result[Int]
  n = try text.to_i
  if n < 0
    return error("negative")
  end
  return ok(n)
end

def bad_command() -> Void
  puts("error: bad command")
end

def unknown_item(name: String) -> Void
  puts("error: unknown item #{name}")
end

def with_item(shop: Shop, item: Item) -> Shop
  return Shop(items: shop.items.put(item.name, item), spent: shop.spent, revenue: shop.revenue)
end

def add_command(shop: Shop, args: List[String]) -> Shop
  if args.size != 3
    bad_command()
    return shop
  end
  qty = parse_count(args[1])
  price = parse_count(args[2])
  if !qty.ok? || !price.ok?
    bad_command()
    return shop
  end
  name = args[0]
  have = 0
  if shop.items.has_key?(name)
    have = shop.items[name].qty
  end
  total = have + qty.unwrap!
  puts("added #{name}: #{qty.unwrap!} (now #{total})")
  return with_item(shop, Item(name: name, qty: total, price: price.unwrap!))
end

def line_total(item: Item, qty: Int) -> Int
  return item.price * qty
end

def order_command(shop: Shop, args: List[String]) -> Shop
  if args.size != 3
    bad_command()
    return shop
  end
  qty = parse_count(args[2])
  if !qty.ok? || qty.unwrap! == 0
    bad_command()
    return shop
  end
  customer = args[0]
  name = args[1]
  if !shop.items.has_key?(name)
    puts("rejected #{customer} #{name}: unknown item")
    return shop
  end
  item = shop.items[name]
  wanted = qty.unwrap!
  if item.qty < wanted
    puts("rejected #{customer} #{name}: only #{item.qty} in stock")
    return shop
  end
  total = line_total(item, wanted)
  puts("sold #{customer} #{name} #{wanted} for #{total}")
  left = Item(name: item.name, qty: item.qty - wanted, price: item.price)
  before = shop.spent.get(customer, 0)
  return Shop(items: shop.items.put(name, left), spent: shop.spent.put(customer, before + total), revenue: shop.revenue + total)
end

def price_command(shop: Shop, args: List[String]) -> Shop
  if args.size != 2
    bad_command()
    return shop
  end
  price = parse_count(args[1])
  if !price.ok?
    bad_command()
    return shop
  end
  name = args[0]
  if !shop.items.has_key?(name)
    unknown_item(name)
    return shop
  end
  item = shop.items[name]
  puts("price #{name}: #{price.unwrap!}")
  return with_item(shop, Item(name: name, qty: item.qty, price: price.unwrap!))
end

def stock_command(shop: Shop, args: List[String]) -> Void
  if args.size != 1
    bad_command()
    return
  end
  name = args[0]
  if !shop.items.has_key?(name)
    unknown_item(name)
    return
  end
  puts("#{name}: #{shop.items[name].qty}")
end

def customers_command(shop: Shop) -> Void
  if shop.spent.size == 0
    puts("no customers")
    return
  end
  for customer in shop.spent.keys.sort
    puts("#{customer}: #{shop.spent[customer]}")
  end
end

def report_command(shop: Shop) -> Void
  for name in shop.items.keys.sort
    item = shop.items[name]
    puts("#{item.name} #{item.qty} x #{item.price}")
  end
  puts("revenue: #{shop.revenue}")
end

def run_command(shop: Shop, line: String) -> Shop
  parts = words(line)
  command = parts[0]
  args = parts.drop(1)
  if command == "add"
    return add_command(shop, args)
  elsif command == "order"
    return order_command(shop, args)
  elsif command == "price"
    return price_command(shop, args)
  elsif command == "stock"
    stock_command(shop, args)
  elsif command == "customers"
    customers_command(shop)
  elsif command == "report"
    report_command(shop)
  else
    bad_command()
  end
  return shop
end

def main() -> Void
  shop = new_shop()
  while !IO.eof?()
    line = IO.gets!().strip
    if line == ""
      next
    end
    shop = run_command(shop, line)
  end
end
