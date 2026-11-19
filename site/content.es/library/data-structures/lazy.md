---
title: Lazy
weight: 6
description: Pipelines perezosos sobre listas, rangos, fuentes sin fin, archivos y canales, que un método final ejecuta un elemento a la vez, con try en los bloques y un método final que escribe un archivo.
source_hash: "3b2185abcf55"
---

Un `Lazy[T]` es una receta: una fuente y los pasos después de ella. Crearlo no hace ningún trabajo. Un método final (`to_a`, `first`, `each`, `reduce`, `find`, `write_lines`, `write_bytes`) lo ejecuta, y pide un elemento a la vez a la fuente y lo pasa por cada paso, así que ningún paso crea una lista con todos los elementos. Un paso devuelve un `Lazy` nuevo; el anterior no cambia, y cada método final vuelve a ejecutar la fuente desde el principio (un canal, que no se puede leer dos veces, sigue donde se detuvo el último método final).

Usa un `Lazy` para una fuente sin fin, para las líneas de un archivo grande o los valores de un canal, o cuando solo se necesitan los primeros resultados de un encadenamiento largo de pasos. Para una lista que vas a recorrer completa, los métodos estrictos de [List](/library/data-structures/list/) son la forma adecuada.

```agentica
def main() -> Void
  naturals = Lazy.produce(1) do |n| n + 1 end
  squares = naturals.map { |n| n * n }
  puts(squares.select { |n| n % 2 == 1 }.first(3))
  puts((1..10).lazy.each_slice(4).to_a)
end
```

```output
ok([1, 9, 25])
ok([[1, 2, 3, 4], [5, 6, 7, 8], [9, 10]])
```

Cada método final da un `Result`. `take`, `take_while`, `first` y `find` detienen la fuente cuando tienen bastante, así que una fuente sin fin termina; `to_a`, `reduce` y `each` sobre una fuente sin fin nunca terminan, y `--max-steps` los detiene con `RUNTIME-STEP-LIMIT`. Cada elemento pedido cuesta un paso, y cada callback un paso más su cuerpo, igual que en `Range.each`. Otras tareas siguen ejecutándose entre elementos: un método final puede quedar suspendido entre dos elementos, así que `--max-steps`, los turnos de otras tareas y una cancelación llegan a un pipeline sin callback. Los callbacks se ejecutan en la tarea que llamó al método final, y una receta puede compartirse entre tareas en cualquier planificador. Un error de runtime en un callback termina el programa como en cualquier otro lugar. Un método final sobre un archivo o un canal se suspende mientras espera, como lo hacen `File.each_line` y `recv`, y una cancelación lo alcanza allí.

Un `Lazy` no tiene `==`, ni `to_s` (`CHECK-TYPE-MISMATCH`), ni forma JSON (`CHECK-NOT-ENCODABLE`); `IO.inspect` imprime `<Lazy>`. `Lazy` es un nombre de tipo reservado. No hay `next`: un `Lazy` es una receta, no un cursor. Un método de `List` sobre un `Lazy`, como `lz.size`, es `CHECK-UNKNOWN-METHOD` con una ayuda que muestra `to_a`; un paso que solo tiene `Lazy`, como `xs.each_cons(2)` sobre una lista, muestra `.lazy`.

## Fuentes {#sources}

```signature
List.lazy(list: List[A]) -> Lazy[A]
Range.lazy(range: Range) -> Lazy[Int]
Lazy.produce(seed: A, block: Fn[A, A]) -> Lazy[A]
File.foreach(path: String, buffer_bytes: Int = 65536, timeout_ms: Int = 30000) -> Lazy[String]
File.chunks(path: String, size: Int = 65536, timeout_ms: Int = 30000) -> Lazy[Bytes]
Channel.lazy(channel: Channel[A], timeout_ms: Int) -> Lazy[A]
```

`Lazy.produce` da `seed`, luego `f(seed)`, luego `f(f(seed))`, sin fin. No llama a su bloque para un elemento que ningún paso necesita.

```agentica
def main() -> Void
  puts([3, 1, 2].lazy.to_a)
  puts((1...4).lazy.to_a)
  words = Lazy.produce("a") do |s| s + "a" end
  puts(words.first(3))
end
```

```output
ok([3, 1, 2])
ok([1, 2, 3])
ok(["a", "aa", "aaa"])
```

### File.foreach {#fileforeach}

