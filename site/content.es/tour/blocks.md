---
title: Bloques
weight: 7
description: Bloques con do ... end, closures y paso de bloques a tus propias funciones.
source_hash: "544a977d1a82"
---

## Un bloque {#a-block}

Un bloque es una función pequeña que se escribe justo después de una llamada, entre `do` y `end`. Sus parámetros van entre barras.

```agentica
def main() -> Void
  doubled = [1, 2, 3].map do |x| x * 2 end

  puts(doubled)
end
```

```output
[2, 4, 6]
```

La última expresión es el valor del bloque. Un bloque corto cabe en una línea:

```agentica
def main() -> Void
  evens = [1, 2, 3, 4].select do |x| x % 2 == 0 end
  puts(evens)
end
```

```output
[2, 4]
```

## Llaves {#braces}

Una llamada sin argumentos puede dar su bloque entre llaves, en una línea o en varias. Una llamada con argumentos usa `do ... end`. Después del `end` de un bloque `do` no se puede encadenar nada (`CHECK-CHAIN-AFTER-END`): para llamar a un método del resultado, pasa una [lambda](#lambdas) y usa un pipe, `xs |> map(->(x) { x * x }) |> sum()`, escribe el bloque entre llaves, `xs.map { |x| x * x }.sum`, o primero dale un nombre al resultado.

```agentica
def main() -> Void
  squares = [1, 2, 3].map { |x| x * x }
  puts(squares)
end
```

```output
[1, 4, 9]
```

## Bloques que no devuelven nada {#blocks-that-return-nothing}

`each` ejecuta el bloque para cada elemento.

```agentica
def main() -> Void
  ["tea", "cake"].each do |item| puts("I like #{item}") end
end
```

```output
I like tea
I like cake
```

## Dos parámetros {#two-parameters}

`reduce` pasa el valor acumulado y el siguiente elemento.

```agentica
def main() -> Void
  total = [1, 2, 3, 4].reduce(0) do |sum, x| sum + x end
  puts(total)
end
```

```output
10
```

## Closures {#closures}

Un bloque puede leer las variables que lo rodean. Ve sus valores en el momento en que se crea el bloque.

```agentica
def main() -> Void
  rate = 3
  scaled = [1, 2].map do |x| x * rate end
  puts(scaled)
end
```

```output
[3, 6]
```

Un bloque no puede asignar a una variable externa. Construye el valor con `map` o `reduce`, o usa un bucle `for`:

```agentica {expect="CHECK-CAPTURED-ASSIGNMENT"}
def main() -> Void
  total = 0
  [1, 2].each do |x| total += x end
end
```

## return en un bloque {#return-in-a-block}

`return` dentro de un bloque sale solo del bloque, con ese valor:

```agentica
def main() -> Void
  labels = [5, 50].map do |n|
    return "big" if n > 10

    "small"
  end

  puts(labels)
end
```

```output
["small", "big"]
```

## Pasa un bloque a tu propia función {#pass-a-block-to-your-own-function}

El último parámetro de tu función debe ser un `Fn`. El bloque se convierte en ese argumento.

```agentica
def twice(value: Int, f: Fn[Int, Int]) -> Int = f.call(f.call(value))

def main() -> Void
  result = twice(3) do |n| n + 10 end
  puts(result)
end
```

```output
23
```

Una llamada sin otro argumento quita el `()` vacío antes de su bloque, también en tu propia función. Sin bloque, deja el `()`: un nombre suelto nunca es una llamada.

```agentica
def answer(f: Fn[Int]) -> Int = f.call()

def main() -> Void
  puts(answer do 42 end)
  puts(answer { 7 })
end
```

```output
42
7
```

## Lambdas {#lambdas}

Un bloque siempre va después de una llamada. Un valor de función propio, para guardarlo en una variable, un campo o una lista, es una lambda: `->(x) { ... }`, con el cuerpo entre llaves en una línea o en varias. Sus tipos de parámetro vienen del tipo `Fn` que recibe, de anotaciones, o de cómo se usan en el cuerpo: en `->(x) { x + 1 }`, el `+ 1` hace que `x` sea un `Int`. Cuando los usos no dejan un solo tipo, como `x * 2` (un `Int`, o un `String` para repetirlo), anota: `->(x: Int) { x * 2 }` (si no, `CHECK-BLOCK-TYPE`). Una lambda sin parámetros quita los paréntesis: `-> { 42 }`.

```agentica
def main() -> Void
  step = 2
  add_step: Fn[Int, Int] = ->(n) { n + step }
  answer = -> { 40 }
  puts(add_step.call(answer.call()))
  puts([1, 2].map(add_step))
end
```

```output
42
[3, 4]
```

Cuando una llamada recibe un bloque, una lambda dentro de sus paréntesis es ese bloque, con sus tipos de parámetro tomados de la llamada: `xs.map(->(x) { x + 1 })` es `xs.map do |x| x + 1 end`. Un bloque `do ... end` sigue yendo después de los paréntesis. Con un [pipe](/tour/functions/) hacia métodos, las lambdas forman un encadenamiento que se lee un paso por línea:

```agentica
def main() -> Void
  xs = [1, 2, 3]
  puts(xs.map(->(x) { x * 2 }).sum)
  total = (
    xs
    |> map(->(x) { x * 2 })
    |> select(->(x) { x > 2 })
    |> sum()
  )

  puts(total)
end
```

```output
12
10
```

## Encadenamientos en varias líneas {#chains-over-several-lines}

Una línea que empieza con un punto (o `&.`, véase [Optional](/library/data-structures/optional/)) y un nombre continúa la línea anterior. Así, un encadenamiento largo de llamadas a métodos y bloques entre llaves se lee un paso por línea, sin paréntesis. Un comentario puede terminar una línea, o ir solo en una línea entre dos pasos. Una línea en blanco termina la sentencia.

```agentica
def main() -> Void
  scores = [3, 8, 5, 10, 1]
    .select { |x| x > 2 } # drop the small ones
    # then double what is left
    .map { |x| x * 2 }
    .take(3)

  puts(scores)
end
```

```output
[6, 16, 10]
```

Una línea que empieza con `..`, `...` o `|>` no continúa: pon un encadenamiento con pipes entre paréntesis.

## Anota cuando haga falta {#annotate-when-needed}

Los tipos de los parámetros vienen de la llamada. Cuando la llamada no lo indica, escribe el tipo después del nombre:

```agentica
def main() -> Void
  doubled = List.map([]) do |x: Int| x * 2 end
  puts(doubled.size)
end
```

```output
0
```

Escribe los bloques con `do ... end`. La forma `{ |x| ... }` de Ruby no existe.
