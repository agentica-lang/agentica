---
title: Patrones
weight: 6
description: Los patrones de diseño comunes, escritos sin clases, con estructuras, enums, funciones y bloques.
source_hash: "f1f15678db22"
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

Da valores predeterminados a los campos de la estructura y luego cambia algunos con `with`.

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

## Raíz de composición {#composition-root}

`main` construye los colaboradores, como el reloj y el `Store`, y los pasa. Una función nunca construye lo que llama, así que una prueba pasa un doble de prueba.

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

## Resultado de principio a fin {#result-all-the-way}

El cuerpo devuelve `Result[T]` y usa `try`. Convierte una sola vez, en la frontera, con `case`.

```agentica
def port(text: String) -> Result[Int]
  number = try text.to_i
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

## Recurso con un bloque {#resource-with-a-block}

Un auxiliar abre el recurso, llama al bloque y cierra, incluso cuando el bloque devuelve un error. Guarda el resultado en una variable y lo devuelve después del cierre, así que no necesita `ensure`. `File.open` con un bloque es el integrado.

```agentica
def with_connection(name: String, use: Fn[String, Result[String]]) -> Result[String]
  puts("open #{name}")
  result = use.call(name)
  puts("close #{name}")
  result
end

def main() -> Void
  rows = with_connection("db") do |conn| ok("rows from #{conn}") end
  puts(rows.unwrap!)

  failed = with_connection("db") do |conn| error("query failed on #{conn}") end
  puts(failed.message)
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

## Intérprete sobre un enum {#interpreter-over-an-enum}

Un enum recursivo es el árbol y un `case` lo recorre. Cada recorrido es una función, como lo es un Visitante en otros lenguajes.

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
    Expr.Num(n) -> "#{n}"
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

## Pipeline con canales {#pipeline-with-channels}

Un productor, trabajadores y un consumidor son tareas unidas por canales. `close` en `jobs` termina a los trabajadores. El consumidor toma los 6 resultados que espera, y `unwrap!` se detiene si falta uno, así que un tiempo de espera nunca da una suma corta.

```agentica
def produce(jobs: Channel[Int]) -> Void
  (1..6).each do |n| jobs.send(n, 1000).unwrap! end
  jobs.close
end

def work(jobs: Channel[Int], results: Channel[Int]) -> Void
  while true
    case jobs.recv(1000)
      ok(n) -> results.send(n * n, 1000).unwrap!
      error(_) -> break
    end
  end
end

def consume(results: Channel[Int], count: Int) -> Int
  (1..count).reduce(0) do |total, _| total + results.recv(1000).unwrap! end
end

def main() -> Void
  jobs: Channel[Int] = Channel.new(2)
  results: Channel[Int] = Channel.new(2)
  producer = Task.spawn do produce(jobs) end
  workers = [1, 2].map do |_| Task.spawn do work(jobs, results) end end
  consumer = Task.spawn do consume(results, 6) end
  Task.await(producer)
  workers.each do |worker| Task.await(worker) end
  puts(Task.await(consumer))
end
```

```output
91
```

## Reintento con espera creciente {#retry-with-backoff}

Una función recibe un `Fn` que devuelve un `Result` y lo llama otra vez tras una espera más larga, hasta un número de intentos. Aquí las esperas son mínimas.

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
