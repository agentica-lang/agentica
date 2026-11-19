---
title: Caché (std)
weight: 4
description: El módulo std/cache, un contrato pequeño para cachés de cadenas que comparten tareas, y una implementación en memoria de ese contrato construida sobre ATS.
source_hash: "6a1676d5d7c4"
---

`std/cache` está escrito en Agentica, sobre [ATS](/library/concurrency/ats/): `import Cache from "std/cache"`. Guarda texto calculado, como un fragmento HTML ya generado, entre solicitudes, dentro de un presupuesto de bytes y de un tiempo de vida opcional.

- Un `Cache.Store` es una estructura de valores de función: el contrato que cumple toda caché, ya que Agentica no tiene traits. `Cache.memory` crea uno; un paquete con otra estrategia de desalojo crea la misma estructura, y `get`, `put`, `fetch` y los demás auxiliares de este módulo funcionan con todas ellas.
- Un store es un handle, como una tabla `ATS`: pasarlo a una función o a una tarea lo comparte. Cada llamada es segura desde cualquier número de tareas en cualquier planificador, y ningún bloque se ejecuta dentro de una llamada a `ATS`.
- Las claves y los valores son `String`. Usa `id.to_s` para una clave `Int`. No hay valor `Bytes`.
- No hay métodos: llama a `Cache.get(cache, key)`.

## Cache.memory {#cachememory}

```signature
Cache.memory(max_bytes: Int, options: Cache.Options = Cache.Options()) -> Cache.Store
```

Una caché vacía que guarda como mucho `max_bytes`, contando cada elemento como su clave, su valor y 64 bytes de sobrecarga. `Cache.Options` tiene tres campos, cada uno con su predeterminado:

