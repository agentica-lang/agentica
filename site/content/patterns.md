---
title: Patterns
weight: 6
description: The common design patterns written without classes, with structs, enums, functions and blocks.
---

## Strategy

A rule is an `Fn` value: pass a function with `&name` or a block.

```agentica
def total(prices: List[Int], discount: Fn[Int, Int]) -> Int
  return prices.reduce(0) do |sum, price| sum + discount.call(price) end
end

def half(price: Int) -> Int
  return price / 2
end

def main() -> Void
  puts(total([100, 50], &half))
  puts(total([100, 50]) do |price| price - 10 end)
end
```

```output
75
130
```

## Factory

One function builds a value from a name and returns a `Result[T]`.

```agentica
enum Shape
  Circle(Float)
  Square(Float)
end

def shape(kind: String, size: Float) -> Result[Shape]
  case kind
    "circle" -> return ok(Shape.Circle(size))
    "square" -> return ok(Shape.Square(size))
    _ -> return error("unknown shape: #{kind}")
  end
end

def main() -> Void
  puts(shape("square", 3.0).unwrap!)
  puts(shape("star", 1.0).message)
end
```

```output
Shape.Square(3.0)
unknown shape: star
```

## Builder

Give struct fields defaults, then change some with `with`.

```agentica
struct Request
  url: String
  method: String = "GET"
  retries: Int = 0
end

def main() -> Void
  request = Request(url: "https://example.com").with(method: "POST").with(retries: 3)
  puts("#{request.method} #{request.retries}")
end
```

```output
POST 3
```

## State machine

An enum is the state and a `case` is the step.

```agentica
enum Door
  Open
  Closed
end

enum Event
  Push
  Pull
end

def step(door: Door, event: Event) -> Door
  case door
    Door.Open ->
      case event
        Event.Push -> return Door.Closed
        _ -> return door
      end

    Door.Closed ->
      case event
        Event.Pull -> return Door.Open
        _ -> return door
      end
  end
end

def main() -> Void
  puts([Event.Push, Event.Push, Event.Pull].reduce(Door.Open) do |state, event| step(state, event) end)
end
```

```output
Door.Open
```

## Command

Actions are enum variants; one function applies them.

```agentica
enum Command
  Deposit(Int)
  Withdraw(Int)
end

def apply(balance: Int, command: Command) -> Int
  case command
    Command.Deposit(n) -> return balance + n
    Command.Withdraw(n) -> return balance - n
  end
end

def main() -> Void
  puts([Command.Deposit(100), Command.Withdraw(30)].reduce(0) do |balance, command| apply(balance, command) end)
end
```

```output
70
```

## Decorator

A function takes an `Fn` and returns a new one. A block can only follow a call, so `wrap` returns it.

```agentica
def wrap(f: Fn[Int, Int]) -> Fn[Int, Int]
  return f
end

def logged(f: Fn[Int, Int]) -> Fn[Int, Int]
  return wrap() do |x: Int|
    y = f.call(x)
    puts("f(#{x}) = #{y}")
    y
  end
end

def main() -> Void
  double = logged() do |x| x * 2 end
  double.call(4)
end
```

```output
f(4) = 8
```

## Observer

The subject holds a list of `Fn`.

```agentica
struct Bus
  handlers: List[Fn[String, String]]
end

def subscribe(bus: Bus, handler: Fn[String, String]) -> Bus
  return bus.with(handlers: bus.handlers.push(handler))
end

def publish(bus: Bus, message: String) -> List[String]
  return bus.handlers.map do |handler| handler.call(message) end
end

def shout(text: String) -> String
  return text.upcase
end

def main() -> Void
  puts(Bus(handlers: []) |> subscribe(&shout) |> publish("hello"))
end
```

```output
["HELLO"]
```
