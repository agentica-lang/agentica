---
title: Lista
weight: 1
description: Funciones de List[T]. Cada una es también un método de las listas.
source_hash: "c3d8cab90882"
---

Las listas son inmutables: cada función da una lista nueva. `xs.length` es `xs.size`, `push` es `append`, `select` es `filter`.

`xs == ys` es verdadero cuando las dos listas tienen la misma longitud y elementos iguales en el mismo orden, comparados en profundidad; el tipo de los elementos debe admitir igualdad (no `Fn`, `Task`, `Channel` ni un handle).

Un callback es un bloque, `&name` o una variable de función. Se ejecuta una vez por elemento, de izquierda a derecha, bajo el presupuesto de pasos del llamador. Los tipos de parámetro y de retorno deben coincidir exactamente, y un callback de `map` devuelve datos, no `Void`. Los parámetros de bloque con anotación permiten que una lista vacía o un valor inicial vacío de `reduce` deduzca su tipo. Los costos de esta página no incluyen el trabajo propio del callback.

## Crear y leer {#build-and-read}

```signature
List.size(list: List[T]) -> Int
List.empty?(list: List[A]) -> Bool
List.at(list: List[T], index: Int) -> T
List.first(list: List[A]) -> A
List.last(list: List[A]) -> A
List.append(list: List[T], value: T) -> List[T]
List.set(list: List[T], index: Int, value: T) -> List[T]
List.repeat(value: T, count: Int) -> List[T]
List.reverse(list: List[T]) -> List[T]
```

