---
title: Guía de estilo
weight: 6
description: Cómo escribir código de Agentica simple y fácil de leer, con un ejemplo para cada regla.
source_hash: "c8f958265263"
---

El código se lee mucho más de lo que se escribe. Esta guía mantiene el código de Agentica simple y fácil de leer, con el espíritu de las guías de estilo de Ruby y Elixir. Cuando una regla estorba a un código claro, gana el código claro. Cambia el estilo solo del código que tocas.

Algunas reglas se exigen: el programa no compila si las incumples. Sus ejemplos llevan la marca "No compila" y muestran el código de error.

## Disposición {#layout}

Sangra con dos espacios. Nada de tabuladores, nada de espacios al final de la línea, y un salto de línea al final del archivo.

Mantén las líneas en 119 caracteres o menos, con los comentarios incluidos. Parte una llamada o una lista larga con un elemento por línea y una coma final:

```agentica {mode="check" fmt="off"}
# good
struct User
  name: String
  age: Int
  email: String
end

def main() -> Void
  user = User(
    name: "Ana",
    age: 25,
    email: "ana@example.com",
  )
  puts(user.name)
end
```

Pon una expresión larga entre paréntesis. Nunca sigas una expresión en una línea suelta:

```agentica {mode="check" fmt="off"}
# good
def label(first: String, last: String, title: String) -> String
  return (
    "#{title} #{first} #{last}, " +
    "member of the board since 2001"
  )
end

def main() -> Void
  puts(label("Ana", "Diaz", "Dr."))
end
```

Pon espacios alrededor de los operadores y después de las comas, pero no alrededor de `..` y `...` ni dentro de corchetes o paréntesis: `total(a, b) + 1`, `[1, 2, 3]`, `0..9`.

Separa las declaraciones de nivel superior con una línea vacía. No pongas líneas vacías justo después de `def` ni antes de `end`, ni dos líneas vacías seguidas.

```agentica {expect="PARSE-MISSING-BLANK-LINE" fmt="off"}
# bad
def one() -> Int
  return 1
end
def main() -> Void
  puts(one())
end
```

Pon una línea vacía después del `end` de un bloque, antes de la siguiente sentencia. Los ejemplos de este sitio la siguen, y `blank_line_after_end = true` bajo `[style]` en `agentica.toml` hace que `agentica check` la exija (ver [la referencia de módulos](/reference/modules/)).

## Nombres {#naming}

| Qué | Estilo | Ejemplo |
|---|---|---|
| funciones, variables, campos, archivos | `snake_case` | `read_line`, `max_len`, `http_client.agc` |
| estructuras, enums, variantes | `CamelCase` | `User`, `Shape.Circle` |
| constantes | `UPPER_SNAKE_CASE` | `MAX_TRIES` |

La primera letra se exige, y también que una constante vaya en mayúsculas:

```agentica {expect="PARSE-CONSTANT-NAME" fmt="off"}
# bad
Limit = 10

def main() -> Void
  puts(Limit)
end
```

Una función que devuelve un `Bool` termina en `?` y se lee como una pregunta. No uses el prefijo `is_`:

```agentica {mode="check"}
# good
def blank?(text: String) -> Bool = text.length == 0

def main() -> Void
  puts(blank?(""))
end
```

Un nombre que termina en `!` detiene el programa en lugar de devolver un `Result`. Pon un `!` a una función solo cuando haga eso.

Nombra las cosas por lo que significan, no por su tipo: `price`, no `int_value`. Pon nombre a un número que tenga un significado, y usa `_` en los números grandes:

```agentica {mode="check"}
# good
MAX_BYTES = 1_048_576

def too_big?(bytes: Int) -> Bool = bytes > MAX_BYTES

def main() -> Void
  puts(too_big?(2048))
end
```

Dilo en positivo. Pon el caso positivo primero y no pongas una condición negada junto a `else`:

