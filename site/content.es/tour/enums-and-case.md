---
title: Enums y case
weight: 11
description: Enums con y sin payload, enums genéricos y el emparejamiento de patrones con case.
source_hash: "d79f9b2eb874"
---

## Declarar un enum {#declare-an-enum}

Un enum es un tipo con un conjunto fijo de variantes. Escribe una variante con el nombre del enum delante.

```agentica
enum Color
  Red
  Green
  Blue
end

def main() -> Void
  c = Color.Green
  puts(c)
end
```

```output
Color.Green
```

## case sobre un enum {#case-on-an-enum}

`case` ejecuta la rama que coincide. Debe cubrir cada variante, o terminar con `_`.

```agentica
enum Color
  Red
  Green
  Blue
end

def name(c: Color) -> String
  case c
    Color.Red -> "red"
    Color.Green -> "green"
    Color.Blue -> "blue"
  end
end

def main() -> Void
  puts(name(Color.Blue))
end
```

```output
blue
```

Una variante que falta es un error del comprobador, así que no se te puede olvidar ningún caso:

```agentica {expect="CHECK-NON-EXHAUSTIVE-CASE"}
enum Color
  Red
  Green
end

def main() -> Void
  case Color.Red
    Color.Red -> puts("red")
  end
end
```

## Variantes con datos {#variants-with-data}

Una variante puede llevar valores. Un patrón da un nombre a cada valor.

```agentica
enum Shape
  Circle(Float)
  Rect(Float, Float)
end

def area(s: Shape) -> Float
  case s
    Shape.Circle(r) -> 3.14 * r * r
    Shape.Rect(w, h) -> w * h
  end
end

def main() -> Void
  puts(area(Shape.Circle(1.0)))
  puts(area(Shape.Rect(2.0, 3.0)))
end
```

```output
3.14
6.0
```

`_` descarta un valor (consulta [Variables](/tour/variables/)) o coincide con todas las demás variantes:

```agentica
enum Event
  Click(Int, Int)
  Key(String)
  Quit
end

def main() -> Void
  events = [Event.Click(3, 4), Event.Key("q"), Event.Quit]
  for e in events
    case e
      Event.Click(x, _) -> puts("click at x=#{x}")
      _ -> puts("other: #{e}")
    end
  end
end
```

```output
click at x=3
other: Event.Key("q")
other: Event.Quit
```

## Un case que da un valor {#a-case-that-gives-a-value}

Un `case` da un valor en tres lugares: a la derecha de una asignación, después de `return` y en la última línea de un bloque. En cualquier otro lugar es una sentencia, así que `puts(case ...)` y `1 + case ...` son errores.

Cada rama termina con una expresión, que es el valor de la rama. Una rama puede tener más líneas antes.

```agentica
enum Kind
  Big
  Small
end

def label(kind: Kind) -> String
  return case kind
    Kind.Big -> "big"
    Kind.Small -> "small"
  end
end

def main() -> Void
  r: Result[Int] = ok(3)
  text = case r
    ok(n) -> "got #{n}"
    error(message) -> "failed: #{message}"
  end

  puts(text)

  size = case text
    "got 3" ->
      base = 2
      base + 1
    _ -> 0
  end

  puts(size)

  puts(label(Kind.Small))
  numbers = [Kind.Big, Kind.Small].map do |kind|
    case kind
      Kind.Big -> 1
      Kind.Small -> 2
    end
  end

  puts(numbers)
end
```

```output
got 3
3
small
[1, 2]
```

Todas las ramas tienen un mismo tipo, y el case debe cubrir cada variante, o terminar con `_`. El tipo es la anotación de la asignación; si no hay una, es el tipo de la primera rama. Por eso escribe `x: Result[Int] = case ...` cuando la primera rama es `error(...)`, `[]` o `none`. Una rama que termina con `return`, `next` o `break` no tiene valor (`CHECK-CASE-ARM-VALUE`). Un tipo que no coincide es `CHECK-TYPE-MISMATCH` en la última expresión de la rama:

```agentica {expect="CHECK-TYPE-MISMATCH"}
def main() -> Void
  text = case 1
    1 -> "one"
    _ -> 2
  end

  puts(text)
end
```

## Enums genéricos {#generic-enums}

Un enum puede tomar un parámetro de tipo. Para un valor que puede faltar, usa el [Optional](/library/data-structures/optional/) integrado, no tu propio enum.

```agentica
enum Change[T]
  Added(T)
  Removed(T)
end

def describe(change: Change[Int]) -> String
  case change
    Change.Added(n) -> "+#{n}"
    Change.Removed(n) -> "-#{n}"
  end
end

def main() -> Void
  puts(describe(Change.Added(4)))
  puts(describe(Change.Removed(2)))
end
```

```output
+4
-2
```

## Los enums son recursivos {#enums-are-recursive}

