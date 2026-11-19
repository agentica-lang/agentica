---
title: Result
weight: 1
description: Construye y lee valores Result.
source_hash: "e1197c86f222"
---

`Result[T]` es `ok(value)` o `error(...)`, que guarda un [Error](/library/errors/error/).

## ok {#ok}

```signature
ok(value: T) -> Result[T]
ok() -> Result[Void]
```

```agentica
def main() -> Void
  puts(ok(3))
  puts(ok("yes"))
end
```

```output
ok(3)
ok("yes")
```

## error {#error}

```signature
error(message: String) -> Result[T]
error(message: String, kind: String, code: Int, details: Map[String, String], cause: Error) -> Result[T]
error(error: Error) -> Result[T]
```

Con un `String`, construye un nuevo `Error` con ese mensaje, creado en esta llamada. Los demás campos llegan como argumentos con nombre, cada uno opcional y en cualquier orden; `code` y `cause` se guardan como `some(...)` ([Error](/library/errors/error/#kinds)). Con un `Error`, guarda ese mismo `Error`, así que una rama de `case` puede pasar un error como `Result` de otro tipo. El tipo sale de una anotación, del tipo de retorno, de un parámetro o de un campo.

```agentica
def fail_now() -> Result[Int] = error("broken")

def main() -> Void
  puts(fail_now())
end
```

```output
error("broken")
```

## Result.ok? {#resultok}

```signature
Result.ok?(result: Result[T]) -> Bool
```

```agentica
def main() -> Void
  puts("1".to_i.ok?)
  puts("one".to_i.ok?)
end
```

```output
true
false
```

## Result.unwrap! {#resultunwrap}

```signature
Result.unwrap!(result: Result[T]) -> T
```

Da el valor, o detiene el programa con `RUNTIME-UNWRAP-ERROR`.

```agentica
def main() -> Void
  puts("5".to_i.unwrap! * 2)
end
```

```output
10
```

## Result.unwrap_or {#resultunwrap_or}

```signature
Result.unwrap_or(result: Result[T], default: T) -> T
```

Da el valor, o el valor predeterminado para un error. El valor predeterminado siempre se calcula.

```agentica
def main() -> Void
  puts("5".to_i.unwrap_or(0))
  puts("five".to_i.unwrap_or(0))
end
```

```output
5
0
```

## Result.message {#resultmessage}

```signature
Result.message(result: Result[T]) -> String
```

Da el `message` del error, o `""` si todo salió bien.

```agentica
def main() -> Void
  puts("five".to_i.message)
  puts("[" + "5".to_i.message + "]")
end
```

```output
cannot convert "five" to Int
[]
```
