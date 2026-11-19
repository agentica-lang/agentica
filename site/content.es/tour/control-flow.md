---
title: Control de flujo
weight: 5
description: if, while, for, break, next, operadores booleanos y case con valores.
source_hash: "a4bf1480c053"
---

## if, elsif, else {#if-elsif-else}

La condición debe ser un `Bool`.

```agentica
def main() -> Void
  temperature = 18
  if temperature > 25
    puts("hot")
  elsif temperature > 15
    puts("mild")
  else
    puts("cold")
  end
end
```

```output
mild
```

## Operadores booleanos {#boolean-operators}

`and`, `or` y `not` (o `&&`, `||`, `!`) combinan valores `Bool`. `and` y `or` se detienen pronto cuando el lado izquierdo decide el resultado.

```agentica
def main() -> Void
  sunny = true
  warm = false
  puts(sunny and warm)
  puts(sunny || warm)
  puts(not warm)
  puts(!(sunny && warm))
end
```

```output
false
true
true
true
```

## while {#while}

`while` repite su bloque mientras la condición se cumpla.

```agentica
def main() -> Void
  n = 1
  while n < 50
    n *= 3
  end

  puts(n)
end
```

```output
81
```

## for {#for}

`for` recorre una lista. La variable del bucle es de solo lectura. Usa `_` para descartarla (ver [Variables](/tour/variables/)).

```agentica
def main() -> Void
  for fruit in ["apple", "pear", "plum"]
    puts(fruit)
  end

  for _ in 1..2 # the body does not need the number
    puts("tick")
  end
end
```

```output
apple
pear
plum
tick
tick
```

Para contar, recorre un rango: `a..b` incluye `b`, `a...b` no lo incluye. `n.times` ejecuta un bloque `n` veces. Consulta [Range](/library/data-structures/range/) para más.

```agentica
def main() -> Void
  for i in 1..3
    puts(i)
  end

  2.times do |i| puts("round #{i}") end
end
```

```output
1
2
3
round 0
round 1
```

## break y next {#break-and-next}

`break` sale del bucle. `next` pasa a la siguiente vuelta. Cuando uno de ellos, o un `return`, depende de una condición, escribe la condición después: `next if c` es el `if c` con `next` y `end` escritos. Solo `return`, `break` y `next` admiten esta guarda, y tiene una sola condición: no hay `unless` ni `else`.

```agentica
def main() -> Void
  for n in [1, 2, 3, 4, 5, 6]
    next if n % 2 == 0
    break if n > 4
    puts(n)
  end
end
```

```output
1
3
```

Una sentencia después de `return`, `break` o `next`, o después de un `if` o `case` cuyas ramas terminan todas en una de ellas, nunca se ejecuta, así que es un error (`CHECK-UNREACHABLE-CODE`). Quítala o muévela antes.

```agentica {expect="CHECK-UNREACHABLE-CODE"}
def main() -> Void
  for n in [1, 2, 3]
    if n == 2
      break
      puts("never")
    end

    puts(n)
  end
end
```

## case con valores {#case-on-values}

`case` ejecuta la primera rama que coincide; `_` coincide con cualquier cosa. Con un número, una cadena o un `Bool`, termina con una rama `_`.

```agentica
def describe(n: Int) -> String
  case n
    0 -> "zero"
    1 -> "one"
    _ -> "many"
  end
end

def main() -> Void
  puts(describe(0))
  puts(describe(1))
  puts(describe(7))
end
```

```output
zero
one
many
```

Una rama puede tener más líneas:

```agentica
def main() -> Void
  command = "add"
  total = 10
  case command
    "add" ->
      total += 5
      puts("added")
    "reset" -> total = 0
    _ -> puts("unknown command")
  end

  puts(total)
end
```

```output
added
15
```

`case` es más útil con enums: ver [Enums y case](/tour/enums-and-case/).

## Sentencias, no expresiones {#statements-not-expressions}

`if` y `case` no dan un valor. Asigna dentro de ellos, o devuelve desde ellos:

```agentica
def sign(n: Int) -> String
  word = "not negative"
  if n < 0
    word = "negative"
  end

  word
end

def main() -> Void
  puts(sign(-3))
end
```

```output
negative
```
