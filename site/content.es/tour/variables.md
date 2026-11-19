---
title: Variables
weight: 2
description: Crea y actualiza variables, anotaciones de tipo y alcance.
source_hash: "7d175c3388b5"
---

## Crear una variable {#create-a-variable}

La primera asignación crea una variable. Su tipo viene del valor.

```agentica
def main() -> Void
  name = "Ana"
  age = 25
  puts("#{name} is #{age}")
end
```

```output
Ana is 25
```

## Actualizar una variable {#update-a-variable}

Una asignación posterior cambia el valor, no el tipo. `+=`, `-=`, `*=`, `/=` y `%=` son formas cortas, y la variable ya debe existir.

```agentica
def main() -> Void
  count = 1
  count = count + 1
  count += 10
  puts(count)
end
```

```output
12
```

```agentica {expect="CHECK-TYPE-MISMATCH"}
def main() -> Void
  count = 1
  count = "one" # error: count is an Int
end
```

## Anotaciones de tipo {#type-annotations}

Escribe el tipo cuando el valor no lo muestre, como en una lista vacía.

```agentica
def main() -> Void
  total: Float = 0.5
  names: List[String] = []
  names = names.push("Ana")
  puts(total)
  puts(names)
end
```

```output
0.5
["Ana"]
```

## Descartar con _ {#discard-with-_}

`_` descarta un valor donde se vincula un nombre: en una asignación, una variable de `for`, un parámetro de bloque o de función, o un hueco de patrón. No vincula nada, puede repetirse y nunca entra en conflicto. Leerlo es `CHECK-UNKNOWN-NAME`.

```agentica
def load(n: Int) -> Int
  puts("load #{n}")
  n
end

def main() -> Void
  _ = load(1) # keep the call, drop its value
  for _ in 1..2 # the body does not need the number
    puts("tick")
  end

  {"a": 1, "b": 2}.each do |_, v| # drop the key
    puts(v)
  end

  case Result.Ok(3)
    ok(_) -> puts("fine") # drop the payload
    error(_) -> puts("failed")
  end
end
```

```output
load 1
tick
tick
1
2
fine
```

```agentica {expect="CHECK-UNKNOWN-NAME"}
def main() -> Void
  _ = 1
  puts(_) # error: _ cannot be read
end
```

`_: Int = x` es `PARSE-UNEXPECTED-TOKEN`, `_ = puts("x")` es `CHECK-VOID-VALUE` y `_ += 1` es `CHECK-UNKNOWN-NAME`.

## Variables sin usar {#unused-variables}

Una variable que nunca se lee es un error (`CHECK-UNUSED-VARIABLE`): quítala, o empieza su nombre con `_` si no se usa a propósito. Lo mismo vale para una variable de `for`, un parámetro de bloque y un nombre en un patrón de `case`; usa `_` ahí, como arriba. Nunca se avisa de un parámetro de función, porque el llamador depende de la firma.

Actualizar una variable no la lee: `count += 1` por sí solo deja `count` sin usar. Una variable que se asigna dos veces y se lee una vez está bien.

```agentica {expect="CHECK-UNUSED-VARIABLE"}
def main() -> Void
  total = 0
  count = 0 # error: count is only updated, never read
  for n in [1, 2]
    total += n
    count += 1
  end

  puts(total)
end
```

```agentica
def main() -> Void
  _count = 0 # kept on purpose
  puts("ok")
end
```

```output
ok
```

## Alcance {#scope}

Una variable creada dentro de un bloque (`if`, `while`, `for`, ...) deja de existir después de su `end`. Créala antes del bloque para usarla después.

```agentica
def main() -> Void
  message = "small"
  n = 12
  if n > 10
    message = "big"
  end

  puts(message)
end
```

```output
big
```

No hay sombreado: una variable nueva no puede reutilizar un nombre visible.

```agentica {expect="CHECK-SHADOWED-NAME"}
def main() -> Void
  x = 1
  for x in [1, 2] # error: x is already visible
    puts(x)
  end
end
```

## Nombres {#names}

Los nombres de variable, función y campo empiezan con una letra minúscula o `_`. Los nombres de tipo empiezan con una mayúscula. `a = b = 1` no está permitido.
