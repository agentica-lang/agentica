---
title: ATS
weight: 3
description: Comparte un contador o una caché entre tareas en una sola tabla mutable.
source_hash: "005b8d55676a"
---

Un `ATS[K, V]` (Agentica Table Storage) es una tabla que las tareas comparten y actualizan directamente, como ETS de Erlang. Los valores siguen siendo inmutables; una tabla es el único lugar compartido que cambia. Usa un [Channel](/library/concurrency/channel/) para pasar mensajes, y una tabla para un estado que muchas tareas leen y actualizan, como un contador o una caché.

- Una tabla es un handle: pasarla a una función o a una tarea la comparte, nunca se copia. Puede ser un campo de estructura, un elemento de lista, un valor de `Map`, o un argumento o un resultado de `Task.spawn`, pero no un valor dentro de una tabla. Una constante solo guarda una tabla cuando es todo su inicializador, `ATS.new()` ([una tabla constante](#a-constant-table)); en cualquier otro sitio dentro de una constante es `CHECK-CONSTANT-TYPE`. `ATS` es un nombre reservado: una `struct`, un `enum` o un alias de importación de usuario llamado `ATS` es `CHECK-REDEFINED-NAME`.
- Las claves son `Int`, `String`, `Bytes` o `Ref`, como en un `Map`; si no, `CHECK-MAP-KEY-TYPE`. Los valores son datos sin `Fn`, `Task`, `Channel`, handle, `Lazy` ni tabla dentro, y no `Nil`; si no, `CHECK-ATS-VALUE` en el tipo del valor. La prueba es profunda: mira dentro de los campos de estructura, los elementos de lista, los payloads de enum, los valores de `Map` y `Result`, y rechaza `Fn` porque un bloque puede capturar un handle. La [`Address`](/library/concurrency/channel/#channeladdress) de un canal es un dato, así que una tabla puede guardar las direcciones de canales. Un `Result[Void]` anidado está permitido; un `V` igual a `Void` es `CHECK-VOID-TYPE`. Un parámetro de tipo no se acepta como `V` (un payload de enum genérico `ATS[String, T]`), porque sus usos no se comprobarían; un alias genérico se comprueba donde se usa.
- Cada llamada es atómica, en cualquier planificador: un lector ve la tabla antes o después de una escritura, nunca a medias. Ninguna llamada toma un bloque, así que no se ejecuta código del usuario dentro de una llamada, y una llamada no puede causar un interbloqueo ni volver a entrar en la tabla.
- Todas salvo `new` también funcionan como métodos: `hits.add("home", 1)` es `ATS.add(hits, "home", 1)`.
- `puts`, `print`, la interpolación y `==` sobre una tabla son `CHECK-TYPE-MISMATCH`, `.to_s` es `CHECK-UNKNOWN-METHOD`, y una estructura con un campo de tabla es `CHECK-NOT-ENCODABLE` como JSON. `IO.inspect` imprime `<ATS>` sin el contenido. Usa `to_map` para verlo.
- El recolector de basura libera una tabla cuando nada la referencia. No es un recurso del SO, así que no se aplica la regla de propiedad de los handles: la tarea que la creó no la posee, su fin no la cierra, y no hace falta `Task.spawn_owning`. Una tarea llega a una tabla por un handle que recibió o por una tabla constante. Una tabla pertenece a la ejecución que la creó, y una llamada desde otra ejecución se detiene con `RUNTIME-ATS-CONTEXT`.
- No hay límite de tamaño ni caducidad; una caché acotada es [std/cache](/library/concurrency/cache/), un módulo de `std/` sobre `ATS`, y una con caducidad también debe ir en un módulo. No se admiten: tablas ordenadas, claves duplicadas (guarda una lista por clave con [`ATS.push`](#atspush)), un `update` basado en bloque, un `replace` con comparar e intercambiar (compare-and-swap), ni tablas compartidas entre procesos del SO.
- `put`, `put_new`, `delete`, `clear`, `add` y `push` llevan el efecto `concurrency`, que además evita `CHECK-UNUSED-VALUE` en un `put_new`, `add` o `push` que se ignora.
- `get`, `put`, `put_new`, `has_key?`, `delete`, `add` y `push` tardan O(1) en promedio, sea cual sea el tamaño de la tabla, y `size` y `clear` O(1). `keys` y `to_map` son O(n): copian la tabla mientras no hay escrituras y luego construyen su lista o su mapa sin retener a las otras tareas. Una lectura no toma ningún bloqueo ni escribe nada que vean los otros planificadores, así que las tareas que leen una misma tabla se ejecutan en paralelo; una lectura que se solapa con una escritura vuelve a intentarlo. Una escritura espera a las otras escrituras de esa tabla, y a una copia de `keys` o `to_map`, durante lo que dura una sola llamada. Así que las escrituras a una misma tabla no se ejecutan en paralelo, aunque escriban claves distintas.
- En BDD, un proceso trabajador ejecuta el `main` del programa de pasos una vez y después muchos escenarios, así que una tabla creada en `main` y capturada por bloques de pasos es compartida por los escenarios que ese trabajador ejecuta. Para tener una nueva en cada escenario, créala en un paso y guárdala con `BDD.keep`, o ejecuta `agentica test --isolate`, que ejecuta cada escenario, y `main` de nuevo, en un proceso propio. Una tabla no puede ir en el JSON de `BDD.set`.

## ATS.new {#atsnew}

```signature
ATS.new() -> ATS[K, V]
```

Crea una tabla vacía. Necesita un tipo esperado (anotación, parámetro, campo o tipo devuelto), si no `CHECK-EXPECTED-TYPE`.

```agentica {expect="CHECK-EXPECTED-TYPE"}
def main() -> Void
  hits = ATS.new()
end
```

```agentica {expect="CHECK-ATS-VALUE"}
def main() -> Void
  jobs: ATS[String, Task[Int]] = ATS.new()
end
```

## Una tabla constante {#a-constant-table}

Una constante cuyo inicializador completo es `ATS.new()`, con su tipo escrito, es una tabla creada una vez por ejecución antes de `main`, como cualquier otra constante. Todas las tareas de la ejecución y cada archivo que importa la constante comparten la misma tabla, así que da un estado por programa con un tipo estático, como un registro de nombres con [direcciones](/library/concurrency/channel/#channeladdress). Sin el tipo es `CHECK-EXPECTED-TYPE`; una tabla en cualquier otro lugar de una constante (`[ATS.new()]`, un campo de estructura, la tabla de otra constante) es `CHECK-CONSTANT-TYPE`.

```agentica
HITS: ATS[String, Int] = ATS.new()

def visit(page: String) -> Int = HITS.add(page, 1)

def main() -> Void
  tasks = ["home", "home", "about"].map do |page| Task.spawn(&visit, page) end
  tasks.each do |t| Task.await(t) end
  puts(HITS.get("home").unwrap!)
end
```

```output
2
```

```agentica {expect="CHECK-CONSTANT-TYPE"}
TABLES: List[ATS[String, Int]] = [ATS.new()]

def main() -> Void
  puts(TABLES.size)
end
```

## ATS.put, ATS.put_new y ATS.get {#atsput-atsput_new-and-atsget}

```signature
ATS.put(table: ATS[K, V], key: K, value: V) -> Void
ATS.put_new(table: ATS[K, V], key: K, value: V) -> Bool
ATS.get(table: ATS[K, V], key: K) -> Result[V]
ATS.has_key?(table: ATS[K, V], key: K) -> Bool
```

`put` inserta o reemplaza. `put_new` inserta solo cuando la clave no está y da `true`; `false` deja la tabla sin cambios. `get` da `ok(value)`, o un error cuando la clave no está.

```agentica
def main() -> Void
  names: ATS[Int, String] = ATS.new()
  names.put(1, "ana")
  names.put(1, "eve")
  puts(names.put_new(1, "bob"))
  puts(names.put_new(2, "bob"))
  puts(names.get(1).unwrap!)
  puts(names.get(3).ok?)
  puts(names.has_key?(2))
end
```

```output
false
true
eve
false
true
```

## ATS.add {#atsadd}

```signature
ATS.add(table: ATS[K, Int], key: K, by: Int) -> Int
```

Suma `n` al valor de la clave, contando una clave ausente como 0, y da el nuevo valor. La lectura y la escritura son un solo paso atómico, así que las tareas que suman a la vez no pierden ninguna actualización. Solo funciona sobre una tabla de valores `Int`; si no, `CHECK-TYPE-MISMATCH`. Un resultado fuera del rango de 64 bits detiene el programa con `RUNTIME-INTEGER-OVERFLOW` y deja la tabla sin cambios.

```agentica
def count_visits(hits: ATS[String, Int]) -> Void
  for _ in 1..100
    hits.add("home", 1)
  end
end

def main() -> Void
  hits: ATS[String, Int] = ATS.new()
  tasks = [1, 2, 3, 4].map do |_| Task.spawn(&count_visits, hits) end
  tasks.each do |task| Task.await(task) end
  puts(hits.get("home").unwrap!)
end
```

```output
400
```

## ATS.push {#atspush}

```signature
ATS.push(table: ATS[K, List[E]], key: K, value: E) -> Int
```

Añade `value` a la lista de la clave, contando una clave ausente como una lista vacía, y da la nueva longitud. La lectura y la escritura son un solo paso atómico, así que las tareas que añaden a la misma clave a la vez no pierden ningún elemento; un `get` seguido de un `put` sí puede perder uno. Un push construye primero su lista nueva y empieza de nuevo cuando otra tarea cambió la clave mientras tanto, así que muchas tareas que añaden a una misma clave a la vez repiten trabajo: dale a cada una su propia clave cuando las listas son largas. Solo funciona sobre una tabla cuyos valores son listas; si no, `CHECK-TYPE-MISMATCH`.

```agentica
def main() -> Void
  rooms: ATS[String, List[String]] = ATS.new()
  tasks = ["ana", "bob", "eve"].map do |name| Task.spawn { rooms.push("lobby", name) } end
  tasks.each do |task| Task.await(task) end
  puts(rooms.get("lobby").unwrap!.sort)
  puts(rooms.push("hall", "ana"))
end
```

```output
["ana", "bob", "eve"]
1
```

## ATS.delete y ATS.clear {#atsdelete-and-atsclear}

```signature
ATS.delete(table: ATS[K, V], key: K) -> Void
ATS.clear(table: ATS[K, V]) -> Void
```

`delete` quita la clave; una clave ausente se ignora. `clear` quita cada clave en un solo paso, sea cual sea el tamaño de la tabla: un lector ve la tabla llena o vacía, una instantánea tomada antes conserva sus claves, y una escritura que se ejecuta a la vez llega antes del clear y se quita, o después y se queda.

```agentica
def main() -> Void
  stock: ATS[String, Int] = ATS.new()
  stock.put("tea", 3)
  stock.put("milk", 1)
  before = stock.keys
  stock.clear
  puts(stock.size)
  puts(before)
  puts(stock.add("tea", 1))
end
```

```output
0
["tea", "milk"]
1
```

## ATS.size, ATS.keys y ATS.to_map {#atssize-atskeys-and-atsto_map}

```signature
ATS.size(table: ATS[K, V]) -> Int
ATS.keys(table: ATS[K, V]) -> List[K]
ATS.to_map(table: ATS[K, V]) -> Map[K, V]
```

Cada una lee la tabla tal como está en el momento de la llamada. `keys` y `to_map` listan las claves en orden de primera inserción; una clave quitada y vuelta a poner va al final, como en `Map`. No hay `values` ni `get` con valor predeterminado: usa `to_map` y `Result.unwrap_or`.

```agentica
def main() -> Void
  stock: ATS[String, Int] = ATS.new()
  stock.put("tea", 3)
  stock.put("milk", 1)
  stock.put("bread", 2)
  stock.delete("tea")
  stock.put("tea", 5)
  puts(stock.size)
  puts(stock.keys)
  IO.inspect(stock.to_map)
end
```

```output
3
["milk", "bread", "tea"]
{"milk": 1, "bread": 2, "tea": 5}
```

## Una caché que llenan las tareas {#a-cache-that-tasks-fill}

La primera tarea con un desacierto de caché en una clave calcula su valor y lo guarda con `put_new`; una tarea con un desacierto en esa clave al mismo tiempo también lo calcula, pero solo se guarda un valor. Una segunda tabla cuenta el trabajo.

```agentica
struct Shared
  cache: ATS[Int, String]
  stats: ATS[String, Int]
end

def lookup(shared: Shared, n: Int) -> String
  found = shared.cache.get(n)
  return found.unwrap! if found.ok?

  text = "#{n} squared is #{n * n}"
  if shared.cache.put_new(n, text)
    shared.stats.add("stored", 1)
  end

  text
end

def work(shared: Shared) -> Void
  for n in 1..3
    lookup(shared, n)
  end
end

def main() -> Void
  cache: ATS[Int, String] = ATS.new()
  stats: ATS[String, Int] = ATS.new()
  shared = Shared(cache: cache, stats: stats)
  tasks = [1, 2, 3].map do |_| Task.spawn(&work, shared) end
  tasks.each do |task| Task.await(task) end
  puts(stats.get("stored").unwrap!)
  cache.keys.sort.each do |n| puts(cache.get(n).unwrap!) end
end
```

```output
3
1 squared is 1
2 squared is 4
3 squared is 9
```

`add` y `push` son las actualizaciones atómicas, y `put_new` la única inserción condicional. No hay transacciones sobre varias claves: para actualizar otros valores de forma segura, deja que una tarea dueña haga las escrituras ([Estado que posee una sola tarea](/library/concurrency/channel/#state-owned-by-one-task)).