- `at` es `list[index]`, y `set` reemplaza un elemento. Un índice no válido detiene el programa. Las dos son O(log32 n): como máximo cuatro pasos para un millón de elementos. Una lista nueva comparte todo menos el camino hasta el elemento.
- `first` y `last` dan el primer y el último elemento. En una lista vacía detienen el programa con `RUNTIME-INDEX-OUT-OF-RANGE`, como lo hace `xs[0]`; comprueba antes con `empty?`.
- `append` toma casi tiempo constante, así que n añadidos cuestan O(n). `reverse` es O(n).
- `repeat` acepta una cantidad de 0 a 1048576; cero da una lista vacía del tipo del elemento, y cualquier otra cantidad es `RUNTIME-INVALID-COUNT`.
- Un índice negativo o fuera de rango es `RUNTIME-INDEX-OUT-OF-RANGE` en el argumento del índice.
- `parts.join(separator)` sobre un `List[String]` da una sola cadena, con el separador entre las partes; [`List.join`](/library/text-and-data/string/#join) está en la página de String.
- `xs + ys` une dos listas del mismo tipo de elemento en una nueva; las dos listas siguen igual. Tarda un tiempo proporcional al tamaño de `ys` cuando `ys` tiene 32 elementos o menos. Un `ys` más largo copia las dos listas.

```agentica
def main() -> Void
  xs = [1, 2]
  puts(xs.size) # 2
  puts(xs.empty?) # false
  puts(xs.at(1)) # 2, the same as xs[1]
  puts(xs.first)
  puts(xs.last)
  puts(xs.push(9)) # xs is still [1, 2]
  puts(xs.set(0, 7))
  puts(xs + [3])
  puts(List.repeat("-", 3))
  puts(xs.reverse)
end
```

```output
2
false
2
1
2
[1, 2, 9]
[7, 2]
[1, 2, 3]
["-", "-", "-"]
[2, 1]
```

## take y drop {#take-and-drop}

```signature
List.take(list: List[T], count: Int) -> List[T]
List.drop(list: List[T], count: Int) -> List[T]
```

`take` conserva los primeros `count` elementos, `drop` los quita. Una cantidad mayor da la lista entera (`take`) o una lista vacía (`drop`), y una cantidad negativa es `RUNTIME-INVALID-COUNT`. O(n) en el tamaño del resultado.

```agentica
def main() -> Void
  xs = [1, 2, 3, 4]
  puts(xs.take(2))
  puts(xs.drop(2))
  puts(xs.take(10)) # a larger count is fine
end
```

```output
[1, 2]
[3, 4]
[1, 2, 3, 4]
```

## sort {#sort}

```signature
List.sort(list: List[T]) -> List[T]
```

Ordena valores `Int`, `Float`, `String` o `Ref`, de menor a mayor (un `Ref` según cuándo se creó); cualquier otro tipo de elemento es `CHECK-TYPE-MISMATCH`. El orden es estable y O(n log n). Las cadenas se ordenan por punto de código, así que `"B"` va antes que `"a"`, y un `NaN` va al final.

```agentica
def main() -> Void
  puts([3, 1, 2].sort)
  puts(["pear", "Fig", "apple"].sort)
end
```

```output
[1, 2, 3]
["Fig", "apple", "pear"]
```

## sort_by {#sort_by}

```signature
List.sort_by(list: List[A], key: Fn[A, K]) -> List[A]
```

Ordena de forma ascendente por la clave que da la función (un `Int`, `Float`, `String` o `Ref`; otro tipo de clave es `CHECK-TYPE-MISMATCH`). La función se ejecuta una vez por elemento, de izquierda a derecha. Las claves iguales conservan su orden, y el costo es O(n log n) más las llamadas a la función de clave.

```agentica
def main() -> Void
  words = ["ccc", "a", "bb"]
  puts(words.sort_by do |w| w.length end)
end
```

```output
["a", "bb", "ccc"]
```

## map, select y reduce {#map-select-and-reduce}

```signature
List.map(list: List[A], block: Fn[A, B]) -> List[B]
List.filter(list: List[A], block: Fn[A, Bool]) -> List[A]
List.reduce(list: List[A], initial: B, block: Fn[B, A, B]) -> B
```

`select` (la función es `List.filter`) conserva los elementos para los que la función da `true`. `reduce` combina de izquierda a derecha, empezando con `initial`.

```agentica
def main() -> Void
  puts([1, 2, 3].map do |x| x * 10 end)
  puts([1, 2, 3, 4].select do |x| x % 2 == 1 end)
  puts([1, 2, 3].reduce(0) do |sum, x| sum + x end)
end
```

```output
[10, 20, 30]
[1, 3]
6
```

## each y each_with_index {#each-and-each_with_index}

```signature
List.each(list: List[A], block: Fn[A, Void]) -> Void
List.each_with_index(list: List[A], block: Fn[A, Int, Void]) -> Void
```

Ejecutan la función para cada elemento, en orden, y no devuelven nada. El índice empieza en 0.

```agentica
def main() -> Void
  ["a", "b"].each_with_index do |s, i| puts("#{i}: #{s}") end
end
```

```output
0: a
1: b
```

## any? y all? {#any-and-all}

```signature
List.any?(list: List[A], block: Fn[A, Bool]) -> Bool
List.all?(list: List[A], block: Fn[A, Bool]) -> Bool
```

`any?` se detiene en el primer `true`, `all?` en el primer `false`.

```agentica
def main() -> Void
  xs = [3, 8, 5]
  puts(xs.any? do |x| x > 7 end)
  puts(xs.all? do |x| x > 7 end)
end
```

```output
true
false
```

## find {#find}

```signature
List.find(list: List[A], block: Fn[A, Bool]) -> Result[A]
```

`ok` con el primer elemento para el que la función da `true`; si no, `error("not found")`. Se detiene en la primera coincidencia.

```agentica
def main() -> Void
  xs = [3, 8, 5, 9]
  puts(xs.find do |x| x > 4 end)
  puts(xs.find do |x| x > 10 end)
end
```

```output
ok(8)
error("not found")
```

## count {#count}

```signature
List.count(list: List[A], block: Fn[A, Bool]) -> Int
```

`count` da el número de elementos para los que el bloque da `true`, sin construir una lista como hace `select(...).size`. Llama al bloque una vez por elemento, O(n). `size` cuenta todos los elementos.

```agentica
def main() -> Void
  xs = [1, 2, 3, 4]
  puts(xs.count do |x| x % 2 == 0 end)
end
```

```output
2
```

## index y find_index {#index-and-find_index}

```signature
List.index(list: List[T], value: T) -> Optional[Int]
List.find_index(list: List[A], block: Fn[A, Bool]) -> Optional[Int]
```

`index` da `some` con la posición del primer elemento `==` al valor, si no `none`; los elementos necesitan `==`, como para `include?`. `find_index` recibe un bloque en su lugar y da la posición del primer elemento para el que da `true`, así que es la forma con bloque: `xs.index do ... end` es `CHECK-BLOCK-TARGET`. Los `Float` se comparan con `==`, así que un NaN nunca coincide (`[nan].index(nan)` es `none`) y `-0.0` coincide con `0.0`. Ambos se detienen en la primera coincidencia y son O(n).

```agentica
def main() -> Void
  xs = ["pear", "fig", "fig"]
  puts(xs.index("fig"))
  puts(xs.index("kiwi"))
  puts(xs.find_index do |x| x.length > 3 end)
end
```

```output
some(1)
none
some(0)
```

## flat_map {#flat_map}

```signature
List.flat_map(list: List[A], block: Fn[A, List[B]]) -> List[B]
```

Une las listas que da la función, en orden.

```agentica
def main() -> Void
  puts([1, 2, 3].flat_map do |x| List.repeat(x, x) end)
end
```

```output
[1, 2, 2, 3, 3, 3]
```

## partition {#partition}

```signature
List.partition(list: List[A], block: Fn[A, Bool]) -> List[List[A]]
```

Da `[accepted, rejected]`.

```agentica
def main() -> Void
  halves = [1, 2, 3, 4, 5].partition do |x| x % 2 == 0 end
  puts(halves[0])
  puts(halves[1])
end
```

```output
[2, 4]
[1, 3, 5]
```

## take_while y drop_while {#take_while-and-drop_while}

```signature
List.take_while(list: List[A], block: Fn[A, Bool]) -> List[A]
List.drop_while(list: List[A], block: Fn[A, Bool]) -> List[A]
```

`take_while` conserva los elementos anteriores al primer `false`; `drop_while` conserva ese elemento y el resto. Ninguno llama a la función después de ese punto.

```agentica
def main() -> Void
  xs = [1, 2, 5, 1]
  puts(xs.take_while do |x| x < 3 end)
  puts(xs.drop_while do |x| x < 3 end)
end
```

```output
[1, 2]
[5, 1]
```

## each_slice {#each_slice}

```signature
List.each_slice(list: List[A], size: Int) -> List[List[A]]
```

Divide la lista en porciones de `size` elementos; la última puede ser más corta. No recibe bloque (`CHECK-BLOCK-TARGET`): llama a `each` sobre el resultado. Un `size` menor que 1 es `RUNTIME-INVALID-COUNT`.

```agentica
def main() -> Void
  [1, 2, 3, 4, 5].each_slice(2).each do |pair| puts(pair) end
end
```

```output
[1, 2]
[3, 4]
[5]
```

## group_by {#group_by}

```signature
List.group_by(list: List[A], key: Fn[A, K]) -> Map[K, List[A]]
```

Agrupa por la clave (un `Int`, un `String`, un `Bytes` o un `Ref`; otro tipo de clave es `CHECK-TYPE-MISMATCH` en el bloque). Las claves y los grupos conservan el orden de primera aparición.

```agentica
def main() -> Void
  words = ["apple", "fig", "pear", "kiwi"]
  puts(words.group_by do |w| w.length end)
end
```

```output
{5: ["apple"], 3: ["fig"], 4: ["pear", "kiwi"]}
```

## tally y uniq {#tally-and-uniq}

```signature
List.tally(list: List[K]) -> Map[K, Int]
List.uniq(list: List[K]) -> List[K]
```

`tally` cuenta los elementos iguales; `uniq` conserva el primero de cada uno. Los elementos son `Int` o un tipo entero de menos bits (`UInt8` y los demás), `String`, `Bytes` o `Ref`, en orden de primera aparición.

```agentica
def main() -> Void
  xs = ["b", "a", "b"]
  puts(xs.tally)
  puts(xs.uniq)
end
```

```output
{"b": 2, "a": 1}
["b", "a"]
```

## include? {#include}

```text
List.include?(list: List[T], value: T) -> Bool
```

Es verdadero cuando un elemento `==` al valor; `member?` es el mismo método. Los elementos pueden ser de cualquier tipo que tenga `==` (números, `Bool`, `String`, `nil`, rangos, `Bytes`, `JSON.Value`, y listas, mapas, conjuntos, Optional, Result, estructuras y enums de esos); una lista de funciones o de handles da `CHECK-TYPE-MISMATCH` en la lista, y un valor de otro tipo lo da en el valor. Se detiene en la primera coincidencia y es O(n). Un Float sigue la norma IEEE 754, así que `NaN` nunca pertenece a la lista y `-0.0` coincide con `0.0`. Para muchas búsquedas en una misma lista, crea antes un `Set`.

```agentica
def main() -> Void
  puts(["pear", "fig"].include?("fig"))
  puts([3, 1, 2].member?(9))
end
```

```output
true
false
```

## sum {#sum}

```signature
List.sum(list: List[N]) -> N
```

Suma valores `Int` o `Float` de izquierda a derecha. Una lista vacía da `0` o `0.0`. Una suma de `Int` que pasa de 64 bits es `RUNTIME-INTEGER-OVERFLOW` en la llamada, y cualquier otro tipo de elemento es `CHECK-TYPE-MISMATCH`.

```agentica
def main() -> Void
  puts([1, 2, 3].sum)
  puts([0.5, 0.25].sum)
end
```

```output
6
0.75
```

## min y max {#min-and-max}

```signature
List.min(list: List[T]) -> Optional[T]
List.max(list: List[T]) -> Optional[T]
```

`some` con el elemento menor o mayor, o `none` para una lista vacía. Los elementos son `Int`, `Float` o `String` (se comparan con `String.compare`); cualquier otro tipo de elemento es `CHECK-TYPE-MISMATCH`. En un empate gana el primer elemento, y un `NaN` nunca gana salvo que todos sean `NaN`. Un `Int` no tiene `min(other)`, como en Ruby: escribe `[a, b].min.unwrap!`, o `n.clamp(lo, hi)` para mantener un número dentro de un rango.

```agentica
def main() -> Void
  puts([3, 1, 2].min)
  puts([3, 1, 2].max)
  puts(["pear", "apple"].min)
  empty: List[Float] = []
  puts(empty.max)
  puts([700, 80].min.unwrap!)
end
```

```output
some(1)
some(3)
some("apple")
none
80
```

## min_by y max_by {#min_by-and-max_by}

```signature
List.min_by(list: List[A], key: Fn[A, O]) -> Optional[A]
List.max_by(list: List[A], key: Fn[A, O]) -> Optional[A]
```

`some` con el elemento de clave menor o mayor, o `none` para una lista vacía, como dan `min` y `max`. La clave es un `Int`, `Float` o `String` (se compara con `String.compare`); la función se ejecuta una vez por elemento. En un empate gana el primer elemento, y una clave `NaN` nunca gana salvo que todas sean `NaN`.

```agentica
def main() -> Void
  words = ["fig", "apple", "kiwi", "pear"]
  puts(words.min_by do |w| w.length end)
  puts(words.max_by do |w| w.length end)
  puts(words.max_by do |w| w end)
end
```

```output
some("fig")
some("apple")
some("pear")
```

## Costos y nombres {#costs-and-names}

Son O(n), aunque menos si se detienen antes. Están escritos en Agentica (`stdlib/prelude/`), así que cuentan `--max-steps` por elemento, sin contar tu función; y un error de runtime en ellos se reporta en la llamada de tu programa (en el argumento que lo nombra), nunca en el preludio.

`reject` es `CHECK-UNKNOWN-METHOD`. Escribe `xs.select do |x| !cond end`.