Las líneas de un archivo, leídas como las lee [`File.each_line`](/library/io-and-system/files/#fileeach_line): un trozo de `buffer_bytes` (de 1024 a 16777216, que también es la línea más larga) a la vez, y `timeout_ms` para cada lectura. Crear el `Lazy` no abre nada. El archivo se abre cuando empieza un método final y se cierra antes de que el método final devuelva, sea cual sea lo que lo terminó (el fin del archivo, un `take` o un `find` que ya tenía bastante, un error, un `try` fallido); un fallo o una cancelación de la tarea lo cierra al final de la tarea. Tras un tiempo de espera de lectura, el handle se libera de inmediato, y el descriptor del sistema operativo se cierra cuando termina la lectura que expiró.

Un error de lectura (UTF-8 inválido, una línea más larga que el búfer), un archivo que falta o un tiempo de espera incorrecto terminan el método final con ese error. `File.foreach(...).each do ... end` sin ningún paso entre medias, escrito como un solo encadenamiento, es `CHECK-LAZY-NO-STEP`: para eso escribe `File.each_line`. Un búfer fuera de 1024..16777216 es `RUNTIME-INVALID-COUNT` en el argumento.

```agentica {mode="check"}
def main() -> Void
  head = File.foreach("server.log", 4096, 1000).first(10)
  errors = File.foreach("server.log", 4096, 1000).select { |line| line.include?("ERROR") }.each do |line|
    puts(line)
    ok()
  end

  puts(head.ok? and errors.ok?)
end
```

### File.chunks {#filechunks}

Los bytes de un archivo regular en trozos de `size` bytes (de 1 a 16777216), el último más corto. Se abre y se cierra igual que `File.foreach`. Un archivo que falta, o uno que no es regular (se decide en el descriptor abierto), termina el método final con `error("filesystem: path does not refer to a regular file")`. Un tamaño fuera de 1..16777216 es `RUNTIME-INVALID-COUNT` en el argumento.

### ch.lazy {#chlazy}

Los valores de un canal hasta que se cierra y se vacía. Cada espera de un valor respeta `timeout_ms`, y un tiempo de espera termina el método final con `error("channel: timed out")`. Un tiempo negativo es `RUNTIME-INVALID-DURATION` en el argumento; `ch.lazy(0)` toma solo lo que ya está ahí. Un canal no se puede leer dos veces: un segundo método final sigue con los valores que el primero no tomó (`ok([])` cuando ya está vacío), y un valor que un método final tomó ya no está, aunque un paso posterior lo haya descartado. `take`, `first` y `find` no toman ningún valor que no necesiten; `take_while` consume el primer valor que rechaza su bloque.

```agentica
def produce(ch: Channel[Int]) -> Void
  for i in 1..6
    ch.send(i, 1000).unwrap!
  end

  ch.close
end

def main() -> Void
  ch: Channel[Int] = Channel.new(2)
  Task.spawn(&produce, ch)
  values = ch.lazy(1000)
  puts(values.first(2))
  puts(values.map { |n| n * n }.to_a)
end
```

```output
ok([1, 2])
ok([9, 16, 25, 36])
```

## map, select y flat_map {#map-select-and-flat_map}

```signature
Lazy.map(lazy: Lazy[A], block: Fn[A, B]) -> Lazy[B]
Lazy.filter(lazy: Lazy[A], block: Fn[A, Bool]) -> Lazy[A]
Lazy.flat_map(lazy: Lazy[A], block: Fn[A, List[B]]) -> Lazy[B]
```

`select` es el método de `Lazy.filter`. `flat_map` da los elementos de las listas que devuelve su bloque, en orden. No hay `filter_map`: escribe `select` y luego `map`.

```agentica
def main() -> Void
  xs = [1, 2, 3, 4]
  puts(xs.lazy.select { |x| x % 2 == 0 }.map { |x| x * 10 }.to_a)
  puts(xs.lazy.flat_map { |x| [x, -x] }.first(5))
end
```

```output
ok([20, 40])
ok([1, -1, 2, -2, 3])
```

## take, take_while, drop y drop_while {#take-take_while-drop-and-drop_while}

```signature
Lazy.take(lazy: Lazy[A], count: Int) -> Lazy[A]
Lazy.take_while(lazy: Lazy[A], block: Fn[A, Bool]) -> Lazy[A]
Lazy.drop(lazy: Lazy[A], count: Int) -> Lazy[A]
Lazy.drop_while(lazy: Lazy[A], block: Fn[A, Bool]) -> Lazy[A]
```

Una cantidad negativa es `RUNTIME-INVALID-COUNT` en el argumento, al crear el paso. `take_while` se detiene en el primer elemento que su bloque rechaza; `drop_while` deja de llamar a su bloque en el primer elemento que rechaza.

```agentica
def main() -> Void
  naturals = Lazy.produce(1) do |n| n + 1 end
  puts(naturals.drop(2).take(3).to_a)
  puts(naturals.take_while { |n| n < 4 }.to_a)
  puts([1, 5, 2, 7].lazy.drop_while { |n| n < 3 }.to_a)
end
```

```output
ok([3, 4, 5])
ok([1, 2, 3])
ok([5, 2, 7])
```

## with_index {#with_index}

```signature
Lazy.with_index(lazy: Lazy[A], block: Fn[A, Int, B]) -> Lazy[B]
```

Transforma cada elemento con su índice, desde 0. Para guardar el elemento y el índice juntos, devuelve una estructura.

```agentica
def main() -> Void
  puts(["a", "b", "c"].lazy.with_index { |s, i| "#{i}:#{s}" }.to_a)
end
```

```output
ok(["0:a", "1:b", "2:c"])
```

## each_slice, each_cons y chunk_while {#each_slice-each_cons-and-chunk_while}

```signature
Lazy.each_slice(lazy: Lazy[A], size: Int) -> Lazy[List[A]]
Lazy.each_cons(lazy: Lazy[A], size: Int) -> Lazy[List[A]]
Lazy.chunk_while(lazy: Lazy[A], block: Fn[A, A, Bool]) -> Lazy[List[A]]
```

`each_slice` da porciones de `size` elementos, la última más corta. `each_cons` da cada ventana de `size` vecinos, y ninguna cuando la fuente tiene menos. `chunk_while` empieza un grupo nuevo donde su bloque es falso para dos vecinos. Un tamaño menor que 1 es `RUNTIME-INVALID-COUNT` en el argumento, al crear el paso.

```agentica
def main() -> Void
  xs = [1, 2, 4, 5, 6, 9]
  puts(xs.lazy.each_slice(4).to_a)
  puts(xs.lazy.each_cons(3).first(2))
  puts(xs.lazy.chunk_while { |a, b| b == a + 1 }.to_a)
end
```

```output
ok([[1, 2, 4, 5], [6, 9]])
ok([[1, 2, 4], [2, 4, 5]])
ok([[1, 2], [4, 5, 6], [9]])
```

## to_a y first {#to_a-and-first}

```signature
Lazy.to_a(lazy: Lazy[A]) -> Result[List[A]]
Lazy.first(lazy: Lazy[A], count: Int) -> Result[List[A]]
```

`first(n)` es `take(n)` seguido de `to_a`: como mucho `n` elementos, menos cuando la fuente termina.

```agentica
def main() -> Void
  puts([1, 2].lazy.first(5))
  puts((1..3).lazy.map { |n| n * n }.to_a)
end
```

```output
ok([1, 2])
ok([1, 4, 9])
```

## each {#each}

```signature
Lazy.each(lazy: Lazy[A], block: Fn[A, Result[Void]]) -> Result[Void]
```

El bloque devuelve `ok()` para seguir, o un `error` que detiene el pipeline y es el resultado, como en `File.each_line`. `try` funciona en el bloque.

```agentica
def main() -> Void
  naturals = Lazy.produce(1) do |n| n + 1 end
  result = naturals.each do |n|
    return error("stopped at #{n}") if n > 2

    puts(n)
    ok()
  end

  puts(result)
end
```

```output
1
2
error("stopped at 3")
```

## reduce y find {#reduce-and-find}

```signature
Lazy.reduce(lazy: Lazy[A], initial: B, block: Fn[B, A, B]) -> Result[B]
Lazy.find(lazy: Lazy[A], block: Fn[A, Bool]) -> Result[A]
```

`reduce` pliega desde la izquierda, como `List.reduce`. `find` da el primer elemento que acepta su bloque, o `error("not found")` cuando la fuente termina, como `List.find`.

```agentica
def main() -> Void
  puts((1..4).lazy.reduce(0) do |total, n| total + n end)
  powers = Lazy.produce(1) do |n| n * 2 end
  puts(powers.find do |n| n > 100 end)
  puts([1, 2].lazy.find do |n| n > 5 end)
end
```

```output
ok(10)
ok(128)
error("not found")
```

## write_lines {#write_lines}

```signature
Lazy.write_lines(lazy: Lazy[String], path: String, timeout_ms: Int = 30000) -> Result[Void]
```

Escribe cada elemento y un salto de línea en un archivo, creado o truncado, y da `ok()` al final. El archivo se abre antes de pedir el primer elemento (si la apertura falla, no se pide nada) y se vacía y se cierra antes de que el método final devuelva, sea cual sea lo que lo terminó; un fallo o una cancelación de la tarea lo cierra al final de la tarea. Las líneas se guardan en búfer y se escriben de 64 KiB en 64 KiB. Lo que se escribió antes de un error se queda en el archivo. `timeout_ms` limita la apertura, cada escritura y el cierre. Un tiempo de espera o una ruta incorrectos, una apertura, escritura o cierre fallidos, y una línea de más de 1 MiB terminan el método final con ese error. Una línea que contiene un salto de línea se lee de vuelta como dos líneas con `File.foreach`.

```agentica {mode="check"}
def amount(line: String) -> Result[Int] = line.split(",")[1].to_i

def main() -> Void
  done = (
    File.foreach("ledger.csv", 4096, 1000)
      .drop(1)
      .map { |line| "#{try amount(line) * 100}" }
      .write_lines("cents.txt", 1000)
  )

  puts(done)
end
```

## Pasos de Zlib {#zlib-steps}

```signature
Lazy.deflate(lazy: Lazy[Bytes], level: Int = 6, raw: Bool = false) -> Lazy[Bytes]
Lazy.inflate(lazy: Lazy[Bytes], raw: Bool = false, max_bytes: Int = 1073741824) -> Lazy[Bytes]
Lazy.gzip(lazy: Lazy[Bytes], level: Int = 6) -> Lazy[Bytes]
Lazy.gunzip(lazy: Lazy[Bytes], max_bytes: Int = 1073741824) -> Lazy[Bytes]
Lazy.write_bytes(lazy: Lazy[Bytes], path: String, timeout_ms: Int = 30000) -> Result[Int]
```

Los pasos comprimen o descomprimen un flujo de trozos de [`Bytes`](/library/data-structures/bytes/), como los trozos de `File.chunks`, que lee un archivo regular de `size` bytes (de 1 a 16777216) a la vez. `write_bytes` escribe los trozos en un archivo, creado o truncado, como `write_lines` escribe líneas (un trozo puede tener cualquier tamaño, también vacío), y da los bytes escritos. Un truncamiento, un checksum incorrecto, un byte sobrante al final, una salida que pasa de `max_bytes`, un `level` fuera de 0..9 y un `max_bytes` menor que 1 terminan el método final con un error que empieza por `zlib: `. Un decodificador comprueba `max_bytes` mientras procesa el flujo, antes de pasar un byte que lo supera. Una ejecución libera sus flujos de zlib antes de que el método final devuelva, sea cual sea lo que lo terminó; un fallo o una cancelación los libera al final de la tarea. [Zlib](/library/text-and-data/zlib/#streams) tiene los detalles.

```agentica
def main() -> Void
  packed = ["hi".bytes, "".bytes, "!".bytes].lazy.gzip.to_a.unwrap!
  puts(packed.lazy.gunzip.map { |chunk| chunk.to_a }.to_a)
end
```

```output
ok([[104, 105, 33]])
```

## try en los bloques {#try-in-the-blocks}

Un `try` fallido en cualquier bloque de un método de `Lazy` (un paso, `Lazy.produce`, un método final), sea cual sea el tipo de resultado del bloque, termina el pipeline: no se pide ningún elemento posterior, se cierra un archivo que abrió la ejecución, y el método final devuelve el error. Un `try` que tiene éxito da su valor, así que el bloque sigue dando un elemento normal. Un bloque anidado dentro de ese bloque, como el de un `List.map`, sigue la regla habitual: un `try` allí necesita un bloque que devuelva un `Result` (`CHECK-TRY-CONTEXT`).

```agentica
def parse(text: String) -> Result[Int] = text.to_i

def main() -> Void
  words = ["1", "2", "x", "4"]
  puts(words.lazy.map { |word| try parse(word) * 10 }.first(2))
  puts(words.lazy.map { |word| try parse(word) * 10 }.to_a)
  puts(words.lazy.reduce(0) do |sum, word| sum + try parse(word) end)
end
```

```output
ok([10, 20])
error("cannot convert \"x\" to Int", kind: "number.parse")
error("cannot convert \"x\" to Int", kind: "number.parse")
```
