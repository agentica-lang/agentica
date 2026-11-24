---
title: Patterns
weight: 6
description: The common design patterns written without classes, with structs, enums, functions and blocks.
---

## Strategy

A rule is an `Fn` value: pass a function with `&name` or a block.

```agentica
def total(prices: List[Int], discount: Fn[Int, Int]) -> Int
  prices.reduce(0) do |sum, price| sum + discount.call(price) end
end

def half(price: Int) -> Int = price / 2

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
    "circle" -> ok(Shape.Circle(size))
    "square" -> ok(Shape.Square(size))
    _ -> error("unknown shape: #{kind}")
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
        Event.Push -> Door.Closed
        _ -> door
      end

    Door.Closed ->
      case event
        Event.Pull -> Door.Open
        _ -> door
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
    Command.Deposit(n) -> balance + n
    Command.Withdraw(n) -> balance - n
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

A function takes an `Fn` and returns a new one, a lambda that calls it.

```agentica
def logged(f: Fn[Int, Int]) -> Fn[Int, Int]
  ->(x) {
    y = f.call(x)
    puts("f(#{x}) = #{y}")
    y
  }
end

def main() -> Void
  double = logged do |x| x * 2 end
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

def subscribe(bus: Bus, handler: Fn[String, String]) -> Bus = bus.with(handlers: bus.handlers.push(handler))

def publish(bus: Bus, message: String) -> List[String] = bus.handlers.map do |handler| handler.call(message) end

def shout(text: String) -> String = text.upcase

def main() -> Void
  puts(Bus(handlers: []) |> subscribe(&shout) |> publish("hello"))
end
```

```output
["HELLO"]
```

## Composition root

`main` builds the collaborators, such as the clock and the `Store`, and passes them in. A function never builds what it calls, so a test passes a fake.

```agentica
struct Store
  notes: List[String]
end

def note(store: Store, clock: Fn[Int], text: String) -> Store
  store.with(notes: store.notes.push("#{clock.call()} #{text}"))
end

def main() -> Void
  clock = &Time.now_ms
  real = note(Store(notes: []), clock, "started")
  puts(real.notes.size)

  fake = -> { 1000 }
  puts(note(Store(notes: []), fake, "started").notes)
end
```

```output
1
["1000 started"]
```

## Result all the way

The body returns `Result[T]` and uses `try`. Convert once, at the boundary, with `case`.

```agentica
def parse(text: String) -> Result[Int] = text.to_i

def port(text: String) -> Result[Int]
  number = try parse(text)
  return error("port out of range: #{number}") if number < 1 or number > 65535

  ok(number)
end

def describe(text: String) -> String
  case port(text)
    ok(n) -> "listening on #{n}"
    error(e) -> "bad port: #{e.message}"
  end
end

def main() -> Void
  puts(describe("8080"))
  puts(describe("99999"))
  puts(describe("web"))
end
```

```output
listening on 8080
bad port: port out of range: 99999
bad port: cannot convert "web" to Int
```

## Resource with a block

A helper opens the resource, calls the block and closes it. There is no `ensure`: the helper keeps the result in a variable and returns it after the close, so the close runs on every path. `try use.call(name)` would return before the close. `File.open` with a block is the builtin one.

```agentica
def with_connection[T](name: String, use: Fn[String, Result[T]]) -> Result[T]
  puts("open #{name}")
  result = use.call(name)
  puts("close #{name}")
  result
end

def fetch(conn: String) -> Result[String] = ok("rows from #{conn}")

def broken(conn: String) -> Result[String] = error("query failed on #{conn}")

def main() -> Void
  puts(with_connection("db", &fetch).unwrap!)
  puts(with_connection("db", &broken).message)
end
```

```output
open db
close db
rows from db
open db
close db
query failed on db
```

## Interpreter over an enum

A recursive enum is the tree and a `case` walks it. Each walk is one function, as a Visitor is in other languages.

```agentica
enum Expr
  Num(Int)
  Add(Expr, Expr)
  Mul(Expr, Expr)
end

def eval(expr: Expr) -> Int
  case expr
    Expr.Num(n) -> n
    Expr.Add(left, right) -> eval(left) + eval(right)
    Expr.Mul(left, right) -> eval(left) * eval(right)
  end
end

def show(expr: Expr) -> String
  case expr
    Expr.Num(n) -> n.to_s
    Expr.Add(left, right) -> "(#{show(left)} + #{show(right)})"
    Expr.Mul(left, right) -> "#{show(left)} * #{show(right)}"
  end
end

def main() -> Void
  expr = Expr.Mul(Expr.Add(Expr.Num(1), Expr.Num(2)), Expr.Num(4))
  puts(show(expr))
  puts(eval(expr))
end
```

```output
(1 + 2) * 4
12
```

## Pipeline with channels

A producer, workers and a consumer are tasks joined by channels. `close` is the end: a receiver stops when `recv` gives an error. The sum is the same in any order.

```agentica
def produce(jobs: Channel[Int]) -> Void
  (1..6).each do |n| _ = jobs.send(n, 1000) end
  jobs.close
end

def work(jobs: Channel[Int], results: Channel[Int]) -> Void
  while true
    case jobs.recv(1000)
      ok(n) -> _ = results.send(n * n, 1000)
      error(_) -> break
    end
  end
end

def consume(results: Channel[Int]) -> Int
  total = 0
  while true
    case results.recv(1000)
      ok(n) -> total = total + n
      error(_) -> break
    end
  end

  total
end

def main() -> Void
  jobs: Channel[Int] = Channel.new(2)
  results: Channel[Int] = Channel.new(2)
  producer = Task.spawn do produce(jobs) end
  workers = [1, 2].map do |_| Task.spawn do work(jobs, results) end end
  consumer = Task.spawn do consume(results) end
  Task.await(producer)
  workers.each do |worker| Task.await(worker) end
  results.close
  puts(Task.await(consumer))
end
```

```output
91
```

## Retry with backoff

A function takes an `Fn` that returns a `Result` and calls it again after a longer wait, up to a number of attempts. The waits are tiny here.

```agentica
def retry[T](attempts: Int, wait_ms: Int, action: Fn[Int, Result[T]]) -> Result[T]
  result = action.call(1)
  attempt = 1
  delay = wait_ms
  while not result.ok? and attempt < attempts
    puts("attempt #{attempt} failed, waiting #{delay} ms")
    Task.sleep(delay)
    delay = delay * 2
    attempt = attempt + 1
    result = action.call(attempt)
  end

  result
end

def flaky(attempt: Int) -> Result[String]
  return error("busy") if attempt < 3

  ok("done on attempt #{attempt}")
end

def main() -> Void
  puts(retry(5, 1, &flaky).unwrap!)
  puts(retry(2, 1, &flaky).message)
end
```

```output
attempt 1 failed, waiting 1 ms
attempt 2 failed, waiting 2 ms
done on attempt 3
attempt 1 failed, waiting 1 ms
busy
```
