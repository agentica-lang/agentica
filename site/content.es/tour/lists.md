---
title: Listas
weight: 8
description: Literales de lista, índices, cómo añadir elementos y los métodos comunes de lista.
source_hash: "6d1f568d1d00"
---

## Crear una lista {#make-a-list}

Una lista guarda valores de un solo tipo, en orden. Su tipo se escribe `List[T]`.

```agentica
def main() -> Void
  numbers = [3, 1, 2]
  names = ["Ana", "Bob"]
  puts(numbers)
  puts(names.size)
end
```

```output
[3, 1, 2]
2
```

Mezclar tipos en una lista es un error:

```agentica {expect="CHECK-TYPE-MISMATCH"}
def main() -> Void
  mixed = [1, "two"]
end
```

Una lista vacía necesita un tipo conocido, por ejemplo con una anotación:

```agentica
def main() -> Void
  todo: List[String] = []
  puts(todo.size)
end
```

```output
0
```

## Leer elementos {#read-elements}

Los índices empiezan en 0. Un índice fuera de la lista detiene el programa.

```agentica
def main() -> Void
  letters = ["a", "b", "c"]
  puts(letters[0])
  puts(letters[2])
end
```

```output
a
c
```

```agentica {expect="RUNTIME-INDEX-OUT-OF-RANGE"}
def main() -> Void
  letters = ["a", "b", "c"]
  puts(letters[3])
end
```

## Añadir y cambiar {#add-and-change}

Las listas nunca cambian en su sitio. `push` da una lista nueva con un elemento más. `set` da una lista nueva con un elemento reemplazado. `+` une dos listas en una nueva.

```agentica
def main() -> Void
  xs = [1, 2]
  xs = xs.push(3)
  xs = xs.set(0, 10)
  puts(xs)
  puts(xs + [4, 5])
end
```

```output
[10, 2, 3]
[10, 2, 3, 4, 5]
```

`xs[0] = 10` no existe. Usa `set`.

## Recorrer una lista {#walk-a-list}

Usa `for`, o `each` con un bloque:

```agentica
def main() -> Void
  for n in [1, 2]
    puts(n)
  end

  ["x", "y"].each do |s| puts(s) end
end
```

```output
1
2
x
y
```

## Transformar {#transform}

`map`, `select` y `reduce` reciben un bloque y dan un valor nuevo:

```agentica
def main() -> Void
  xs = [1, 2, 3, 4, 5]
  puts(xs.map do |x| x * x end)
  puts(xs.select do |x| x > 2 end)
  puts(xs.reduce(0) do |sum, x| sum + x end)
end
```

```output
[1, 4, 9, 16, 25]
[3, 4, 5]
15
```

## Ordenar, tomar y descartar {#sort-take-drop}

```agentica
def main() -> Void
  xs = [5, 3, 8, 1]
  puts(xs.sort)
  puts(xs.reverse)
  puts(xs.take(2))
  puts(xs.drop(2))
end
```

```output
[1, 3, 5, 8]
[1, 8, 3, 5]
[5, 3]
[8, 1]
```

`sort_by` ordena por una clave que da un bloque:

```agentica
def main() -> Void
  words = ["pear", "fig", "banana"]
  puts(words.sort_by do |w| w.length end)
end
```

```output
["fig", "pear", "banana"]
```

## Comprobar los elementos {#ask-questions}

```agentica
def main() -> Void
  xs = [2, 4, 7]
  puts(xs.any? do |x| x > 5 end)
  puts(xs.all? do |x| x % 2 == 0 end)
end
```

```output
true
false
```

## Listas de listas {#lists-of-lists}

```agentica
def main() -> Void
  grid = [[1, 2], [3, 4]]
  puts(grid[1][0])
  puts(List.repeat(0, 3))
end
```

```output
3
[0, 0, 0]
```

Prefiere `for` o `each` para visitar cada elemento. Consulta la [página de la biblioteca List](/library/data-structures/list/) para ver cada función.
