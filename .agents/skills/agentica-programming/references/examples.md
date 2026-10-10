# Complete programs

Control flow and functions:

```ruby
def classify(age: Int) -> String
  if age >= 18
    return "adult"
  elsif age >= 13
    return "teen"
  else
    return "child"
  end
end

def main() -> Void
  puts(classify(25))
end
```

Structs, lists and blocks:

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
  pending = tasks.filter do |task| !task.done end
  pending.each do |task|
    puts("todo: #{task.title}")
  end
  puts("#{pending.size} of #{tasks.size} left")
end
```

Maps and strings:

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

Reading input, Result and `try`:

```ruby
def parse_numbers(line: String) -> Result[List[Int]]
  numbers: List[Int] = []
  words = line.strip.split(" ").filter do |w| w != "" end
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
    case parse_numbers(line) do
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
