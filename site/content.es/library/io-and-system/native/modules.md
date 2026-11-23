---
title: Módulos nativos
weight: 6
description: Llama a código de C escrito para Agentica con tipos de Agentica, y un resultado completo en una sola llamada.
source_hash: "5530421d682a"
---

Un módulo nativo es código de C escrito contra la API de C de la VM, la cabecera `agentica_native.h`. Un bloque `extern module "NAME"` declara sus funciones con tipos de Agentica, y el programa las llama como cualquier `def`. Una llamada puede recibir y devolver listas, mapas, opcionales, resultados y las estructuras y enums propios del programa, como todas las filas de una consulta, donde un [bloque `extern`](/library/io-and-system/native/) necesita una llamada por cada valor de C.

```agentica {mode="check"}
struct Summary
  count: Int
  mean: Float
end

enum Cell
  Empty
  Number(Float)
  Text(String)
end

extern module "stats"
  ## The count and mean of the values; none for no values.
  def summary(values: List[Float]) -> Optional[Summary]
  ## The lines of a CSV text after its header, as maps from the header's names to typed cells.
  def rows(text: String) -> Result[List[Map[String, Cell]]]
  def empty?(text: String) -> Bool
end

def main() -> Void
  puts(summary([2.0, 4.0, 9.0]))
  puts(rows("name,qty\nkiwi,3\n"))
end
```

## El bloque {#the-block}

- `NAME` es una biblioteca como en un bloque `extern`: un nombre sin `/`, una ruta absoluta, o el `[native.NAME]` del `agentica.toml` del paquete.
- Cada línea es un `def` o un `compute def` sin cuerpo, con el nombre que le da la tabla del módulo, con `?` y `!` incluidos, o un `resource Name`. La documentación con `##` funciona como en cualquier `def`, y una línea de recurso ocupa el lugar de un `def` en el orden de declaración. El bloque es público como un todo, o privado como un todo después de `private`.
- Estos tipos cruzan: `Int`, `Float`, `Bool`, `String`, `Bytes`, `Void` como resultado, una `List`, `Optional` o `Result` de ellos, un `Map` con claves `Int`, `String` o `Bytes`, alias de estos, y las estructuras y enums del programa que no son genéricos, cuyos campos y payloads también cruzan. Un recurso del bloque cruza como el tipo completo de un parámetro, y en cualquier lugar de un resultado excepto en un campo o payload. Cualquier otro tipo es `CHECK-NATIVE-TYPE` en ese punto, y lo mismo dos de esos tipos o recursos con un mismo nombre suelto en un bloque (`A.Row` y `B.Row`): el módulo conoce sus tipos por ese nombre.
- La tabla nombra la función de C y sus tipos, así que una línea `callback` o `struct`, un `free:` después de un recurso, un parámetro `out`, un `...` y un nombre de C después de `=` son `PARSE-EXTERN-MODULE`, y un tipo `C.` es `PARSE-EXTERN-TYPE`.
- Un `def` es una llamada corta. Un `compute def` es una llamada dirty: se ejecuta en el grupo de hilos de cómputo mientras la tarea espera, como un `compute def` de un bloque `extern`, y puede bloquear. Una tarea cancelada durante una no la detiene: la llamada llega hasta su final y su resultado se descarta.
- Un recurso es un handle al estado de C que el módulo guarda, como una conexión. Pertenece a la tarea que lo creó. La función de liberación del módulo lo libera una sola vez: en `Native.close`, al final de esa tarea, o al final de la ejecución, del más nuevo al más antiguo. Una llamada que lo recibe como argumento lo mantiene vivo hasta que la llamada devuelve, sin importar qué lo cierre mientras tanto. `Native.closed?` dice si está cerrado, y una llamada con uno cerrado falla con `RUNTIME-NATIVE-CLOSED`.
- Cualquier flag `--deny-*` o `--sandbox` rechaza un programa con un bloque de módulo antes de que se ejecute (`RUNTIME-NATIVE-DENIED`, código de salida 2), con o sin un programa en caché, y no se compila nada: una tabla `build` no inicia ningún compilador, y `agentica compile` con un flag así rechaza el módulo (`PKG-NATIVE-BUILD`).

## Vinculación {#binding}