```agentica {mode="check"}
# good
def describe(visible: Bool) -> String
  return "shown" if visible

  "hidden"
end

def main() -> Void
  puts(describe(true))
end
```

## Archivos y documentación {#files-and-docs}

Un archivo tiene un orden fijo: su documentación y sus importaciones; la parte pública (constantes, luego estructuras, enums, alias de tipo, bloques de módulo y bloques extern con un recurso, luego funciones); una línea `private` con una línea vacía antes y después; y luego la parte privada en el mismo orden. Ordena las importaciones por ruta. Una constante se lee a través del alias (`Limits.LIMIT`) como el resto; impórtala por nombre (`import {LIMIT} from "limits"`) cuando se usa mucho, y un archivo puede importar un módulo de las dos maneras.

```agentica {expect="CHECK-DECL-ORDER"}
# bad
def main() -> Void
  puts("x")
end

struct Item
  name: String
end
```

Mantén un solo tema por archivo, y haz públicos solo los nombres que usan otros archivos.

Documenta lo mínimo. Solo el código público recibe un `##`: una función, estructura o enum público, que diga qué devuelve o qué es, no cómo. Una función privada nunca recibe `##`; cuando necesita una nota, usa un solo comentario `#`. Un campo o una variante recibe una nota solo cuando su nombre no dice lo suficiente. Un comentario `#` dice por qué el código es así, no qué hace la línea siguiente:

```agentica {mode="check"}
# bad
## This function loops over the prices and adds them up.
def total(prices: List[Int]) -> Int
  sum = 0
  # add each price to sum
  for price in prices
    sum += price
  end

  sum
end

def main() -> Void
  puts(total([250, 199]))
end
```

```agentica {mode="check"}
# good
## Returns the sum of the prices, in cents.
def total(prices: List[Int]) -> Int
  sum = 0
  for price in prices
    sum += price
  end

  sum
end

private

def main() -> Void
  puts(total([250, 199]))
end
```

Borra el código en lugar de comentarlo.

## Funciones {#functions}

Haz que cada función tenga un solo trabajo. Si los comentarios la dividen en partes, divídela en funciones.

Usa cuatro parámetros o menos. Pon más en una estructura. Una función cuyo cuerpo es un solo valor es un def de una línea, `def double(n: Int) -> Int = n * 2`; `agentica fmt` la escribe así. Devuelve pronto en los casos malos, para que el flujo principal se quede plano:

```agentica {mode="check"}
# bad
def ship(weight: Int, width: Int, height: Int, depth: Int, rush: Bool) -> Int
  cost = 0
  if weight > 0
    if width > 0
      if rush
        cost = weight * 3
      else
        cost = weight * 2
      end
    end
  end

  cost
end

def main() -> Void
  puts(ship(2, 10, 10, 10, true))
end
```

```agentica {mode="check"}
# good
struct Parcel
  weight: Int
  width: Int
  height: Int
  depth: Int
  rush: Bool
end

def ship(parcel: Parcel) -> Int
  return 0 if parcel.weight <= 0 or parcel.width <= 0

  return parcel.weight * 3 if parcel.rush

  parcel.weight * 2
end

def main() -> Void
  puts(ship(Parcel(weight: 2, width: 10, height: 10, depth: 10, rush: true)))
end
```

Un registro con campos conocidos es una estructura, no un mapa:

```agentica {mode="check"}
# good
struct User
  name: String
end

def greet(user: User) -> String = "hello #{user.name}"

def main() -> Void
  puts(greet(User(name: "Ana")))
end
```

Usa un bucle `for` para un total acumulado, y un método como `map` para transformar una lista. Un bloque no puede asignar una variable desde fuera de él:

```agentica {expect="CHECK-CAPTURED-ASSIGNMENT"}
# bad
def main() -> Void
  sum = 0
  [1, 2].each do |x| sum += x end
  puts(sum)
end
```

```agentica {mode="check"}
# good
def main() -> Void
  sum = 0
  for x in [1, 2]
    sum += x
  end

  puts(sum)
  puts([1, 2].map do |x| x * 2 end)
end
```

