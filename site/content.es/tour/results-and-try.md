---
title: Result y try
weight: 12
description: Devuelve errores como valores con Result, compruébalos y pásalos con try.
source_hash: "bddbb7431003"
---

## Result {#result}

Una función que puede fallar devuelve `Result[T]`. Es `ok(value)` o `error(message)`. El error guarda un registro [Error](/library/errors/error/), cuyo `message` es un `String`. Un valor que puede faltar, sin error que informar, es en cambio un [Optional](/library/data-structures/optional/#optional-or-result).

```agentica
def divide(a: Int, b: Int) -> Result[Int]
  return error("division by zero") if b == 0

  ok(a / b)
end

def main() -> Void
  puts(divide(10, 2))
  puts(divide(1, 0))
end
```

```output
ok(5)
error("division by zero")
```

## Mirar dentro de un Result {#look-inside-a-result}

```agentica
def main() -> Void
  good = "12".to_i
  bad = "x".to_i
  puts(good.ok?)
  puts(bad.ok?)
  puts(good.unwrap!)
  puts(bad.unwrap_or(0))
  puts(bad.message)
end
```

```output
true
false
12
0
cannot convert "x" to Int
```

`unwrap!` detiene el programa cuando el Result es un error:

```agentica {expect="RUNTIME-UNWRAP-ERROR"}
def main() -> Void
  _n = "x".to_i.unwrap!
end
```

## case con un Result {#case-on-a-result}

`ok(...)` y `error(...)` también funcionan como patrones. `error(e)` enlaza el `Error`: `"#{e}"` y `puts(e)` dan su mensaje, y `e.message` es el `String` en sí.

```agentica
def main() -> Void
  case "42".to_i
    ok(n) -> puts("number #{n}")
    error(message) -> puts("bad: #{message}")
  end
end
```

```output
number 42
```

## try {#try}

`try` saca el valor de un `ok`. Ante un `error`, devuelve ese error desde la función actual de inmediato. La función debe devolver un `Result`.

```agentica
def add_texts(a: String, b: String) -> Result[Int]
  x = try a.to_i
  y = try b.to_i
  ok(x + y)
end

def main() -> Void
  puts(add_texts("2", "3"))
  puts(add_texts("2", "three"))
end
```

```output
ok(5)
error("cannot convert \"three\" to Int", kind: "number.parse")
```

## Resultados sin valor {#results-with-no-value}

`Result[Void]` quiere decir "funcionó, o falló con un mensaje". Devuelve `ok()` cuando todo sale bien.

```agentica
def check_age(age: Int) -> Result[Void]
  return error("age must not be negative") if age < 0

  ok()
end

def main() -> Void
  puts(check_age(30))
  puts(check_age(-1))
end
```

```output
ok()
error("age must not be negative")
```

## Un Result se debe usar {#a-result-must-be-used}

Una llamada cuyo `Result` se descarta perdería su error, así que es `CHECK-UNUSED-RESULT`. Vale para cualquier llamada, tuya o de un integrado, y también para `Result[Void]`.

```agentica {expect="CHECK-UNUSED-RESULT"}
def check_age(age: Int) -> Result[Void]
  return error("age must not be negative") if age < 0

  ok()
end

def main() -> Void
  check_age(-1)
end
```

Trátalo con `try`, un `case` o `unwrap!`. Para descartarlo a propósito, escribe `_ =` delante de la llamada:

```agentica
def check_age(age: Int) -> Result[Void]
  return error("age must not be negative") if age < 0

  ok()
end

def main() -> Void
  _ = check_age(-1)
  case check_age(30)
    ok(_) -> puts("fine")
    error(message) -> puts(message)
  end
end
```

```output
fine
```

## Error necesita un tipo {#error-needs-a-type}

`error("...")` solo no dice de qué `Result` es. Dale un tipo, por ejemplo con una anotación:

```agentica
def main() -> Void
  r: Result[Int] = error("not ready")
  puts(r.unwrap_or(-1))
end
```

```output
-1
```

Sin la anotación, `r = error("not ready")` es el error `CHECK-RESULT-TYPE`.

## ! indica que puede detener el programa {#-means-it-can-halt}

Por convención, un nombre que termina en `!` detiene el programa si falla; un nombre que termina en `?` devuelve un `Bool`. `to_i` devuelve un Result; `to_i!` devuelve el número o detiene el programa.