La primera llamada a una función del bloque abre la biblioteca, como lo hace un bloque `extern`, y llama a su `agentica_native_init` una vez por ejecución. Una biblioteca que no se abre, no tiene punto de entrada, o se compiló para otra versión mayor de la API (o una versión menor más nueva) hace que esa llamada falle con `RUNTIME-NATIVE-LOAD`. Después, la VM busca la función por su nombre en la tabla del módulo. Debe tener la misma firma, el mismo modo, y cada estructura o enum con el mismo nombre, campos o variantes y tipos; si no, la llamada falla con `RUNTIME-NATIVE-SIGNATURE`. Una firma se escribe de forma canónica: los alias expandidos, los tipos del usuario por sus nombres sueltos, `", "` entre parámetros y argumentos de tipo, y después `" -> "` y el resultado, como en `(List[Float]) -> Optional[Summary]`. La forma de una estructura es `"count: Int, mean: Float"`, la de un enum `"Empty | Number(Float) | Text(String)"`, en el orden declarado.

## Un handle en datos genéricos {#a-handle-in-generic-data}

Un recurso pertenece al bloque que lo declara, así que un paquete propietario de un tipo de datos, como un tensor, no puede nombrar el recurso de un backend que vive en otro paquete. No le hace falta: haz que el tipo y la tabla de operaciones sean genéricos sobre el handle, y deja que el backend rellene la tabla. El paquete de los datos no tiene código nativo, y el backend lo importa, así que no hay ciclo de imports. El comprobador lo acepta entre paquetes, y `Native.close`, `Native.arena` y `RUNTIME-NATIVE-CLOSED` funcionan con un handle guardado en los datos como con cualquier otro.

```agentica {mode="check"}
# In the package that owns the data: no native code, so no import cycle.
struct Tensor[H]
  handle: H
  shape: List[Int]
end

struct Ops[H]
  make: Fn[Int, Result[H]]
  add: Fn[H, H, Result[H]]
end

def plus[H](ops: Ops[H], a: Tensor[H], b: Tensor[H]) -> Result[Tensor[H]]
  handle = try ops.add(a.handle, b.handle)
  ok(Tensor(handle: handle, shape: a.shape))
end

# In the backend: the block declares the resource and fills the table with its own functions.
extern module "backend"
  resource Buf
  def make(n: Int) -> Result[Buf]
  def add(a: Buf, b: Buf) -> Result[Buf]
end

def ops() -> Ops[Buf] = Ops(make: &make, add: &add)
```

Las funciones nativas del backend siguen recibiendo y devolviendo su propio recurso, aquí `Buf`. `Ops[Buf]` las guarda como valores `Fn` normales, y `plus` las llama para cualquier `H`. Una función nativa que recibe o devuelve `Tensor[Buf]`, recibe una estructura con un campo `Buf` o nombra el recurso de otro bloque sigue siendo `CHECK-NATIVE-TYPE`.

## El lado de C {#the-c-side}