Usa un bloque en una llamada solo para un cuerpo corto, una sola expresión como `do |order| order.item end`. Un cuerpo más largo, como un handler de ruta (`|> Bond.get("/users/:id", &show_user)`) o varias sentencias, es una función con nombre que se pasa con `&name`:

```agentica {mode="check"}
# bad
struct Order
  item: String
  price: Int
  count: Int
end

def main() -> Void
  orders = [Order(item: "tea", price: 3, count: 2)]
  lines = orders.map do |order|
    total = order.price * order.count
    tax = total / 10
    "#{order.item}: #{total + tax}"
  end

  puts(lines)
end
```

```agentica {mode="check"}
# good
struct Order
  item: String
  price: Int
  count: Int
end

def line(order: Order) -> String
  total = order.price * order.count
  tax = total / 10
  "#{order.item}: #{total + tax}"
end

def main() -> Void
  orders = [Order(item: "tea", price: 3, count: 2)]
  puts(orders.map(&line))
  puts(orders.map do |order| order.item end)
end
```

Usa un `Bool` tal cual, con `and`, `or` y `not`, nunca comparado con `true` o `false`:

```agentica {mode="check"}
# good
def allowed?(admin: Bool, banned: Bool) -> Bool = admin and not banned

def main() -> Void
  puts(allowed?(true, false))
end
```

## if y case {#if-and-case}

Usa `if` para una pregunta de sí o no. Usa `case` para un enum, un `Result`, o tres o más ramas sobre un mismo valor:

```agentica {mode="check"}
# bad
def size_name(n: Int) -> String
  if n == 0
    "empty"
  elsif n == 1
    "one"
  else
    "many"
  end
end

def main() -> Void
  puts(size_name(3))
end
```

```agentica {mode="check"}
# good
def size_name(n: Int) -> String
  case n
    0 -> "empty"
    1 -> "one"
    _ -> "many"
  end
end

def main() -> Void
  puts(size_name(3))
end
```

Usa un enum para los estados en lugar de pasar códigos numéricos:

```agentica {mode="check"}
# bad
def color_name(code: Int) -> String
  if code == 0
    return "red"
  elsif code == 1
    return "green"
  end

  "unknown"
end

def main() -> Void
  puts(color_name(1))
end
```

```agentica {mode="check"}
# good
enum Color
  Red
  Green
end

def color_name(color: Color) -> String
  case color
    Color.Red -> "red"
    Color.Green -> "green"
  end
end

def main() -> Void
  puts(color_name(Color.Green))
end
```

Lista cada variante de un enum pequeño en `case` y deja fuera el `_`, para que una variante nueva falle en la comprobación allí donde hay que tratarla. Un `_` está bien cuando muchas variantes comparten un mismo resultado:

```agentica {mode="check"}
# bad
enum Shape
  Dot
  Circle(Int)
end

def area(shape: Shape) -> Int
  case shape
    Shape.Circle(r) -> r * r * 3
    _ -> 0
  end
end

def main() -> Void
  puts(area(Shape.Circle(2)))
end
```

```agentica {mode="check"}
# good
enum Shape
  Dot
  Circle(Int)
end

def area(shape: Shape) -> Int
  case shape
    Shape.Circle(r) -> r * r * 3
    Shape.Dot -> 0
  end
end

def main() -> Void
  puts(area(Shape.Circle(2)))
end
```

Dejar fuera una variante sin `_` no compila:

```agentica {expect="CHECK-NON-EXHAUSTIVE-CASE"}
# bad
enum Shape
  Dot
  Circle(Int)
end

def area(shape: Shape) -> Int
  case shape
    Shape.Circle(r) -> r * r * 3
  end
end

def main() -> Void
  puts(area(Shape.Dot))
end
```

## Pipes {#pipes}

