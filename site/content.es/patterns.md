---
title: Patrones
weight: 6
description: Los patrones de diseño comunes, escritos sin clases, con structs, enums, funciones y bloques.
source_hash: "c8dafd2e22df"
---

## Estrategia {#strategy}

Una regla es un valor `Fn`: pasa una función con `&name` o con un bloque.

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

## Fábrica {#factory}

Una función construye un valor a partir de un nombre y devuelve un `Result[T]`.

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

## Constructor {#builder}

Da valores predeterminados a los campos del struct y luego cambia algunos con `with`.

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

## Máquina de estados {#state-machine}

Un enum es el estado y un `case` es el paso.

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

## Comando {#command}

Las acciones son variantes de un enum; una sola función las aplica.

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

## Decorador {#decorator}

Una función recibe un `Fn` y devuelve uno nuevo: una lambda que lo llama.

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

## Observador {#observer}

El sujeto guarda una lista de `Fn`.

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