- `max_entries: Int = 0`: como mucho esta cantidad de elementos, 0 para ningún límite.
- `ttl_ms: Int = 0`: el tiempo de vida de un elemento en milisegundos, 0 para ninguno (ver [Caducidad](#expiry)).
- `clock: Optional[Fn[Int]] = none`: la hora en milisegundos, que solo tiene que avanzar. Sirve para medir los elementos y el lease de un descarte (abajo), así que un reloj que se detiene también impide que otra tarea tome un descarte atascado. El predeterminado es el reloj monotónico; una prueba da uno falso.

Un elemento es demasiado grande cuando su clave, su valor y los 64 bytes de sobrecarga suman más de la mitad de `max_bytes` (ver [Desalojo](#eviction)): `fetch` y `put_new` no lo guardan, y `put` tampoco lo guarda, y quita el valor anterior de su clave.

## Cache.fetch {#cachefetch}

```signature
Cache.fetch(cache: Cache.Store, key: String, compute: Fn[String]) -> String
```

Da el valor de `key`. Si no está, ejecuta el bloque, guarda el resultado y lo da. El bloque se ejecuta fuera del store, así que puede ser lento o llamar al store. Dos tareas que no encuentran la misma clave a la vez ejecutan ambas el bloque, y se conserva un solo resultado; un bloque que debe ejecutarse una sola vez pertenece a una tarea dueña.

```agentica
import Cache from "std/cache"

def render(id: Int, renders: ATS[String, Int]) -> String
  renders.add("renders", 1)
  "<p>message #{id}</p>"
end

def main() -> Void
  cache = Cache.memory(1_000_000)
  renders: ATS[String, Int] = ATS.new()
  for id in [1, 2, 1, 1, 2]
    html = Cache.fetch(cache, "msg:#{id}:v1") do render(id, renders) end
    puts(html)
  end

  puts(renders.get("renders").unwrap!)
end
```

```output
<p>message 1</p>
<p>message 2</p>
<p>message 1</p>
<p>message 1</p>
<p>message 2</p>
2
```

## Cache.get, put, put_new, delete y clear {#cacheget-put-put_new-delete-and-clear}

```signature
Cache.get(cache: Cache.Store, key: String) -> Optional[String]
Cache.put(cache: Cache.Store, key: String, value: String) -> Void
Cache.put_new(cache: Cache.Store, key: String, value: String) -> Bool
Cache.delete(cache: Cache.Store, key: String) -> Void
Cache.clear(cache: Cache.Store) -> Void
```

`get` da `some(value)` o `none`; un elemento caducado es un desacierto. `put` guarda un valor y reemplaza el que ya hay; es una eliminación seguida de un guardado, no un paso atómico, así que un lector puede ver un desacierto entre medias, y un `put` que no encuentra sitio, o que pierde la clave frente a otro `put`, se descarta después de que el valor viejo ya no está. `put_new` guarda solo cuando la clave no tiene un valor vigente, y da `true` cuando guardó. `delete` ignora una clave ausente. `clear` quita cada elemento; un `put` que se ejecuta a la vez puede sobrevivirle, o descartarse (el valor anterior de su clave se pierde de todos modos).

Un delete o un clear no tiene orden respecto a un `fetch` o un `put` de la misma clave que está en curso: un bloque que empezó antes del delete puede guardar su valor después. Un `get` que empieza después de que un delete ha devuelto no ve el valor, salvo que un `put` de esa clave que empezó antes se haya detenido durante una rotación completa y llegue después (ver [Desalojo](#eviction)).

```agentica
import Cache from "std/cache"

def main() -> Void
  cache = Cache.memory(10_000)
  Cache.put(cache, "a", "one")
  Cache.put(cache, "a", "two")
  puts(Cache.get(cache, "a"))
  puts(Cache.put_new(cache, "a", "three"))
  Cache.delete(cache, "a")
  puts(Cache.get(cache, "a"))
end
```

```output
some("two")
false
none
```

## Cache.bytes {#cachebytes}

```signature
Cache.bytes(cache: Cache.Store) -> Int
```

Los bytes que ocupan los elementos, contados como los cuenta `max_bytes`, nunca por encima de `max_bytes`. Cuando no hay ninguna llamada en curso el conteo es exacto: es la suma de los elementos que están en la caché, y delete, un reemplazo, la caducidad y `cleanup` devuelven sus bytes.

## Caducidad {#expiry}

Con `ttl_ms`, un elemento nunca se lee más de ese tiempo después de escribirse, y una lectura no lo hace vivir más (pon la versión en la clave en su lugar: `"msg:#{id}:#{updated_at}"`). Tres cosas lo quitan:

- `get` y `put_new` tratan un elemento caducado como ausente y lo quitan.
- Una generación joven que lleva la mitad del tiempo de vida pasa a vieja cuando llega la siguiente escritura, y la generación anterior a la vieja se descarta entera (ver [Desalojo](#eviction)). La rotación solo ocurre con escrituras: sin `put` ni desacierto de `fetch`, los elementos caducados se quedan hasta que se leen o se ejecuta `Cache.cleanup`. Con escrituras en curso, un elemento sale de la memoria como mucho unas 1,5 veces el tiempo de vida después de escribirse, y puede salir antes del tiempo de vida, y no antes de aproximadamente la mitad de él, como puede hacer una caché al descartar un elemento.
- `Cache.cleanup` quita de una vez cada elemento caducado.

```signature
Cache.cleanup(cache: Cache.Store) -> Int
```

`cleanup` quita cada elemento que pasó su tiempo de vida y da cuántos quitó. Es seguro desde cualquier tarea en cualquier momento, junto a `get` y `put`, y mantiene exacto el conteo de bytes. Sin `ttl_ms` no quita nada. Para barrer cada pocos segundos, ejecútalo en una tarea propia:

```agentica {mode="check"}
import Cache from "std/cache"

def sweep_forever(cache: Cache.Store) -> Void
  while true
    _ = Cache.cleanup(cache)
    Task.sleep(5_000)
  end
end

def main() -> Void
  cache = Cache.memory(64 * 1024 * 1024, Cache.Options(ttl_ms: 60_000))
  _ = Task.spawn(&sweep_forever, cache)
end
```

Un ejemplo con un tiempo de vida corto:

```agentica
import Cache from "std/cache"

def main() -> Void
  cache = Cache.memory(10_000, Cache.Options(ttl_ms: 20))
  Cache.put(cache, "a", "one")
  puts(Cache.get(cache, "a"))
  Task.sleep(60)
  puts(Cache.cleanup(cache))
  puts(Cache.bytes(cache))
  puts(Cache.get(cache, "a"))
end
```

```output
some("one")
1
0
none
```

## Desalojo {#eviction}

`Cache.memory` guarda tres tablas `ATS`, llamadas generaciones. Los elementos nuevos van a la generación joven. Cuando un elemento no cabe en ella, la generación joven pasa a ser la vieja, la generación anterior se descarta entera y empieza una vacía. `get` busca en la generación joven y luego en la vieja, y no guarda nada: solo lo hacen `put` y `fetch` (solo quita un elemento caducado). Por eso un elemento sale entre una y dos rotaciones después de escribirse, por muchas veces que se lea, y una clave popular la vuelve a calcular el siguiente `fetch` aproximadamente cada dos rotaciones. Es una aproximación barata de primero en entrar, primero en salir por generaciones, sin escribir al leer, y eso es lo que mantiene `get` rápido y sin carreras con `delete`.

Cada generación viva guarda como mucho la mitad de `max_bytes` y de `max_entries` (al menos un elemento), así que la caché guarda entre la mitad y el total; el tamaño de un elemento (clave, valor y los 64 bytes) se compara con `max_bytes / 2`. Con una carga desigual (20.000 claves de 1 KB, las populares pedidas mucho más a menudo, un presupuesto del 10 % de las claves) dio acierto en el 63 % de las solicitudes (37 % con una distribución más plana). Una simulación de las mismas solicitudes con el presupuesto completo da 69 % y 45 % para LRU exacto, y 60 % y 34 % para vaciar toda la caché cuando está llena.

Descartar una generación es un [`ATS.clear`](/library/concurrency/ats/#atsdelete-and-atsclear) de su tabla, sea cual sea su tamaño, así que el put que la inicia no espera y `Cache.clear` tarda lo mismo, muy poco. Un put que encuentra un descarte en curso en otra tarea, y sin sitio, se descarta: una caché puede olvidar un elemento.

## El conteo de bytes es exacto {#the-byte-count-is-exact}

El conteo de bytes se mantiene exacto cuando las tareas compiten por los mismos elementos: ningún tamaño se cuenta dos veces ni se pierde. Sus límites:

- Una tarea cancelada a mitad de una escritura puede dejar un elemento sin contar, legible hasta un descarte posterior de su tabla.
- Una tarea cancelada entre reservar los bytes de un elemento y guardarlo deja esa reserva contada hasta que se descarta su generación.
- Solo la generación actual puede descartarse. Un descarte que una tarea ha tenido durante dos segundos según el reloj de la caché, como cuando se canceló a mitad, lo toma otra tarea. Una tarea cancelada mientras toma un descarte también es tomada por otra, entre dos y cuatro segundos después. Si la primera tarea solo se detuvo y sigue más tarde, la caché puede saltarse una generación, cuya tabla conserva sus elementos sin contar y sin leer hasta que un descarte posterior la vacíe, o perder los elementos de la generación joven, cuyos bytes siguen contados hasta que esa generación se descarte.

## Escribir otra caché {#writing-another-cache}

Una implementación devuelve un `Cache.Store` cuyas funciones siguen este contrato, cada una segura para llamar desde cualquier tarea en cualquier momento:

- `get` da el valor, o `none`; un elemento caducado es un desacierto.
- `put` guarda un valor y reemplaza el que ya hay; un valor demasiado grande para la caché no se guarda, y el valor anterior de su clave desaparece.
- `put_new` guarda solo cuando la clave no tiene un valor vigente, y da `true` cuando guardó.
- `delete` ignora una clave ausente, y `clear` quita cada elemento.
- `cleanup` quita cada elemento caducado y da cuántos; da 0 cuando la caché no tiene tiempo de vida.
- `bytes` da los bytes de los elementos, contados como la implementación cuenta `max_bytes`.

Cada campo es una [lambda](/tour/blocks/#lambdas) que guarda el estado de la caché. Esta guarda todo en una tabla, sin límite, y cuenta elementos donde una caché con límite de bytes cuenta bytes:

```agentica
import Cache from "std/cache"

def table_get(table: ATS[String, String], key: String) -> Optional[String]
  found = table.get(key)
  return some(found.unwrap!) if found.ok?

  none
end

def table_clear(table: ATS[String, String]) -> Void
  for key in table.keys
    table.delete(key)
  end
end

def table_cache() -> Cache.Store
  table: ATS[String, String] = ATS.new()
  Cache.Store(
    get: ->(key) { table_get(table, key) },
    put: ->(key, value) { table.put(key, value) },
    put_new: ->(key, value) { table.put_new(key, value) },
    delete: ->(key) { table.delete(key) },
    clear: -> { table_clear(table) },
    cleanup: -> { 0 },
    bytes: -> { table.size },
  )
end

def main() -> Void
  cache = table_cache()
  puts(Cache.fetch(cache, "a") do "one" end)
  puts(Cache.fetch(cache, "a") do "two" end)
  puts(Cache.put_new(cache, "a", "three"))
end
```

```output
one
one
false
```
