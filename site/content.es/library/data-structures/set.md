---
title: Conjunto
weight: 3
description: Funciones de Set[T], una colección de valores enteros, String, Bytes o Ref distintos. Cada una es también un método de los conjuntos.
source_hash: "5fcd4a49bfff"
---

Un conjunto guarda cada valor una sola vez, en el orden en que se añadió por primera vez. Los elementos son `Int` o un tipo entero de menos bits (`UInt8` y los demás), `String`, `Bytes` o `Ref`, como las claves de un mapa. Los conjuntos son inmutables.

- `for` recorre un conjunto en orden. Un conjunto se imprime como `Set[1, 2]`.
- `a == b` es verdadero cuando los dos conjuntos tienen los mismos elementos, en cualquier orden.
- Un conjunto puede ser un campo de estructura, un elemento de una lista o un valor de un mapa.
- Un conjunto no se puede codificar en JSON, así que `JSON.encode` lo rechaza.

```agentica
def main() -> Void
  seen = Set.new(["b", "a", "b"])
  for name in seen
    puts(name)
  end

  puts(seen)
end
```

```output
b
a
Set["b", "a"]
```

## new {#new}

```signature
Set.new(items: List[T]) -> Set[T]
```

Crea un conjunto a partir de una lista. Un elemento repetido se descarta, y el primero conserva su lugar. `T` debe ser `Int` o un tipo entero de menos bits (`UInt8` y los demás), `String`, `Bytes` o `Ref`; si no, `CHECK-SET-ELEMENT-TYPE`. Una lista vacía necesita un tipo esperado, como `[]` y `{}`: sin él, `CHECK-EMPTY-SET-TYPE`.

```agentica
def main() -> Void
  puts(Set.new([3, 1, 2, 3, 1]))
  empty_set: Set[String] = Set.new([])
  puts(empty_set)
end
```

```output
Set[3, 1, 2]
Set[]
```

## add {#add}

```signature
Set.add(set: Set[T], value: T) -> Set[T]
```

Añade un elemento al final. Un elemento que ya está en el conjunto deja el conjunto igual.

```agentica
def main() -> Void
  s = Set.new([1, 2])
  puts(s.add(3))
  puts(s.add(1))
  puts(s)
end
```

```output
Set[1, 2, 3]
Set[1, 2]
Set[1, 2]
```

## delete {#delete}

```signature
Set.delete(set: Set[T], value: T) -> Set[T]
```

Quita un elemento. No pasa nada si el elemento no está. Un elemento que se vuelve a añadir después va al final. Cuesta lo mismo que `Map.delete`.

```agentica
def main() -> Void
  s = Set.new(["a", "b", "c"])
  puts(s.delete("a"))
  puts(s.delete("zzz"))
  puts(s.delete("a").add("a"))
end
```

```output
Set["b", "c"]
Set["a", "b", "c"]
Set["b", "c", "a"]
```

## include? {#include}

```signature
Set.include?(set: Set[T], value: T) -> Bool
```

Comprueba la pertenencia del valor al conjunto. Tarda, en la práctica, un tiempo constante, como `Map.key?`.

```agentica
def main() -> Void
  s = Set.new([1, 2])
  puts(s.include?(2))
  puts(s.include?(5))
end
```

```output
true
false
```

## size y empty? {#size-and-empty}

```signature
Set.size(set: Set[T]) -> Int
Set.empty?(set: Set[T]) -> Bool
```

```agentica
def main() -> Void
  s = Set.new([4, 4, 5])
  puts(s.size)
  puts(s.empty?)
  puts(s.delete(4).delete(5).empty?)
end
```

```output
2
false
true
```

## to_a {#to_a}

```signature
Set.to_a(set: Set[T]) -> List[T]
```

Los elementos en orden de primera inserción.

```agentica
def main() -> Void
  puts(Set.new([9, 7, 9, 8]).to_a)
end
```

```output
[9, 7, 8]
```

## union, intersection y difference {#union-intersection-and-difference}

```signature
Set.union(set: Set[T], other: Set[T]) -> Set[T]
Set.intersection(set: Set[T], other: Set[T]) -> Set[T]
Set.difference(set: Set[T], other: Set[T]) -> Set[T]
```

`union` da los elementos de `set`, seguidos de los de `other` que `set` no tiene. `intersection` y `difference` conservan el orden de `set`.

```agentica
def main() -> Void
  a = Set.new([1, 2, 3, 4])
  b = Set.new([4, 3, 9])
  puts(a.union(b))
  puts(a.intersection(b))
  puts(a.difference(b))
  puts(b.difference(a))
end
```

```output
Set[1, 2, 3, 4, 9]
Set[3, 4]
Set[1, 2]
Set[9]
```

## subset? {#subset}

```signature
Set.subset?(set: Set[T], other: Set[T]) -> Bool
```

Es verdadero cuando cada elemento de `set` está en `other`. El conjunto vacío es subconjunto de cualquier conjunto.

```agentica
def main() -> Void
  small = Set.new([2, 3])
  big = Set.new([1, 2, 3])
  puts(small.subset?(big))
  puts(big.subset?(small))
  puts(small.subset?(small))
end
```

```output
true
false
true
```
