struct State
  prices: Map[String, Int]
  unknown: Int
end

def find_price(prices: Map[String, Int], item: String) -> Result[Int]
  if prices.has_key?(item)
    return ok(prices[item])
  end
  return error("unknown item #{item}")
end

def bad_command() -> Void
  puts("error: bad command")
end

def miss(state: State) -> State
  return State(prices: state.prices, unknown: state.unknown + 1)
end

def price_command(state: State, args: List[String]) -> State
  if args.size != 2
    bad_command()
    return state
  end
  cents = args[1].to_i
  if !cents.ok? || cents.unwrap! < 0
    bad_command()
    return state
  end
  item = args[0]
  old = find_price(state.prices, item)
  if old.ok?
    puts("updated #{item}: #{old.unwrap!} -> #{cents.unwrap!}")
  else
    puts("added #{item}: #{cents.unwrap!}")
  end
  return State(prices: state.prices.put(item, cents.unwrap!), unknown: state.unknown)
end

def quote_command(state: State, args: List[String]) -> State
  if args.size != 1
    bad_command()
    return state
  end
  price = find_price(state.prices, args[0])
  if !price.ok?
    puts("error: #{price.message}")
    return miss(state)
  end
  puts("#{args[0]}: #{price.unwrap!}")
  return state
end

def cost_command(state: State, args: List[String]) -> State
  if args.size < 3 || args.size % 2 != 1
    bad_command()
    return state
  end
  quantities: List[Int] = []
  i = 2
  while i < args.size
    qty = args[i].to_i
    if !qty.ok? || qty.unwrap! < 1
      bad_command()
      return state
    end
    quantities = quantities.push(qty.unwrap!)
    i += 2
  end
  total = 0
  for n in 0...quantities.size
    price = find_price(state.prices, args[1 + 2 * n])
    if !price.ok?
      puts("#{args[0]}: #{price.message}")
      return miss(state)
    end
    total = total + price.unwrap! * quantities[n]
  end
  puts("#{args[0]}: #{total}")
  return state
end

def cheapest_command(state: State, args: List[String]) -> State
  if args.size < 1
    bad_command()
    return state
  end
  best = ""
  best_price = -1
  found = false
  misses = 0
  for item in args
    price = find_price(state.prices, item)
    if !price.ok?
      misses += 1
    elsif !found || price.unwrap! < best_price
      best = item
      best_price = price.unwrap!
      found = true
    end
  end
  if found
    puts("cheapest: #{best} (#{best_price})")
  else
    puts("error: no known items")
  end
  return State(prices: state.prices, unknown: state.unknown + misses)
end

def report_command(state: State) -> Void
  for item in state.prices.keys.sort
    puts("#{item} #{state.prices[item]}")
  end
end

def main() -> Void
  prices: Map[String, Int] = {}
  state = State(prices: prices, unknown: 0)
  while !IO.eof?()
    line = IO.gets!().strip
    if line == ""
      next
    end
    parts = line.split(" ").filter do |w| w != "" end
    args = parts.drop(1)
    case parts[0]
      "price" -> state = price_command(state, args)
      "quote" -> state = quote_command(state, args)
      "cost" -> state = cost_command(state, args)
      "cheapest" -> state = cheapest_command(state, args)
      "report" -> report_command(state)
      _ -> bad_command()
    end
  end
  puts("unknown: #{state.unknown}")
end
