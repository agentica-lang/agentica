---
title: Mapa
weight: 2
description: Funciones de Map[K, V]. Cada una es también un método de los mapas.
source_hash: "61b3282195c0"
---

Los mapas son inmutables y mantienen el orden en que se añadieron las claves. Las claves son `Int`, `String` o `Bytes`.

`a == b` es verdadero cuando los dos mapas tienen las mismas claves con valores iguales, en cualquier orden. El tipo del valor debe admitir igualdad (no `Fn`, `Task`, `Channel` ni un handle).

## size y empty? {#size-and-empty}

```signature
Map.size(map: Map[K, V]) -> Int
Map.empty?(map: Map[K, V]) -> Bool
```

```agentica
def main() -> Void
  puts({"a": 1, "b": 2}.size)
  puts({"a": 1, "b": 2}.empty?)
end
```

```output
2
false
```

`size` es O(1): el mapa guarda su cantidad de pares.

## get {#get}

```signature
Map.get(map: Map[K, V], key: K) -> Optional[V]
Map.get(map: Map[K, V], key: K, default: V) -> V
```

Con dos argumentos, `get` da un [Optional](/library/data-structures/optional/): `some(value)`, o `none` cuando falta la clave. Con un tercer argumento, da el valor o el predeterminado; el predeterminado se evalúa siempre, y `false` y `nil` son valores presentes.

```agentica
def main() -> Void
  ages = {"Ana": 25}
  puts(ages.get("Ana"))
  puts(ages.get("Bob").none?)
  puts(ages.get("Bob", 0))
  case ages.get("Ana")
    some(age) -> puts("Ana is #{age}")
    none -> puts("no Ana")
  end
end
```

```output
some(25)
true
0
Ana is 25
```

`map[key]` también lee un valor, y detiene el programa cuando falta la clave.

## has_key? y key? {#has_key-and-key}

```signature
Map.has_key?(map: Map[K, V], key: K) -> Bool
```

`m.key?(k)` es el nombre de Ruby de `Map.has_key?`.

```agentica
def main() -> Void
  m = {1: "one"}
  puts(m.key?(1))
  puts(m.key?(2))
end
```

```output
true
false
```

## put {#put}

```signature
Map.put(map: Map[K, V], key: K, value: V) -> Map[K, V]
```

Añade o reemplaza un par clave-valor. Una clave reemplazada conserva su lugar.

```agentica
def main() -> Void
  m = {"a": 1, "b": 2}
  puts(m.put("c", 3))
  puts(m.put("a", 10))
end
```

```output
{"a": 1, "b": 2, "c": 3}
{"a": 10, "b": 2}
```

## delete {#delete}

```signature
Map.delete(map: Map[K, V], key: K) -> Map[K, V]
```

Quita una clave y conserva el orden de las demás. No pasa nada si la clave no existe, y una clave que se vuelve a poner después va al final. Cuesta O(log32 n) amortizado a lo largo de una línea de versiones, con una reconstrucción O(n) de la lista de claves tras muchas llamadas a delete.

```agentica
def main() -> Void
  m = {"a": 1, "b": 2}
  puts(m.delete("a"))
  puts(m.delete("zzz"))
end
```

```output
{"b": 2}
{"a": 1, "b": 2}
```

## keys y values {#keys-and-values}

```signature
Map.keys(map: Map[K, V]) -> List[K]
Map.values(map: Map[K, V]) -> List[V]
```

Ambos siguen el orden de inserción.

```agentica
def main() -> Void
  m = {"x": 1, "y": 2}
  puts(m.keys)
  puts(m.values)
end
```

```output
["x", "y"]
[1, 2]
```

## each {#each}

```signature
Map.each(map: Map[K, V], block: Fn[K, V, Void]) -> Void
```

Ejecuta la función con cada clave y cada valor, en orden de inserción.

```agentica
def main() -> Void
  {"x": 1, "y": 2}.each do |key, value| puts("#{key}=#{value}") end
end
```

```output
x=1
y=2
```

## filter y select {#filter-and-select}

```signature
Map.filter(map: Map[K, V], block: Fn[K, V, Bool]) -> Map[K, V]
```

Conserva los pares clave-valor para los que la función da `true`, en orden de inserción. O(n), como `each`. `m.select` es el nombre de Ruby.

```agentica
def main() -> Void
  stock = {"apple": 3, "fig": 0, "kiwi": 7}
  puts(stock.select do |_, count| count > 0 end)
end
```

```output
{"apple": 3, "kiwi": 7}
```
