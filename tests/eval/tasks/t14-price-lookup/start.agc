def find_price(prices: Map[String, Int], item: String) -> Int
  if prices.has_key?(item)
    return prices[item]
  end
  return -1
end

def bad_command() -> Void
  puts("error: bad command")
end

def price_command(prices: Map[String, Int], args: List[String]) -> Map[String, Int]
  if args.size != 2
    bad_command()
    return prices
  end
  cents = args[1].to_i
  if !cents.ok? || cents.unwrap! < 0
    bad_command()
    return prices
  end
  item = args[0]
  old = find_price(prices, item)
  if old == -1
    puts("added #{item}: #{cents.unwrap!}")
  else
    puts("updated #{item}: #{old} -> #{cents.unwrap!}")
  end
  return prices.put(item, cents.unwrap!)
end

def quote_command(prices: Map[String, Int], args: List[String]) -> Void
  if args.size != 1
    bad_command()
    return
  end
  puts("#{args[0]}: #{find_price(prices, args[0])}")
end

def cost_command(prices: Map[String, Int], args: List[String]) -> Void
  if args.size < 3 || args.size % 2 != 1
    bad_command()
    return
  end
  total = 0
  i = 1
  while i < args.size
    qty = args[i + 1].to_i
    if !qty.ok? || qty.unwrap! < 1
      bad_command()
      return
    end
    total = total + find_price(prices, args[i]) * qty.unwrap!
    i += 2
  end
  puts("#{args[0]}: #{total}")
end

def cheapest_command(prices: Map[String, Int], args: List[String]) -> Void
  if args.size < 1
    bad_command()
    return
  end
  best = args[0]
  best_price = find_price(prices, best)
  for item in args.drop(1)
    price = find_price(prices, item)
    if price < best_price
      best = item
      best_price = price
    end
  end
  puts("cheapest: #{best} (#{best_price})")
end

def report_command(prices: Map[String, Int]) -> Void
  for item in prices.keys.sort
    puts("#{item} #{prices[item]}")
  end
end

def main() -> Void
  prices: Map[String, Int] = {}
  while !IO.eof?()
    line = IO.gets!().strip
    if line == ""
      next
    end
    parts = line.split(" ").filter do |w| w != "" end
    args = parts.drop(1)
    case parts[0]
      "price" -> prices = price_command(prices, args)
      "quote" -> quote_command(prices, args)
      "cost" -> cost_command(prices, args)
      "cheapest" -> cheapest_command(prices, args)
      "report" -> report_command(prices)
      _ -> bad_command()
    end
  end
end