Una variante puede contener su propio tipo de enum, como en un árbol:

```agentica
enum Expr
  Num(Int)
  Add(Expr, Expr)
end

def eval(e: Expr) -> Int
  case e
    Expr.Num(n) -> n
    Expr.Add(a, b) -> eval(a) + eval(b)
  end
end

def main() -> Void
  puts(eval(Expr.Add(Expr.Num(2), Expr.Add(Expr.Num(3), Expr.Num(4)))))
end
```

```output
9
```

## Guardas {#guards}

Una rama puede llevar una guarda: `pattern if condition ->`. La condición es un Bool y puede usar los nombres del patrón. Si es falsa, `case` sigue con la siguiente rama.

```agentica
enum Shape
  Circle(Int)
  Rect(Int, Int)
end

def size(s: Shape) -> String
  case s
    Shape.Circle(r) if r > 100 -> "big circle"
    Shape.Circle(_) -> "circle"
    Shape.Rect(w, h) if w == h -> "square"
    Shape.Rect(_, _) -> "rect"
  end
end

def main() -> Void
  puts(size(Shape.Circle(500)))
  puts(size(Shape.Rect(2, 2)))
  puts(size(Shape.Rect(2, 3)))
end
```

```output
big circle
square
rect
```

Una rama con guarda puede fallar, así que nunca cubre una variante. La rama sin guarda que va después sí la cubre, y el mismo patrón puede aparecer otra vez:

```agentica {expect="CHECK-NON-EXHAUSTIVE-CASE"}
def main() -> Void
  case Result.Ok(4)
    ok(n) if n > 0 -> puts("positive")
    error(_) -> puts("failed")
  end
end
```

## Varios patrones en una rama {#several-patterns-in-one-arm}

Separa los patrones con comas para compartir una rama. La rama se ejecuta cuando coincide cualquiera de ellos. Una rama así no vincula nombres: escribe `_` en las posiciones del payload.

```agentica
def ttl?(option: String) -> Bool
  case option
    "ex", "px" -> true
    _ -> false
  end
end

def main() -> Void
  puts(ttl?("px"))
  puts(ttl?("nx"))
end
```

```output
true
false
```

## Patrones dentro de patrones {#patterns-inside-patterns}

En una posición de payload, un patrón puede ser un literal (también un número negativo), un nombre, `_`, u otra variante, `ok(...)`, `error(...)`, `some(...)` o `none`, a cualquier profundidad.

```agentica
def describe(r: Result[Optional[Int]]) -> String
  case r
    ok(some(0)) -> "zero"
    ok(some(n)) if n < 0 -> "negative #{n}"
    ok(some(n)) -> "value #{n}"
    ok(_) -> "none"
    error(e) if e.message == "timeout" -> "timed out"
    error(_) -> "failed"
  end
end

def main() -> Void
  puts(describe(ok(some(-3))))
  puts(describe(ok(none)))
  puts(describe(error("timeout")))
end
```

```output
negative -3
none
timed out
```

Una rama sin guarda cuyas posiciones son solo nombres o `_` cubre su variante. Los patrones anidados cubren juntos lo que cubren sus variantes: `ok(ok(n))`, `ok(error(_))` y `error(_)` cubren un `Result[Result[Int]]`; una rama después de ese conjunto no se marca como inalcanzable (por ahora). Una rama con guarda o un literal como `some(0)` puede fallar, así que termina con `some(n)`, con una variante con posiciones `_`, o con `_`.

El payload de tu propia variante puede ser un [Optional](/library/data-structures/optional/), y se aplican los mismos patrones:

```agentica
enum Reading
  Value(Optional[Int])
  Missing
end

def label(r: Reading) -> String
  case r
    Reading.Value(some(0)) -> "zero"
    Reading.Value(some(n)) -> "value #{n}"
    Reading.Value(_) -> "no value"
    Reading.Missing -> "missing"
  end
end

def main() -> Void
  puts(label(Reading.Value(some(0))))
  puts(label(Reading.Value(some(5))))
  puts(label(Reading.Value(none)))
  puts(label(Reading.Missing))
end
```

```output
zero
value 5
no value
missing
```

Las ramas con `Reading.Value(some(n))` y `Reading.Value(none)` cubrirían `Reading.Value` entre las dos. Un literal nunca cubre su tipo, así que con `some(0)` en lugar de `some(n)` el case no es exhaustivo hasta que añadas `Reading.Value(_)` o `_`.

```agentica {expect="CHECK-NON-EXHAUSTIVE-CASE"}
enum Reading
  Value(Optional[Int])
  Missing
end

def main() -> Void
  case Reading.Missing
    Reading.Value(some(0)) -> puts("zero")
    Reading.Value(none) -> puts("no value")
    Reading.Missing -> puts("missing")
  end
end
```