Usa un pipe para dos o más pasos `|>` sobre un mismo valor. Empieza con el valor, y pon un paso por línea dentro de paréntesis (`agentica fmt` lo hace, y pone una línea vacía después de cualquier sentencia que ocupa varias líneas):

```agentica {mode="check"}
# good
def shout(text: String) -> String = text.upcase

def wrap(text: String, mark: String) -> String = "#{mark}#{text}#{mark}"

def banner(text: String) -> String
  (
    text
    |> shout()
    |> wrap("*")
    |> wrap(" ")
  )
end

def main() -> Void
  puts(banner("hi"))
end
```

Un paso es una llamada simple: `shout(text)`, no `text |> shout()`. Tres llamadas anidadas en primera posición son un pipe que empieza por la más interna: `wrap(shout(trim(text)), "*")` es `trim(text) |> shout() |> wrap("*")`. Dos llamadas anidadas se quedan simples. Un paso puede nombrar un método del valor, y un encadenamiento de métodos de tres o más pasos que pasa lambdas es un pipe de este tipo: `xs.map(->(x) { x * 2 }).select(->(x) { x > 2 }).sum` es `xs |> map(->(x) { x * 2 }) |> select(->(x) { x > 2 }) |> sum()`, un paso por línea. Un integrado nunca va en un pipe con su tipo; escribe el método:

```agentica {expect="CHECK-PIPE-METHOD"}
# bad
def main() -> Void
  puts("x" |> String.upcase())
end
```

## Errores {#errors}

