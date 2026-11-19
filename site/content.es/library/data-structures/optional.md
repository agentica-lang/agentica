---
title: Optional
weight: 8
description: Un valor que puede faltar, con some y none.
source_hash: "ce5dad8f1158"
---

`Optional[T]` es `some(value)` o `none`. Úsalo para un valor que puede faltar: un campo de estructura, un parámetro, un valor devuelto, un elemento de una lista o un valor de un mapa. `map.get(key)` y `text.index_of(part)` dan uno.

```agentica
struct User
  name: String
  age: Optional[Int]
end

def main() -> Void
  users = [User(name: "Ana", age: some(31)), User(name: "Bo", age: none)]
  for user in users
    case user.age
      some(n) -> puts("#{user.name} is #{n}")
      none -> puts("#{user.name} gave no age")
    end
  end
end
```

```output
Ana is 31
Bo gave no age
```

Un `case` necesita las dos ramas, `some(n) ->` y `none ->`, o un `_` final. Una rama con un literal dentro, como `some(0) ->`, puede fallar, así que no cubre nada: añade `some(n) ->` o `_` después de ella. [Patrones dentro de patrones](/tour/enums-and-case/#patterns-inside-patterns) muestra un Optional dentro de un enum de usuario o de un `Result`. `==` compara dos Optional cuyos elementos tienen `==`: `age == none`, `age == some(31)`. Un Optional se imprime como `some(31)` o `none`. Un campo o un parámetro puede tener `none` como predeterminado: `port: Optional[Int] = none`. En [JSON](/library/text-and-data/json/#optional-values), `none` es `null` (una clave que falta al decodificar) y `some(x)` es `x`.

## Campos, parámetros, elementos y genéricos {#fields-parameters-items-and-generics}

`Optional[T]` va donde va un tipo, `T` puede ser un parámetro de tipo, y los Optional pueden anidarse. Un parámetro o campo toma `none` como predeterminado, y quien llama lo omite o pasa `some(x)`.

```agentica
struct Config
  host: String
  port: Optional[Int] = none
end

struct Box[T]
  item: Optional[T]
end

def greet(name: String, title: Optional[String] = none) -> String = "#{title.unwrap_or("Mx")} #{name}"

def first_or_none[T](xs: List[T]) -> Optional[T]
  return none if xs.length == 0

  some(xs[0])
end

def main() -> Void
  puts(Config(host: "localhost"))
  puts(Box(item: some(3)))
  puts(greet("Ana"))
  puts(greet("Ana", some("Dr")))
  puts(first_or_none(["a", "b"]))
  empty: List[Int] = []
  puts(first_or_none(empty))
  scores: Map[String, Optional[Int]] = {"ana": some(9), "bo": none}
  items: List[Optional[Int]] = [some(1), none, some(3)]
  puts(scores)
  puts(items.reduce(0) do |sum, o| sum + o.unwrap_or(0) end)
end
```

```output
Config(host: "localhost", port: none)
Box(item: some(3))
Mx Ana
Dr Ana
some("a")
none
{"ana": some(9), "bo": none}
4
```

## Búsquedas {#lookups}

`map.get(key)` y `text.index_of(part)` dan un Optional: `some` cuando la clave o el texto están, `none` cuando no están. Elige la forma de leerlo: `unwrap_or` para un predeterminado, `case` para actuar en cada caso, `unwrap!` solo cuando `none` sería un error.

```agentica
def main() -> Void
  stock = {"apple": 3, "pear": 0}
  puts(stock.get("apple").unwrap_or(0))
  puts(stock.get("kiwi").unwrap_or(0))
  case "hello world".index_of("wor")
    some(i) -> puts("found at #{i}")
    none -> puts("not found")
  end
end
```

```output
3
0
found at 6
```

## some {#some}

```signature
some(value: T) -> Optional[T]
```

```agentica
def main() -> Void
  puts(some(3))
  puts(some("yes"))
end
```

```output
some(3)
some("yes")
```

## none {#none}

```text
none -> Optional[T]
```

El tipo viene de una anotación, de un tipo devuelto, de un parámetro o de un campo. Un `x = none` suelto es `CHECK-OPTIONAL-TYPE`.

```agentica
def find(names: List[String], wanted: String) -> Optional[Int]
  index = 0
  for name in names
    return some(index) if name == wanted

    index += 1
  end

  none
end

def main() -> Void
  puts(find(["a", "b"], "b"))
  puts(find(["a", "b"], "z"))
end
```

```output
some(1)
none
```

## Optional.unwrap_or {#optionalunwrap_or}

```signature
Optional.unwrap_or(optional: Optional[T], default: T) -> T
```

Da el valor, o el predeterminado para `none`. El predeterminado siempre se calcula.

```agentica
def main() -> Void
  age: Optional[Int] = none
  puts(age.unwrap_or(0))
  puts(some(7).unwrap_or(0))
end
```

```output
0
7
```

## Optional.unwrap! {#optionalunwrap}

```signature
Optional.unwrap!(optional: Optional[T]) -> T
```

Da el valor, o detiene el programa con `RUNTIME-UNWRAP-NONE`.

```agentica
def main() -> Void
  puts(some(5).unwrap! * 2)
end
```

```output
10
```

## Optional.map {#optionalmap}

```signature
Optional.map(optional: Optional[T], block: Fn[T, U]) -> Optional[U]
```

Da `some` con el valor del bloque, o `none` sin llamar al bloque.

```agentica
def main() -> Void
  age: Optional[Int] = none
  puts(some(20).map do |n| n + 1 end)
  puts(age.map do |n| n + 1 end)
end
```

```output
some(21)
none
```

## Optional.some? y Optional.none? {#optionalsome-and-optionalnone}

```signature
Optional.some?(optional: Optional[T]) -> Bool
Optional.none?(optional: Optional[T]) -> Bool
```

```agentica
def main() -> Void
  age: Optional[Int] = none
  puts(some(1).some?)
  puts(age.none?)
end
```

```output
true
true
```

## Optional.to_result {#optionalto_result}

```signature
Optional.to_result(optional: Optional[T], message: String) -> Result[T]
```

Da `ok(value)`, o `error(message)` para `none`, así `try` puede pasar el error hacia arriba.

```agentica
def first_even(numbers: List[Int]) -> Optional[Int]
  for n in numbers
    return some(n) if n % 2 == 0
  end

  none
end

def half(numbers: List[Int]) -> Result[Int]
  n = try first_even(numbers).to_result("no even number")
  ok(n / 2)
end

def main() -> Void
  puts(half([3, 8]))
  puts(half([3, 5]))
end
```

```output
ok(4)
error("no even number")
```

## Optional o Result {#optional-or-result}

Usa un Optional cuando no tener valor es normal y no necesita un motivo: una búsqueda que no encuentra nada, un ajuste que quien llama dejó sin dar. Usa un [Result](/tour/results-and-try/) cuando algo falló y quien llama necesita saber por qué, como un análisis o una lectura de archivo. `to_result("message")` convierte el primero en el segundo cuando un valor que falta es un error para quien llama. `List.find` y `Lazy.find` dan un Result con `error("not found")`, no un Optional.
