---
title: Rango
weight: 5
description: Rangos de valores Int y los métodos de bucle de Int (times, upto y downto).
source_hash: "d753a32d1157"
---

`a..b` incluye los dos extremos; `a...b` deja fuera `b`. Ambos extremos son `Int`, y el tipo es `Range`. Un rango guarda solo su inicio, su fin y su clase, así que `0...1000000000` no cuesta nada hasta que se usa. Un extremo que no es `Int` es un tipo incompatible: `CHECK-TYPE-MISMATCH`, como en `"a"..."c"`.

`for` recorre un rango en orden. Un rango vacío (el fin antes que el inicio) no hace nada. Contar hasta el `Int` más grande no provoca desbordamiento.

```agentica
def main() -> Void
  for i in 0...3
    puts(i)
  end

  for _ in 3..1
    puts("never")
  end
end
```

```output
0
1
2
```

Los rangos tienen menor precedencia que cualquier otro operador, así que `0...n + 1` es `0...(n + 1)`. Una llamada a método sobre un rango necesita paréntesis: `(1..5).to_a`. Un rango se imprime como `1..5` o `1...5`, y dos rangos son iguales cuando coinciden su inicio, su fin y su clase.

```agentica
def main() -> Void
  r = 1...5
  puts(r)
  puts(r == (1...5))
  puts(r == (1..5))
end
```

```output
1...5
true
false
```

## Métodos de Enumerable {#enumerable-methods}

```signature
Range.map(range: Range, block: Fn[Int, B]) -> List[B]
Range.select(range: Range, block: Fn[Int, Bool]) -> List[Int]
Range.reduce(range: Range, initial: B, block: Fn[B, Int, B]) -> B
Range.sum(range: Range) -> Int
Range.min(range: Range) -> Optional[Int]
Range.max(range: Range) -> Optional[Int]
```

Un rango tiene los métodos de Enumerable de una lista: `map` (también `collect`), `select`, `flat_map`, `reduce` (también `inject`), `sum`, `min`, `max`, `min_by`, `max_by`, `find` (también `detect`), `find_index`, `any?`, `all?`, `each_with_index`, `each_slice`, `partition`, `group_by`, `take_while` y `drop_while`. Cada uno da lo que dan `.to_a` y el método de lista, sin construir antes la lista, así que no tiene el límite de 1048576 valores; `min` y `max` leen los extremos del rango. Se escriben igual que en una lista (la página de List tiene los detalles de cada uno); `take`, `drop` y `reject` no son métodos de un rango.

```agentica
def main() -> Void
  puts((1..4).map do |n| n * n end)
  puts((0...10).select do |n| n % 3 == 0 end)
  puts((1..100).sum)
  puts((1..5).reduce(1) do |product, n| product * n end)
  puts((5..1).max)
  puts((0...6).max_by do |n| (n - 2) * (n - 2) end)
end
```

```output
[1, 4, 9, 16]
[0, 3, 6, 9]
5050
120
none
some(5)
```

## size {#size}

```signature
Range.size(range: Range) -> Int
```

El recuento de valores. Un recuento que no cabe en `Int`, como en `(0..9223372036854775807).size`, detiene el programa con `RUNTIME-INTEGER-OVERFLOW`.

```agentica
def main() -> Void
  puts((1..5).size)
  puts((1...5).size)
  puts((5..1).size)
end
```

```output
5
4
0
```

## to_a {#to_a}

```signature
Range.to_a(range: Range) -> List[Int]
```

Los valores como lista, en orden. Un rango con más de 1048576 valores detiene el programa con `RUNTIME-INVALID-COUNT`.

```agentica
def main() -> Void
  evens = (0..10).to_a.select do |n| n % 2 == 0 end

  puts(evens)
end
```

```output
[0, 2, 4, 6, 8, 10]
```

## include? {#include}

```signature
Range.include?(range: Range, value: Int) -> Bool
```

```agentica
def main() -> Void
  puts((1...5).include?(4))
  puts((1...5).include?(5))
end
```

```output
true
false
```

## each {#each}

```signature
Range.each(range: Range, block: Fn[Int, Void]) -> Void
```

Llama al bloque con cada valor, en orden.

```agentica
def main() -> Void
  (1..3).each do |i| puts(i * 10) end
end
```

```output
10
20
30
```

## first y last {#first-and-last}

```signature
Range.first(range: Range) -> Result[Int]
Range.last(range: Range) -> Result[Int]
```

El primer y el último valor incluido, o un error para un rango vacío. A diferencia de Ruby, `(1...5).last` es `ok(4)`.

```agentica
def main() -> Void
  puts((1...5).first)
  puts((1...5).last)
  puts((5..1).last)
end
```

```output
ok(1)
ok(4)
error("the range is empty", kind: "argument")
```

## times, upto y downto {#times-upto-and-downto}

```signature
Int.times(int: Int, block: Fn[Int, Void]) -> Void
Int.upto(from: Int, to: Int, block: Fn[Int, Void]) -> Void
Int.downto(from: Int, to: Int, block: Fn[Int, Void]) -> Void
```

Métodos de `Int` para bucles. `n.times` llama al bloque con `0` hasta `n - 1`, y no hace nada cuando `n <= 0`. `a.upto(b)` cuenta desde `a` hasta `b`, y `a.downto(b)` desde `a` hasta `b` en orden inverso, con los dos extremos incluidos; no hacen nada cuando el fin ya quedó pasado. Un receptor negativo necesita paréntesis: `(-2).upto(2)`.

```agentica
def main() -> Void
  3.times do |i| print(i) end

  puts("")
  1.upto(3) do |i| print(i) end

  puts("")
  3.downto(1) do |i| print(i) end

  puts("")
end
```

```output
012
123
321
```
