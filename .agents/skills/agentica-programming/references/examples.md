# Complete programs

Structs, enums, `case`, Result, `try`, `for` and blocks:

```ruby
struct Item
  name: String
  price: Int
end

enum Status
  Paid
  Owed(Int)
end

def describe(status: Status) -> String
  case status
    Status.Paid -> return "paid"
    Status.Owed(amount) -> return "owed #{amount}"
  end
end

def parse_price(text: String) -> Result[Int]
  price = try text.to_i
  if price < 0
    return error("negative: #{price}")
  elsif price == 0
    return error("free")
  end

  return ok(price)
end

def main() -> Void
  items: List[Item] = [Item(name: "pen", price: 3), Item(name: "book", price: 12)]
  total = 0
  for item in items
    total += item.price
  end

  names = items.map do |item| item.name.upcase end
  puts("#{names.join(",")} cost #{total}, half is #{total.to_f * 0.5}")
  case total
    15 -> puts("fifteen")
    _ -> puts("total is #{total}")
  end

  case parse_price("x7")
    ok(p) -> puts(describe(Status.Owed(p)))
    error(message) -> puts(message)
  end
end
```

Filtering with a block:

```ruby
struct Todo
  title: String
  done: Bool
end

def main() -> Void
  tasks: List[Todo] = [
    Todo(title: "write code", done: false),
    Todo(title: "review code", done: true)
  ]
  pending = tasks.select do |task| !task.done end
  pending.each do |task|
    puts("todo: #{task.title}")
  end

  puts("#{pending.size} of #{tasks.size} left")
end
```

Maps:

```ruby
def main() -> Void
  stock: Map[String, Int] = {"apple": 3, "pear": 0}
  stock = stock.put("kiwi", 7)
  for name in stock.keys
    if stock[name] > 0
      puts("#{name.upcase}: #{stock[name]}")
    end
  end
end
```

Reading input:

```ruby
def parse_numbers(line: String) -> Result[List[Int]]
  numbers: List[Int] = []
  words = line.strip.split(" ").select do |w| w != "" end
  for word in words
    n = try word.to_i
    numbers = numbers.push(n)
  end

  return ok(numbers)
end

def main() -> Void
  total = 0
  count = 0
  while !IO.eof?()
    line = IO.gets!()
    case parse_numbers(line)
      Result.Ok(numbers) ->
        total += numbers.reduce(0) do |sum, n| sum + n end
        count += numbers.size
      Result.Err(message) ->
        IO.warn("skipped: #{message}")
    end
  end

  puts("#{count} numbers, total #{total}")
end
```