Una función que puede fallar devuelve un `Result` y propaga los errores con `try`. Usa una forma que detenga el programa, como `to_i!`, solo cuando un fallo es un error de programación, y di por qué en un comentario. Un valor que puede faltar, sin error que informar, es un [Optional](/library/data-structures/optional/#optional-or-result) (`some(x)` o `none`), no un `Result`:

```agentica {mode="check"}
# bad
def double_text(text: String) -> Int = text.to_i! * 2

def main() -> Void
  puts(double_text("21"))
end
```

```agentica {mode="check"}
# good
def double_text(text: String) -> Result[Int]
  n = try text.to_i
  ok(n * 2)
end

def main() -> Void
  case double_text("21")
    ok(n) -> puts(n)
    error(e) -> IO.warn(e.message)
  end
end
```

Escribe el texto de error en minúsculas, sin punto final, e incluye el valor incorrecto (`error("port out of range: 70000")`). Trata los errores en el borde del programa, como `main` o un handler de solicitudes. Un parser devuelve un `Result[T]`, no una estructura con un campo `valid` o `refused`:

```agentica {mode="check"}
# good
def parse_port(text: String) -> Result[Int]
  n = try text.to_i
  return error("port out of range: #{n}") if n < 1 or n > 65535

  ok(n)
end

def main() -> Void
  case parse_port("70000")
    ok(n) -> puts("port #{n}")
    error(e) -> IO.warn(e.message)
  end
end
```

Un fallo por el que el llamador puede decidir recibe una [clase](/library/errors/error/#kinds), y el llamador comprueba la clase con `is_a?` o lee `e.code`, nunca el texto del mensaje:

```agentica {mode="check"}
# bad
def main() -> Void
  r: Result[Int] = error("unique failed: 19")
  case r
    ok(n) -> puts(n)
    error(e) if e.message.start_with?("unique failed") -> puts("duplicate")
    error(e) -> IO.warn(e.message)
  end
end
```

```agentica {mode="check"}
# good
def main() -> Void
  r: Result[Int] = error("unique failed", kind: "db.constraint", code: 19)
  case r
    ok(n) -> puts(n)
    error(e) if e.is_a?("db.constraint") -> puts("duplicate")
    error(e) -> IO.warn(e.message)
  end
end
```

Una firma, un campo de estructura o un alias de tipo que declara `Result[Result[T]]` u `Optional[Optional[T]]` suele tener una capa de más: usa `try` sobre el valor interno para que quede un solo `Result`, o dale al fallo interno un error propio. Deja las dos capas solo cuando significan cosas distintas. Un anidamiento que hace un genérico, como `task.await` de una tarea que devuelve un `Result`, está bien.

## Texto y colecciones {#text-and-collections}

Construye el texto con interpolación, no uniendo piezas con `+` y `.to_s`. Para partir un texto largo, están bien unas pocas piezas `+` del tamaño de una frase entre paréntesis. Usa un heredoc para un texto de varias líneas:

```agentica {mode="check"}
# bad
def line(name: String, count: Int) -> String = name + ": " + count.to_s + " items"

def main() -> Void
  puts(line("cart", 3))
end
```

```agentica {mode="check"}
# good
def line(name: String, count: Int) -> String = "#{name}: #{count} items"

def help() -> String
  <<~TEXT
    usage: tool FILE
    prints the lines of FILE
  TEXT
end

def main() -> Void
  puts(line("cart", 3))
  puts(help())
end
```

Un `String` que crece con `+` en un bucle se copia en cada iteración, así que el bucle es cuadrático: haz `push` de las piezas en una `List` y luego `join` una vez, después del bucle.

Usa una `List` para el orden, un `Set` para la pertenencia, un `Map` para buscar por clave, y una estructura para un registro con campos conocidos.

## Efectos {#effects}

Agentica no tiene monkey patching y una función no es un valor, pero una lambda sí lo es, así que una prueba cambia un efecto (la lectura de un archivo, el reloj, una llamada HTTP, un número aleatorio) mediante una estructura de campos `Fn`: el registro de efectos. Construye el real una vez, al arrancar, a partir de la configuración; una prueba construye otra. El comprobador se asegura de que ambos tengan la misma forma. El compilador lo hace con `Workspace` (`compiler/modules/workspace.agc`), que `io/host.agc` construye y `app/` pasa. Hace el papel de un behaviour más un mock en otros lenguajes. Cuando un servidor real en `localhost` puerto 0 es igual de simple, úsalo en lugar de simular la red.

```agentica {mode="check"}
struct Effects
  read_file: Fn[String, Result[String]]
  now: Fn[Int]
end

def real_effects() -> Effects
  Effects(read_file: ->(path: String) { File.read_text(path) }, now: -> { Time.now_ms() })
end

def banner(effects: Effects, path: String) -> Result[String]
  name = try effects.read_file.call(path)
  ok("#{name.strip} at #{effects.now.call()}")
end

def main() -> Void
  Test.run([
    Test.test("banner reads the name and the clock") do
      fake = Effects(read_file: ->(_path) { ok("agentica\n") }, now: -> { 42 })
      Test.eq(banner(fake, "name.txt"), ok("agentica at 42"))
    end,
  ])
end
```

## Comprueba tu código {#check-your-code}

`agentica fmt` corrige la disposición y `agentica check` rechaza lo que siempre es un error. `agentica lint` sugiere el resto de esta guía que la sintaxis deja ver, y nunca hace fallar la compilación salvo que pases `--strict` (ver [Sugerir cambios de estilo](/cli/#suggest-style-changes)). Sus reglas, cada una con la parte de la guía de la que viene:

- `LINT-PRIVATE-DOC` y `LINT-REPEATED-QUALIFIED-NAME`: [Archivos y documentación](#files-and-docs).
- `LINT-IF-CHAIN`: [if y case](#if-and-case).
- `LINT-NEGATED-ELSE` y `LINT-BOOL-COMPARE`: [Nombres](#naming) y [Funciones](#functions).
- `LINT-SINGLE-PIPE`, `LINT-NESTED-CALL` y `LINT-LAMBDA-CHAIN`: [Pipes](#pipes).
- `LINT-TO-S-CONCAT` y `LINT-STRING-APPEND-IN-LOOP`: [Texto y colecciones](#text-and-collections).
- `LINT-NESTED-WRAPPER`: [Errores](#errors).
