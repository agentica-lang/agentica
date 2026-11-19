---
title: Mapas
weight: 9
description: Literales de mapa, lectura de claves, añadir y quitar entradas.
source_hash: "d815d08d4cda"
---

## Crear un mapa {#make-a-map}

Un mapa asocia claves con valores. Las claves son `Int`, `String` o `Bytes`. Todas las claves tienen un solo tipo, y todos los valores tienen un solo tipo: `Map[K, V]`. Un mapa mantiene el orden en que se añadieron las claves.

```agentica
def main() -> Void
  stock = {"apple": 3, "pear": 0}
  puts(stock)
  puts(stock.size)
end
```

```output
{"apple": 3, "pear": 0}
2
```

Un mapa vacío necesita un tipo conocido:

```agentica
def main() -> Void
  ages: Map[String, Int] = {}
  ages = ages.put("Ana", 25)
  puts(ages)
end
```

```output
{"Ana": 25}
```

## Leer una clave {#read-a-key}

`map[key]` da el valor. Una clave que falta detiene el programa.

```agentica
def main() -> Void
  stock = {"apple": 3}
  puts(stock["apple"])
end
```

```output
3
```

`get` con un valor predeterminado nunca falla. `get` sin él da un [Optional](/library/data-structures/optional/): `some(value)` o `none`.

```agentica
def main() -> Void
  stock = {"apple": 3}
  puts(stock.get("kiwi", 0))
  puts(stock.get("apple"))
  puts(stock.get("kiwi").none?)
  puts(stock.key?("apple"))
end
```

```output
0
some(3)
true
true
```

## Añadir, cambiar y quitar {#add-change-and-remove}

`put` da un mapa nuevo con la entrada añadida o reemplazada. `delete` da un mapa nuevo sin la clave. El mapa anterior no cambia.

```agentica
def main() -> Void
  stock = {"apple": 3}
  more = stock.put("pear", 5)
  more = more.put("apple", 4)
  less = more.delete("pear")
  puts(stock)
  puts(more)
  puts(less)
end
```

```output
{"apple": 3}
{"apple": 4, "pear": 5}
{"apple": 4}
```

## Recorrer un mapa {#walk-a-map}

`keys` y `values` dan listas en el orden de inserción.

```agentica
def main() -> Void
  prices = {"tea": 3, "cake": 5}
  for name in prices.keys
    puts("#{name}: #{prices[name]}")
  end

  puts(prices.values)
end
```

```output
tea: 3
cake: 5
[3, 5]
```

## Contar cosas {#count-things}

```agentica
def main() -> Void
  counts: Map[String, Int] = {}
  for word in "a b a c a".split(" ")
    counts = counts.put(word, counts.get(word, 0) + 1)
  end

  puts(counts)
end
```

```output
{"a": 3, "b": 1, "c": 1}
```

Para campos fijos de tipos distintos, usa una [estructura](/tour/structs/). Todas las funciones están en la [página de la biblioteca Map](/library/data-structures/map/).