El paquete [native-gen](https://www.agentica-lang.com/packages/native-gen/) genera una cabecera de C a partir del bloque: prototipos con tipos, comprobaciones de argumentos y las tablas de funciones y tipos. Después, el archivo de C tiene funciones de C simples. Esta sección describe la API que hay debajo.

```c
#include "agentica_native.h"

enum { SUMMARY };

static an_term summary(an_env *env, int argc, const an_term *argv) {
  an_list_cursor c;
  an_term item;
  size_t n;
  double total = 0, x;
  (void)argc;
  if (!an_list_cursor_begin(env, argv[0], &c, &n)) return an_badarg(env, 0);
  if (n == 0) return an_none(env);
  while (an_list_next(env, &c, &item)) {
    if (!an_get_float(env, item, &x)) return an_badarg(env, 0);
    total += x;
  }
  an_term fields[2] = {an_int(env, (int64_t)n), an_float(env, total / n)};
  return an_some(env, an_struct(env, SUMMARY, fields));
}

static const an_type types[] = {{"Summary", AN_STRUCT, "count: Int, mean: Float"}};

static const an_function functions[] = {
  {"summary", "(List[Float]) -> Optional[Summary]", summary, AN_SHORT},
};

AN_MODULE_TYPES("stats", functions, types, NULL)
```

- `AN_MODULE(NAME, FUNCTIONS, LOAD)` define el punto de entrada de un módulo sin tipos, `AN_MODULE_TYPES(NAME, FUNCTIONS, TYPES, LOAD)` el de uno con tipos, y `AN_MODULE_TABLES(NAME, FUNCTIONS, FUNCTION_COUNT, TYPES, TYPE_COUNT, RESOURCES, RESOURCE_COUNT, LOAD)` el de uno con recursos (`NULL, 0` para una tabla que no tiene). `LOAD` es `NULL` o una función que se ejecuta una vez después del punto de entrada y devuelve `NULL` o un mensaje que rechaza el módulo.
- Una fila de la tabla de funciones es el nombre, la firma canónica, la función de C y su modo, `AN_SHORT` (o `AN_DIRTY` para un `compute def`). `AN_FRESH` sumado al modo (`AN_SHORT | AN_FRESH`, API 1.5) dice que los recursos que crea la función no vienen de sus argumentos de recurso, como un tensor que es propietario de sus datos: una [arena](/library/io-and-system/native/types/#arenas) que retiene uno lo retiene solo, no los argumentos que llevaron a él. Con `AN_FRESH`, el módulo promete que cada recurso que crea la función es propietario de toda su memoria y nunca apunta al estado de un argumento: los argumentos pueden liberarse mientras el resultado vive, incluso durante una llamada sobre el resultado. El programa declara la función como siempre. Un módulo compilado con la cabecera de la API 1.5 necesita agentica 0.37.0 o posterior; uno más antiguo lo rechaza con `RUNTIME-NATIVE-LOAD`. Una fila de la tabla de tipos es el nombre suelto, `AN_STRUCT` o `AN_ENUM`, y la forma; su índice es el tipo que reciben `an_struct`, `an_get_field`, `an_enum`, `an_get_variant` y `an_get_payload`, y los campos, variantes y payloads se cuentan desde 0. Dos filas con un mismo nombre rechazan el módulo (`RUNTIME-NATIVE-LOAD`).
- Los valores son términos opacos. Cada getter (`an_get_int`, `an_get_string`, `an_list_next`, `an_map_get`, `an_get_optional`, `an_get_result`, `an_get_field`, `an_get_variant`, `an_get_payload` y los demás) devuelve `false` para un término de otro tipo, o para un campo o payload fuera de rango. Los datos de un String o Bytes son prestados y de solo lectura: cópialos para conservarlos.
- Un término dura hasta que la función devuelve: guárdalo en variables locales de C, nunca en datos estáticos, en memoria de `malloc` ni entre llamadas.
- `an_raise(env, message)` y `an_badarg(env, index)` hacen fallar la llamada, y también un constructor que recibe una entrada incorrecta (texto que no es UTF-8, una clave de Map que no es `Int`, `String` o `Bytes`, un tipo que la firma no alcanza). Entonces la llamada falla con `RUNTIME-NATIVE-ERROR` en la línea `def` cuando la función devuelve, sea lo que sea que devuelva; el lugar de la llamada está en la traza de pila. Un resultado de otro tipo que el de la firma también es `RUNTIME-NATIVE-ERROR`.
- Una fila de la tabla de recursos es el nombre, el tamaño de su estado de C, y la función que libera el estado (o `NULL`); su índice es el tipo de `an_resource_new` y `an_get_resource`. `an_resource_new(env, type, &term)` crea un recurso y da su estado puesto a cero; `an_get_resource(env, term, type, &state)` da el estado de un argumento de tipo recurso de la llamada. El estado guarda solo datos de C, nunca un término: aquí vive una caché de sentencias preparadas por conexión, y la liberación de la conexión las finaliza. La función de liberación recibe solo el estado, y la VM libera la memoria después.
- Una función dirty lee sus argumentos en su sitio. Un Int, Float, Bool o Void que crea, `none` y una variante sin payload son valores de inmediato, y los getters los leen. Cualquier otro término que crean sus constructores (un String, Bytes, List, Map, `some`, `ok`, `error`, estructura, variante con payload o recurso) se guarda aparte y se convierte en valor cuando la llamada devuelve, así que un getter da `false` para él.
- Una función corta se ejecuta en el planificador de la tarea llamadora, al mismo tiempo que las llamadas de otros planificadores, así que debe ser segura para hilos (o el programa la protege con [`Native.mutex()`](/library/io-and-system/native/)). Puede reservar memoria y crear resultados grandes, pero no debe bloquear, dormir, esperar E/S ni ejecutarse más de unos 100 microsegundos. Un callback de un bloque extern que ella inicia no ejecuta nada y da cero.
- `an_blocking(env, fn, arg)` (API 1.3) ejecuta `fn(arg)` donde el recolector no detiene el hilo: úsala alrededor de una llamada a una biblioteca de C que cambia a una pila propia, como una llamada `_start` o `_cont` de la API no bloqueante de MariaDB Connector/C. Funciona igual en funciones cortas y dirty. `fn` puede usar la memoria propia del módulo y el estado de un recurso que `an_get_resource` o `an_resource_new` dieron en la llamada, y leer los datos String y Bytes de los argumentos de la llamada que un getter dio antes; nada más de la VM: ningún término, ninguna escritura en memoria del GC, ninguna llamada a la API. Los datos de los argumentos duran hasta que la llamada devuelve: los datos que una biblioteca de C guarda entre llamadas (la consulta de un `_start` que después termina un `_cont`) se copian al estado del recurso o a otra memoria de `malloc`. En una función corta sigue ocupando el planificador, así que una llamada que espera pertenece a un `compute def`.
- `an_error(env, message, len)` crea un error de clase `error`. `an_error_kind(env, kind, message, len, keys, values, n)` (API 1.4) crea `error(message, kind: kind, details: {keys[k]: values[k]})` con `n` detalles (`NULL, NULL, 0` para ninguno); `kind` es un nombre con puntos como `db.constraint`, y la clase, las claves y los valores terminan en NUL. Una clase que no es un nombre con puntos, un `NULL` donde hace falta texto o un texto que no es UTF-8 hacen fallar la llamada. `an_get_error(env, term, &kind, &message, &details)` da la clase y el mensaje (Strings) y los detalles (un `Map[String, String]`) de un `Result` que es un error, `false` para `ok(...)` u otro término; pasa `NULL` por una parte que no necesite. `an_get_result` sigue dando el mensaje de un error como String, así que un módulo compilado para la API 1.3 sigue funcionando. Un módulo compilado con la cabecera de la API 1.4 necesita agentica 0.33.0 o posterior; uno más antiguo lo rechaza con `RUNTIME-NATIVE-LOAD`.
- El módulo no enlaza nada de `agentica`: cada llamada pasa por una tabla que le entrega la VM. Una tabla `build` en `[native.NAME]` de `agentica.toml` (`build = { sources = ["native/stats.c"] }`) hace que se compile con el compilador de C del sistema y con la cabecera del binario en ejecución (mira [Paquetes](/tour/modules/)). Con `optional = true` junto a ella, un módulo que no se puede compilar es una advertencia y el programa se ejecuta sin él, así que el paquete comprueba `Native.load("stats")` antes de llamar al módulo. Una tabla `prebuilt` junto a `build` (`prebuilt = { url, source, api, sha256 = { linux-x86_64 = "..." } }`) nombra los archivos que el autor del paquete compiló a partir de él, uno por destino; `agentica native source NAME` imprime la clave de código fuente, la API nativa y la URL de cada destino para la versión que los sube. La clave cubre la tabla `build` y cada archivo de `native/`, con CRLF leído como LF en un archivo que se decodifica como UTF-8, así que cualquier cambio en `native/` da a todos los módulos del paquete una clave nueva. `agentica install`, `add` y `update` descargan el archivo del destino del equipo a la caché de paquetes (como máximo 64 MiB, con redirecciones solo al host de la URL o a los hosts de archivos de release de GitHub); un archivo que no es el que nombra su `sha256` es `PKG-HASH-MISMATCH`, cualquier otra descarga fallida es una advertencia `PKG-FETCH`, y `--deny-net` o `--sandbox` no descargan nada. La `[native_policy]` del proyecto (`build` y `prebuilt_only`, cada uno `"all"` o una lista de nombres) dice qué módulos siempre se compilan, sin descargarse, y cuáles nunca, para los cuales una descarga fallida es un error. En el primer uso, un módulo usa su archivo descargado, sin compilador, cuando el destino tiene una fila, `api` carga y los archivos del paquete siguen dando la clave `source`; si no, se compila desde el código fuente, y un módulo `prebuilt_only` sin archivo es `PKG-NATIVE-BUILD` (ejecuta `agentica install`). `--native-build[=NAMES]` y `--native-prebuilt-only[=NAMES]`, y `AGENTICA_NATIVE_BUILD` y `AGENTICA_NATIVE_PREBUILT_ONLY` (`all` o `NAME,...`), van antes de la política del manifiesto, los flags primero. Para compilarlo tú mismo: en Linux `cc -std=c11 -shared -fPIC -o libstats.so stats.c`, en macOS `-dynamiclib`, en Windows `-shared` (una DLL), con el `include/agentica_native.h` del archivo de la versión que ejecuta el módulo.
- Un fallo en un módulo termina el programa, igual que un fallo en una biblioteca extern.
- El [perfil](/library/testing/profile/) (`AGENTICA_VM_TRACE=profile`) tiene una fila `native` por cada función del módulo que se ejecutó: sus llamadas, los microsegundos en C y su modo.
