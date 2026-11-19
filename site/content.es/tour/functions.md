---
title: Funciones
weight: 6
description: Define funciones, devuelve valores, recursión y valores de función.
source_hash: "c5be02fbccfd"
---

## Define una función {#define-a-function}

`def` define una función. Cada parámetro y el resultado necesitan un tipo. Una función cuyo cuerpo es un solo valor se escribe en una línea, después de `=`; un cuerpo más largo va en las líneas entre la firma y `end` (ver `return` y Funciones de una línea más abajo).

```agentica
def greet(name: String) -> String = "Hello, #{name}!"

def main() -> Void
  puts(greet("Ana"))
end
```

```output
Hello, Ana!
```

Las llamadas siempre usan paréntesis, también sin argumentos: `main()`, `puts("hi")`. Los argumentos se dan por posición o por nombre, y los parámetros finales pueden tener valores predeterminados (ver más abajo).

## return {#return}

El valor de una función es su última expresión. Cuando la última sentencia es un `if` con `else`, o un `case`, el valor es la última expresión de la rama que se ejecuta. `return` sale de la función antes de tiempo, a menudo como guarda:

```agentica
def max(a: Int, b: Int) -> Int
  return a if a > b

  b
end

def sign(n: Int) -> String
  if n > 0
    "plus"
  elsif n < 0
    "minus"
  else
    "zero"
  end
end

def main() -> Void
  puts(max(3, 9))
  puts(sign(-2))
end
```

```output
9
minus
```

Cada camino debe dar un valor. Un `if` sin `else`, un bucle o una asignación al final no dan ninguno, y tampoco una llamada a una función `Void` como `puts`; por eso esto es un error del comprobador:

```agentica {expect="CHECK-MISSING-RETURN"}
def sign(n: Int) -> String
  if n > 0
    "plus"
  end
end

def main() -> Void
  puts(sign(2))
end
```

Una función `Void` no da un valor: su última expresión es una sentencia como cualquier otra.

## Funciones de una línea {#one-line-functions}

Una función cuyo cuerpo es un solo valor se puede escribir en una línea, con `=` después del tipo del resultado. Es lo mismo que un `def` cuyo cuerpo es ese valor.

```agentica
def double(n: Int) -> Int = n * 2

def label(name: String, count: Int = 1) -> String = "#{count} #{name}"

def main() -> Void
  puts(double(4))
  puts(label("apple"))
end
```

```output
8
1 apple
```

El valor empieza en la línea de `=`; puede seguir en más líneas, como cualquier expresión: dentro de paréntesis o de un bloque, o en una línea siguiente que empiece con `.name`. El tipo del resultado sigue siendo obligatorio. Una función `Void` no tiene un valor que dar, así que no puede usar esta forma, y tampoco `case` ni `if`, que son sentencias. Las funciones de una línea pueden ir una tras otra sin línea vacía entre ellas, como pueden las constantes; junto a cualquier otra declaración sigue haciendo falta la línea vacía, salvo justo después de un import, como en toda declaración. `agentica fmt` elige entre las dos formas ([Formato](/cli/#format)). En un bloque `extern`, `= "name"` después de una firma es, en cambio, el nombre C de la función (ver [Código nativo](/library/io-and-system/native/)).

## Funciones Void {#void-functions}

Una función que no da nada devuelve `Void`. Termina en su última línea, o en un `return` sin valor.

```agentica
def report(count: Int) -> Void
  if count == 0
    puts("nothing")
    return
  end

  puts("#{count} items")
end

def main() -> Void
  report(0)
  report(3)
end
```

```output
nothing
3 items
```

## Orden y recursión {#order-and-recursion}

Las funciones se pueden llamar antes de definirlas, y pueden llamarse a sí mismas.

```agentica
def main() -> Void
  puts(factorial(5))
end

def factorial(n: Int) -> Int
  return 1 if n <= 1

  n * factorial(n - 1)
end
```

```output
120
```

Una llamada que es todo el valor de un `return`, o la última expresión que da el valor de la función, reutiliza el frame de quien llama. Las demás llamadas cuentan para el límite de 10000 llamadas anidadas; una llamada a un integrado no usa frame. Los límites de anidamiento del código fuente (`PARSE-TOO-DEEP`, `CHECK-TOO-DEEP`) están en la [referencia del lenguaje](/reference/).

## Varios resultados {#many-results}

Una función devuelve un valor. Para devolver varios, devuelve una [estructura](/tour/structs/).

```agentica
struct MinMax
  min: Int
  max: Int
end

def min_max(xs: List[Int]) -> MinMax
  sorted = xs.sort
  MinMax(min: sorted[0], max: sorted[sorted.size - 1])
end

def main() -> Void
  result = min_max([4, 1, 9, 3])
  puts("#{result.min} to #{result.max}")
end
```

```output
1 to 9
```

## Valores de función {#function-values}

`&name` es una función como valor. Su tipo es `Fn[...]`: los tipos de los parámetros, y después el tipo del resultado. Llámala con `.call(...)`. Un integrado con una sola forma también es un valor: `&Time.now_ms` es `Fn[Int]`, y un método toma primero su receptor, así que `[1, 2].map(&Int.to_s)` es `["1", "2"]`. Un integrado con varias formas o con una regla propia, como `&List.map`, necesita un bloque.

```agentica
def double(n: Int) -> Int = n * 2

def apply(f: Fn[Int, Int], value: Int) -> Int = f.call(value)

def main() -> Void
  f: Fn[Int, Int] = &double
  puts(f.call(21))
  puts(apply(&double, 5))
  puts([1, 2, 3].map(&double))
end
```

```output
42
10
[2, 4, 6]
```

`Fn[Void]` es una función sin parámetros que no da nada. Los valores de función pueden estar en listas, mapas y campos de estructura.

Una función en un campo de estructura se llama con el nombre del campo, como un método: `counter.next(1)` es `counter.next.call(1)`. `counter.next` sin paréntesis sigue leyendo la función. Solo un campo de tipo `Fn` se puede llamar así; cualquier otro nombre es `CHECK-UNKNOWN-METHOD`, porque las estructuras no tienen métodos. Un campo llamado `to_s` o `inspect` que guarda una función tiene prioridad sobre el método de ese nombre.

```agentica
struct Counter
  next: Fn[Int, Int]
end

def succ(n: Int) -> Int = n + 1

def main() -> Void
  counter = Counter(next: &succ)
  puts(counter.next(counter.next(1)))
end
```

```output
3
```

Los [bloques](/tour/blocks/) son la forma corta de escribir un valor de función en el lugar donde lo usas.

## Encadenar llamadas con |> {#chain-calls-with-}

`x |> f(a)` significa `f(x, a)`: el valor de la izquierda pasa a ser el primer argumento.

```agentica
def parse(text: String) -> Result[Int] = text.to_i

def validate(n: Int) -> Result[Int]
  return error("negative") if n < 0

  ok(n)
end

def add(a: Int, b: Int) -> Int = a + b

def load(text: String) -> Result[Int]
  (
    text.strip
    |> try parse()
    |> validate()
  )
end

def main() -> Void
  puts(1 |> add(2) |> add(3))
  puts(load(" 7 ").inspect)
  puts(load("-3").inspect)
  total = (
    10
    |> add(1)
    |> add(100)
  )

  puts(total)
end
```

```output
6
ok(7)
error("negative")
111
```

- El lado derecho debe ser una llamada con paréntesis. Un encadenamiento de varias líneas va entre paréntesis, como `total` arriba.
- Puede empezar con `try`: `x |> try f()` significa `try f(x)`.
- Un paso puede nombrar un método del valor, que luego se llama sobre él: `xs |> map(->(x) { x * 2 }) |> sum()` es `xs.map(->(x) { x * 2 }).sum`. Una función del programa con el mismo nombre que un método tiene prioridad.
- Un integrado con forma de método se escribe con el nombre del método, no con su tipo: `s |> strip()` o `s.strip`, no `s |> String.strip()` (`CHECK-PIPE-METHOD`).

```agentica {expect="CHECK-PIPE-METHOD"}
def main() -> Void
  s = " hi "
  puts(s |> String.strip())
end
```

## Valores predeterminados de parámetros {#default-parameter-values}

Un parámetro puede terminar en `= value`. Una llamada puede omitirlo.

- Un valor predeterminado es una constante: un número, una cadena sin `#{...}`, los bytes de esa cadena (`body: Bytes = "".bytes`), `true`, `false`, `nil`, `none`, `[]`, `{}` o una variante sin payload, como `Level.Info`. Una estructura creada sin argumentos, `options: Options = Options()`, también es un valor predeterminado cuando cada campo de `Options` tiene uno. El nombre de una constante también es un valor predeterminado cuando su valor es uno de estos, como en `limit: Int = LIMIT` o `Limits.LIMIT` (se usa el valor en lugar del nombre, también para quien llama desde otro módulo). Cualquier otra cosa, como `some(1)` o una constante como `SUM = 1 + 2`, es `CHECK-DEFAULT-VALUE`. Cada llamada recibe su propio `[]`, `{}` o estructura.
- Los parámetros con valor predeterminado van al final (`CHECK-DEFAULT-ORDER`). La excepción es un último parámetro `Fn`, que se llena con un bloque.
- Los argumentos llenan los parámetros de izquierda a derecha. Un número incorrecto de argumentos es `CHECK-ARITY`, como `expects 1 to 2 arguments`.

```agentica
def join(words: List[String], sep: String = ", ") -> String = words.join(sep)

def each_line(path: String, timeout_ms: Int = 1000, f: Fn[String, Void]) -> Void
  f.call("#{path} after #{timeout_ms} ms")
end

def show(line: String) -> Void
  puts(line)
end

def main() -> Void
  puts(join(["a", "b"]))
  puts(join(["a", "b"], "-"))
  each_line("a.txt") do |line| puts(line) end

  each_line("b.txt", 50, &show)
end
```

```output
a, b
a-b
a.txt after 1000 ms
b.txt after 50 ms
```

Un valor predeterminado puede nombrar una constante, así un solo valor sirve a muchas funciones:

```agentica
LIMIT = 2

def first(words: List[String], count: Int = LIMIT) -> List[String] = words.take(count)

def main() -> Void
  puts(first(["a", "b", "c"]))
  puts(first(["a", "b", "c"], 3))
end
```

```output
["a", "b"]
["a", "b", "c"]
```

```agentica {expect="CHECK-DEFAULT-VALUE"}
def next_id() -> Int = 1

def label(id: Int = next_id()) -> String = "item #{id}"

def main() -> Void
  puts(label())
end
```

## Argumentos con nombre {#named-arguments}

Cualquier argumento se puede dar con el nombre de su parámetro, `name: value`. Así, una llamada puede cambiar solo uno de los valores predeterminados y dejar los anteriores:

```agentica
def check(name: String, runs: Int = 100, seed: Int = 0, verbose: Bool = false) -> String
  "#{name}: #{runs} runs, seed #{seed}, verbose #{verbose}"
end

def main() -> Void
  puts(check("sort", verbose: true))
  puts(check("sort", 200, seed: 7))
  puts(check(seed: 1, name: "map"))
  puts(["a", "b"].join(separator: "-"))
end
```

```output
sort: 100 runs, seed 0, verbose true
sort: 200 runs, seed 7, verbose false
map: 100 runs, seed 1, verbose false
a-b
```

- Los argumentos posicionales van primero; un argumento posicional después de uno con nombre es `PARSE-UNEXPECTED-TOKEN`. Los argumentos con nombre pueden ir en cualquier orden y se ejecutan en el orden en que están escritos.
- Un nombre que no es un parámetro es `CHECK-UNKNOWN-ARGUMENT`, un parámetro dado dos veces (por nombre, o por posición y por nombre) es `CHECK-REPEATED-ARGUMENT`, y un parámetro sin valor predeterminado y sin argumento es `CHECK-MISSING-ARGUMENT`.
- Un bloque al final llena el parámetro `Fn`: `each_line("a.txt", timeout_ms: 50) do |line| ... end`, `xs.reduce(initial: 0) do |acc, x| ... end`. Cuando otros argumentos tienen nombre, un valor de función para ese parámetro se pasa como bloque o con nombre (`f: &show`), no por posición.
- Los integrados y las funciones de `std/` también admiten nombres. Un valor de función no: su tipo `Fn` no tiene nombres, así que `f.call(1)` sigue siendo posicional.

```agentica {expect="CHECK-UNKNOWN-ARGUMENT"}
def label(id: Int, prefix: String = "item") -> String = "#{prefix} #{id}"

def main() -> Void
  puts(label(1, prefx: "row"))
end
```

## Parámetros de tipo {#type-parameters}

Una función puede tener parámetros de tipo después de su nombre, así una sola definición funciona con cualquier tipo. La llamada no da argumentos de tipo: el comprobador los encuentra a partir de los argumentos.

```agentica
def first_or[T](xs: List[T], fallback: T) -> T
  return fallback if xs.length == 0

  xs[0]
end

def max_by[T](xs: List[T], key: Fn[T, Int]) -> Optional[T]
  return none if xs.length == 0

  best = xs[0]
  best_key = key.call(best)
  for x in xs
    k = key.call(x)
    if k > best_key
      best = x
      best_key = k
    end
  end

  some(best)
end

def main() -> Void
  puts(first_or(["ana", "ben"], "none"))
  puts(first_or([], 0))

  longest = max_by(["pear", "fig", "banana"]) do |w| w.length end

  puts(longest.unwrap_or("none"))
end
```

```output
ana
0
banana
```

En `first_or(["ana", "ben"], "none")` el tipo `T` es `String`, por el primer argumento. En `first_or([], 0)` la lista vacía no dice nada, así que `T` es `Int` por el `0`, y la lista se comprueba al final. El tipo del resultado de la llamada también puede fijar `T`, como en `xs: List[Int] = empty_of()` para `def empty_of[T]() -> List[T]`. El bloque va al final: sus tipos de parámetro vienen de `T` (o, cuando `T` aún está abierto, de cómo se usan en el bloque), y su resultado fija los parámetros de tipo que solo menciona el resultado del `Fn`. Un parámetro que sigue abierto es `CHECK-ENUM-TYPE-INFERENCE`. Un parámetro cuyo tipo tiene `T` toma un valor predeterminado como cualquier otro, como `rest: List[T] = []` o `extra: Optional[T] = none`; una llamada debe mostrar igualmente `T` mediante otro argumento o por su tipo esperado.

```agentica {expect="CHECK-ENUM-TYPE-INFERENCE"}
def empty_of[T]() -> List[T] = []

def main() -> Void
  xs = empty_of()
end
```

Dentro del cuerpo, `T` puede ser cualquier tipo, así que el cuerpo solo puede guardarlo, devolverlo y pasarlo. Comparar, sumar, imprimir o leer un campo de un valor `T` es un error, como `CHECK-TYPE-MISMATCH` para `==`. Para actuar sobre los elementos, recibe una función, como hace `max_by` con `key`. `JSON.encode` y `JSON.from` son la excepción: funcionan con un valor `T`, y cada llamada comprueba que el tipo que da a `T` se puede escribir como JSON ([JSON](/library/text-and-data/json/)).

```agentica {expect="CHECK-TYPE-MISMATCH"}
def same[T](a: T, b: T) -> Bool = a == b

def main() -> Void
  puts(same(1, 1))
end
```

Un parámetro de tipo es un nombre de tipo que ninguna estructura, enum o alias del archivo tiene (`CHECK-REDEFINED-NAME`). `&first_or` es un valor de función solo donde el tipo `Fn` fija cada parámetro de tipo, como en `f: Fn[List[Int], Int, Int] = &first_or`. Una función genérica se puede exportar e importar como cualquier otra.

## Sin sobrecarga {#no-overloading}

Un nombre tiene una sola definición: no hay sobrecarga ni métodos en tus propios tipos. Usa un valor predeterminado en lugar de una segunda versión.
