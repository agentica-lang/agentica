---
title: Tipos y recursos
weight: 1
description: Los tipos de C de un bloque extern, funciones variádicas, lectura de memoria que devuelve C, búferes propios y memoria tipada, recursos que son propietarios de un puntero de C y arenas que los cierran, parámetros out, llamadas a través de punteros a función de C, callbacks que llama C, y estructuras de C pasadas por valor o por puntero.
source_hash: "cd64cf5ead72"
---

## Tipos {#types}

| Tipo de C | En C | En Agentica |
|---|---|---|
| `C.Int8`, `C.Int16`, `C.Int32`, `C.Int64` | `int8_t` a `int64_t` (`signed char`, `short`, `int`, un entero de 64 bits) | `Int` |
| `C.UInt8`, `C.UInt16`, `C.UInt32` | `uint8_t` a `uint32_t` (`unsigned char`, `unsigned short`, `unsigned int`) | `Int`, nunca negativo |
| `C.Long` | `long`: 32 bits en Windows, 64 en Linux y macOS | `Int` |
| `C.Double` | `double` | `Float` |
| `C.Float` | `float` (32 bits) | `Float` |
| `C.Bool` | `bool` | `Bool` |
| `C.String` | `const char *` | `String` |
| `C.Pointer` | `void *` | `C.Pointer` |
| `C.Bytes` | `const uint8_t *` (solo parámetros) | `Bytes` |
| `C.Function` | un puntero a función (solo el primer o el último parámetro, [abajo](#function-pointers)) | `C.Pointer` |
| una `struct` del bloque | una estructura pasada por valor ([abajo](#c-structs)) | esa estructura |

`C.Int` es `PARSE-EXTERN-TYPE`: escribe el ancho (`C.Int32` o `C.Int64`), o `C.Long` para un `long` de C. Un resultado puede ser `Void`, un bloque puede declarar recursos, y un parámetro puede ser un parámetro out (abajo). Una función acepta como máximo 64 parámetros (`PARSE-EXTERN-ARITY`).

- Un argumento entero toma los bits de su tipo, leídos con o sin signo, como lo hacen `Native.put_int8` a `put_int32`: un `C.Int8` o `C.UInt8` toma de -128 a 255, un `C.Int32` o `C.UInt32` de -2^31 a 2^32 - 1 (un `C.Long` igual en Windows, cualquier `Int` en otros sistemas). C recibe los bits bajos, así que `-1` es el `C.UInt32` 4294967295. Un valor fuera de rango falla con `RUNTIME-INTEGER-OVERFLOW`, y un `C.String` con un carácter NUL, con `RUNTIME-INVALID-CHARACTER`. Para un texto con un NUL o con una longitud conocida, usa `Native.from_string` y `bytesize` (abajo).
- Un resultado entero con signo se extiende con signo, y uno sin signo con ceros: un `C.UInt32` por encima de 2^31 es un `Int` positivo. No hay tipo de 64 bits sin signo: declara `uint64_t` o `size_t` como `C.Int64`, y `unsigned long` como `C.Long`. Cruzan los mismos bits, así que un valor por encima del máximo con signo se lee como negativo, como lo lee `read_i64` de `std/binary`.
- Un argumento `C.Float` se redondea al float de 32 bits más cercano (uno fuera de su rango se convierte en infinito). Un resultado `C.Float` se amplía a un `Float` (`0.1` vuelve como `0.10000000149011612`).
- C recibe una copia de cada cadena, válida solo durante la llamada. Un resultado `C.String` se copia; `NULL` da `""`, y los bytes que no son UTF-8 pasan a U+FFFD. Cuando el NULL importa, declara el resultado `-> C.Pointer` y léelo con `Native.get_string` (abajo).
- Un argumento `C.Bytes` es un `Bytes`: C recibe una copia, válida solo durante la llamada. Pasa la longitud (`b.size`) como un parámetro propio. Un resultado `C.Bytes` es `PARSE-EXTERN-TYPE`.
- Un `C.Pointer` es un puntero de C que tu programa pasa de vuelta a C. Puede ser NULL: `Native.null()` crea uno y `Native.null?(p)` lo comprueba. Los punteros no tienen `==`, e `IO.inspect` imprime `<C.Pointer>`.

## Funciones variádicas y nombres de C {#variadic-functions-and-c-names}

Una función variádica de C, como `int open(const char *path, int flags, ...)`, se declara con `...` donde empieza su parte variádica, seguido del tipo de C de cada argumento que pasan tus llamadas. Una cadena después del resultado da el nombre de C cuando es distinto del nombre de `def`, así que una misma función de C se puede declarar con varias formas:

```agentica {mode="check"}
extern "libc.so.6"
  def open(path: C.String, flags: C.Int32, ..., mode: C.Int32) -> C.Int32
  def fcntl_get(fd: C.Int32, cmd: C.Int32, ...) -> C.Int32 = "fcntl"
  def fcntl_set(fd: C.Int32, cmd: C.Int32, ..., arg: C.Int32) -> C.Int32 = "fcntl"
  def close(fd: C.Int32) -> C.Int32
end

def main() -> Void
  fd = open("/tmp/agentica-native.txt", 65, 384) # O_WRONLY | O_CREAT on Linux, mode 0600
  fcntl_set(fd, 2, 1) # F_SETFD, FD_CLOEXEC
  puts(fcntl_get(fd, 1)) # F_GETFD: 1
  close(fd)
end
```

- `...` va después de al menos un parámetro de C, sin contar un `C.Function` (`PARSE-EXTERN-VARIADIC-FIXED`). Aparece una sola vez, y solo en un bloque extern (`PARSE-EXTERN-VARIADIC`). La parte variádica puede estar vacía; los 64 parámetros cuentan las dos partes.
- Un parámetro variádico es `C.Int32`, `C.Int64`, `C.UInt32`, `C.Long`, `C.Double`, `C.String`, `C.Pointer`, `C.Bytes` o un recurso. `C.Bool`, `C.Int8`, `C.Int16`, `C.UInt8`, `C.UInt16` y `C.Float` son `PARSE-EXTERN-VARIADIC-TYPE`, porque C los promueve a `int` y `double`: escribe `C.Int32` o `C.Double`. Un parámetro out ahí también es `PARSE-EXTERN-VARIADIC-TYPE`.
- El nombre de C es una cadena simple de letras, dígitos y `_` (`PARSE-EXTERN-SYMBOL`).
- La llamada sigue la ABI variádica de C de cada sistema, que es distinta de una firma fija: en Apple arm64 los argumentos variádicos van a la pila, y en Windows x64 un `double` variádico también va en un registro entero (`ffi_prep_cif_var` de libffi). Declara una función variádica con `...`, nunca como una fija.

## Leer memoria que devuelve C {#reading-memory-that-c-returns}

Una función que devuelve un puntero y una longitud, o un texto que puede ser NULL, se declara con `-> C.Pointer`, y tu programa copia la memoria:

- `Native.get_string(p, offset)` copia el texto terminado en NUL que empieza `offset` bytes después de `p`. `Native.get_string(p, offset, length)` copia exactamente `length` bytes, incluidos los bytes NUL. Los bytes que no son UTF-8 pasan a U+FFFD.
- `Native.get_bytes(p, offset, length)` copia `length` bytes en un `Bytes`.
- Un `p` NULL con longitud 0 se lee como `""` o `[]`, como lo quiere C (SQLite da NULL para un blob vacío). Cualquier otro `p` NULL falla con `RUNTIME-NATIVE-NULL`, así que compruébalo antes con `Native.null?(p)`. Una longitud negativa falla con `RUNTIME-INVALID-COUNT`, después de comprobar el puntero. Una longitud más allá de la memoria que es de C es comportamiento indefinido, como una firma incorrecta: Agentica no la comprueba.
- `Native.pointer(n)` es el puntero con el valor entero `n`, para centinelas como `SQLITE_TRANSIENT`, que es `Native.pointer(-1)`.
- `Native.address(p)` es el valor entero de `p`. Los punteros no tienen `==`, así que compara direcciones, o resta dos punteros dentro de un mismo bloque de memoria para los bytes que hay entre ellos: `pzTail` de SQLite menos el texto SQL es cuánto leyó. La dirección de un búfer liberado falla con `RUNTIME-NATIVE-CLOSED`.

```agentica {mode="check"}
extern "libsqlite3.so.0"
  resource Db, free: sqlite3_close_v2
  def sqlite3_open(filename: C.String, out db: Db) -> C.Int32
  def sqlite3_exec(db: Db, sql: C.String, callback: C.Pointer, arg: C.Pointer, out errmsg: C.Pointer) -> C.Int32
  def sqlite3_free(p: C.Pointer) -> Void
end

def main() -> Void
  db = sqlite3_open(":memory:").db
  failed = sqlite3_exec(db, "select from nowhere", Native.null(), Native.null())
  if !Native.null?(failed.errmsg)
    puts(Native.get_string(failed.errmsg, 0)) # near "from": syntax error
    sqlite3_free(failed.errmsg)
  end

  Native.close(db)
end
```

## Búferes propios y memoria tipada {#owned-buffers-and-typed-memory}

Una función de C que escribe en memoria que le da el llamador, como `char *getcwd(char *buf, size_t size)`, o que lee un arreglo de flotantes, recibe un búfer propio. `Native.memory_pointer(size)` reserva `size` bytes puestos a cero y los da como un `C.Pointer`, así que el búfer va donde vaya un parámetro `C.Pointer`:

```agentica {mode="check"}
extern "libc.so.6"
  def getcwd(buf: C.Pointer, size: C.Int64) -> C.Pointer
end

def main() -> Void
  Native.memory_pointer(4096) do |buf|
    if !Native.null?(getcwd(buf, 4096))
      puts(Native.get_string(buf, 0))
    end
  end
end
```

- La forma de bloque, `Native.memory_pointer(size) do |buf| ... end`, da el búfer al bloque y lo libera al terminar el bloque, también cuando el bloque termina antes con un error que devuelve `try`. La llamada devuelve el valor del bloque. Un error de runtime en el bloque detiene la tarea, y el final de la tarea libera el búfer. Un búfer que el bloque entrega a otra tarea con `Task.spawn_owning` no se libera al final del bloque: su nuevo propietario lo libera.
- La forma simple, `buf = Native.memory_pointer(size)`, es para un búfer que dura más que un bloque, como uno que C guarda entre llamadas. Un búfer que nunca se libera vive hasta que termina su tarea, así que un bucle que crea búferes sin liberarlos crece. Libera cada uno cuando C haya terminado con él.
- La tarea llamadora es propietaria de un búfer simple como de un recurso: `Native.free(buf)` lo libera una vez (liberarlo otra vez no hace nada), y el final de la tarea libera lo que no liberó. `free` termina un búfer como `Native.close` termina un recurso. El final de la ejecución libera un búfer que sigue abierto, como libera un recurso (abajo).
- `Task.spawn_owning(&work, buf)` entrega el búfer a la nueva tarea, cuyo final lo libera. Enviarlo por un canal o devolverlo desde una tarea no lo mueve: se libera cuando termina su propietario. Un tamaño negativo, uno que el sistema no puede dar y cualquier tamaño por encima de 256 TiB (2^48 bytes) fallan con `RUNTIME-INVALID-COUNT`.
- Una llamada `compute def` mantiene sus argumentos de búfer hasta que devuelve, así que una liberación mientras tanto espera a la llamada. Leer o escribir el búfer mientras corre una llamada así tienen una carrera con C: espera primero a la llamada.
- Un búfer liberado hace fallar toda lectura, escritura o llamada posterior con `RUNTIME-NATIVE-CLOSED`, y `Native.closed?(buf)` es `true`. Un `C.Pointer` que dio C nunca se cierra (el NULL incluido: compruébalo con `Native.null?`). `Native.free` de un puntero que dio C falla con `RUNTIME-NATIVE-NOT-OWNED`: libéralo con la función de su biblioteca.
- Los nombres siguen la gema `ffi` de Ruby (`FFI::MemoryPointer.new(size)` y su forma de bloque, `MemoryPointer.from_string(text)`, `get_int32(offset)`, `get_string(offset)`, `put_array_of_float32(offset, values)`), como funciones `Native.*` que reciben el puntero primero.

Una función de C que recibe texto con su longitud, como `sqlite3_bind_text`, `PQexecParams` o `mysql_real_query`, recibe un búfer de `Native.from_string(text)` (`MemoryPointer.from_string` de la gema ffi de Ruby) y `text.bytesize`. El búfer guarda los bytes UTF-8 del texto y un NUL después de ellos, así que su tamaño es `text.bytesize + 1`. Un NUL dentro del texto se copia como cualquier otro byte, algo que un `C.String` rechaza. Un puntero que C devuelve dentro del texto, como el `pzTail` de SQLite, sigue siendo válido mientras viva el búfer: `Native.address(tail) - Native.address(buf)` es cuántos bytes leyó C. Es un búfer propio como los demás, con la misma forma de bloque y las mismas reglas.

```agentica {mode="check"}
extern "libsqlite3.so.0"
  resource Db, free: sqlite3_close_v2
  resource Stmt, free: sqlite3_finalize
  def sqlite3_open(filename: C.String, out db: Db) -> C.Int32
  def sqlite3_prepare_v2(db: Db, sql: C.Pointer, bytes: C.Int32, out stmt: Stmt, out tail: C.Pointer) -> C.Int32
end

def main() -> Void
  db = sqlite3_open(":memory:").db
  sql = "SELECT 1; SELECT 2"
  Native.from_string(sql) do |buf|
    prepared = sqlite3_prepare_v2(db, buf, sql.bytesize)
    puts(Native.address(prepared.tail) - Native.address(buf))
    Native.close(prepared.stmt)
  end

  Native.close(db)
end
```

Las lecturas y escrituras tipadas toman un desplazamiento en bytes desde cualquier `C.Pointer`, un búfer o uno que devolvió C. El desplazamiento no necesita estar alineado:

| Leer | Escribir | Elemento |
|---|---|---|
| `Native.get_int8(p, offset)`, `get_int16`, `get_int32`, `get_int64` | `Native.put_int8(p, offset, value)`, `put_int16`, `put_int32`, `put_int64` | entero con signo, `Int` |
| `Native.get_uint8(p, offset)`, `get_uint16`, `get_uint32` | las formas `put_int` | entero sin signo, `Int` |
| `Native.get_float32(p, offset)`, `get_float64` | `Native.put_float32(p, offset, value)`, `put_float64` | `float` o `double`, `Float` |
| `Native.get_pointer(p, offset)` | `Native.put_pointer(p, offset, value)` | `void *`, `C.Pointer` |
| `Native.get_array_of_int32(p, offset, count)`, `_int64`, `_float32`, `_float64` | `Native.put_array_of_int32(p, offset, values)`, `_int64`, `_float32`, `_float64` | una `List[Int]` o `List[Float]` |
| `Native.get_string(p, offset)` (arriba) | `Native.put_string(p, offset, text)` | texto y un NUL, una cadena de C |
| `Native.get_bytes(p, offset, length)` (arriba) | `Native.put_bytes(p, offset, bytes)` | un `Bytes` |

- Una forma `put_int` toma un valor que cabe en sus bits, leído con o sin signo: `put_int8` toma de -128 a 255. Cualquier otro valor falla con `RUNTIME-INTEGER-OVERFLOW`. Un `put_array_of_*` comprueba cada elemento antes de escribir el primero.
- `put_string` escribe los bytes del texto y un NUL después de ellos; un NUL en el texto falla con `RUNTIME-INVALID-CHARACTER`. Las cadenas de C propias y un arreglo de punteros a ellas (`const char *const *`) también son búferes. `put_pointer` guarda una dirección que nadie rastrea: mantén sin liberar el búfer al que apunta mientras C lo usa.

```agentica {mode="check"}
extern "/opt/model/libmodel.so"
  def model_inputs(names: C.Pointer, count: C.Int64, data: C.Pointer) -> C.Int32
end

def main() -> Void
  name = Native.memory_pointer(6)
  Native.put_string(name, 0, "input")
  names = Native.memory_pointer(8)
  Native.put_pointer(names, 0, name)
  data = Native.memory_pointer(4 * 3)
  Native.put_array_of_float32(data, 0, [0.5, 1.5, 2.5])
  puts(model_inputs(names, 1, data))
  puts(Native.get_array_of_float32(data, 0, 3))
end
```

- Un búfer conoce su tamaño: una lectura o escritura que empieza antes de él o se pasa de su final falla con `RUNTIME-NATIVE-BOUNDS`, y también `Native.get_string` de un búfer sin NUL después del desplazamiento. Nunca se lee ni se escribe nada fuera del búfer.
- Un puntero que devolvió C no tiene tamaño. Uno NULL falla con `RUNTIME-NATIVE-NULL` (un arreglo o `get_bytes` de cantidad 0 está vacío), y un desplazamiento negativo con `RUNTIME-NATIVE-BOUNDS`. Cualquier otro desplazamiento se acepta. La memoria más allá de lo que es de C es comportamiento indefinido, como una firma incorrecta: toma el tamaño de la biblioteca. Dos tareas que leen y escriben la misma memoria de C a la vez tienen una carrera, como en C; cada lectura o escritura de un búfer propio toma un bloqueo.
- Una cantidad o un tamaño negativos fallan con `RUNTIME-INVALID-COUNT`.

`Native.offset(p, n)` es el puntero `n` bytes después de `p`, para estructuras de C cuyos campos apuntan a un mismo bloque de memoria, como las celdas `length`, `is_null` y `buffer` de un bind de MySQL:

- Para un puntero que devolvió C es la suma simple (con vuelta al desbordar), aceptada igual que `p`.
- Para un búfer propio es una vista de la misma memoria desde el byte `n` hasta el final del búfer. `n` fuera del rango de 0 al tamaño falla con `RUNTIME-NATIVE-BOUNDS`, y las lecturas y escrituras a través de la vista se comprueban contra su rango. Una vista de una vista toma su desplazamiento de la vista y termina donde termina el búfer.
- La vista pertenece a su búfer: liberar el búfer la cierra (`RUNTIME-NATIVE-CLOSED`, `Native.closed?` es `true`). Una llamada `compute def` que recibe la vista mantiene el búfer hasta que devuelve. `Native.free` de una vista falla con `RUNTIME-NATIVE-NOT-OWNED`, y `Task.spawn_owning` entrega el búfer, no una vista.

```agentica {mode="check"}
extern "/opt/db/libdb.so"
  def db_bind(length: C.Pointer, is_null: C.Pointer, data: C.Pointer) -> C.Int32
end

def main() -> Void
  Native.memory_pointer(16 + 8) do |bind|
    Native.put_int64(bind, 0, 5)
    Native.put_string(bind, 16, "hello")
    puts(db_bind(bind, Native.offset(bind, 8), Native.offset(bind, 16)))
  end
end
```

## Recursos {#resources}

Un recurso es un puntero de C que tu programa posee, como un flujo abierto o una conexión a una base de datos. `resource Name, free: c_function` en el bloque declara su tipo y la función de C, de la misma biblioteca, que lo libera, como `void c_function(void *)`. En Windows, `GetProcAddress` busca solo las exportaciones de esa DLL, así que `free: free` (una función de una dependencia, como el runtime de C) es `RUNTIME-NATIVE-LOAD` allí, aunque Linux y macOS la encuentran: declara la función de liberación desde la biblioteca que la exporta. El nombre es como en C y puede empezar con mayúscula, como `PQfinish` o `SSL_free`; solo se lee como tipo el `C.Function` con punto (abajo).

`resource Name, free_ref: c_function` declara un recurso cuya función de liberación recibe una referencia al puntero (su dirección, como la da `Fiddle::Pointer#ref` de Ruby), como `void c_function(void **)`. `duckdb_close` y `duckdb_disconnect` son funciones así. Cada liberación pasa esa dirección, una vez, y la función puede escribir NULL allí. Un recurso tiene una sola función de liberación: `free:` y `free_ref:` juntos son `PARSE-EXTERN-FREE`.

```agentica {mode="check"}
extern "libc.so.6"
  ## A C stream.
  resource Stream, free: fclose
  def fopen(path: C.String, mode: C.String) -> Stream
  def fputs(text: C.String, stream: Stream) -> C.Int32
end

def main() -> Void
  stream = fopen("/tmp/agentica-native.txt", "w").unwrap!
  fputs("hello\n", stream)
  Native.close(stream)
  IO.inspect(fopen("/no/such/dir/file", "r")) # error("fopen returned NULL")
end
```

- Una función declarada `-> Stream` da un `Result[Stream]`: un resultado NULL es `error("fopen returned NULL")`, cualquier otro es `ok` con un recurso que la tarea llamadora posee.
- `Native.close(stream)` ejecuta la función de liberación una vez y cierra el recurso; cerrarlo otra vez no hace nada. Una llamada que recibe un recurso cerrado falla con `RUNTIME-NATIVE-CLOSED`, antes de copiar ningún argumento.
- `Native.closed?(stream)` nunca detiene la tarea, así que un envoltorio puede devolver un `error` en su lugar. Es `true` después de `Native.close` (en cualquier tarea), después del final de la tarea que poseía el recurso (también una tarea que lo devolvió), y para un recurso out NULL. Es `false` para uno vivo, también mientras una llamada `compute def` lo retiene; cerrado durante esa llamada, es `true` de inmediato. `true` es definitivo; `false` puede quedar desactualizado de inmediato si otra tarea puede cerrar el recurso.
- Un recurso que la tarea no cerró se libera cuando la tarea termina (al volver, por fallo o por cancelación), como un archivo. `Task.spawn_owning(&work, stream)` lo entrega a la nueva tarea.
- Una llamada nativa en marcha, `def` o `compute def`, mantiene sus argumentos de recurso hasta que devuelve: si el recurso se cierra mientras tanto, o si se cancela la tarea de una llamada `compute def`, la liberación se ejecuta cuando termina la llamada. También mantiene de dónde viene cada uno de ellos, un nivel hacia arriba y no más: los recursos y búferes que tomó la llamada que lo creó, menos uno del que viene otro de ellos. Así, `mysql_stmt_execute(stmt)` mantiene el `Handle` que tomó `mysql_stmt_init(handle)`, una fila creada por `next(ctx, x)` mantiene solo `x`, ya que `x` viene de `ctx`, y un `Native.close(handle)` desde otra tarea durante esa llamada libera el handle cuando la llamada devuelve. Un recurso cerrado durante la llamada mantiene a su vez de dónde viene hasta su propia liberación. Uno abierto no: con `env`, después `conn` desde él, después `stmt` desde `conn`, un `Native.close(env)` mientras `conn` está abierto libera `env` de inmediato, así que cierra los hijos antes que sus padres: `conn` primero, y `x` antes que `ctx`.
- Cualquier tarea puede pasar a C un recurso o un búfer propio, por ejemplo uno que recibió por una closure o un canal: nada comprueba quién lo posee. Solo el final del propietario o su [arena](#arenas) lo libera, y `Native.close` o `Native.free` de cualquier tarea lo cierra para todas. Dos tareas dentro de C sobre el mismo objeto a la vez tienen una carrera, como en C; `sqlite3_interrupt` o `duckdb_interrupt` desde otra tarea es el uso previsto.
- Una función de liberación que bloquea (`mysql_close`, un `duckdb_close` que hace un checkpoint) se ejecuta en el planificador al llamar a `Native.close` o al final del propietario, como una llamada `def`, y detiene las demás tareas.
- Cada propietario libera sus recursos del más nuevo al más antiguo. Un padre entregado a otra tarea con `Task.spawn_owning` puede liberarse antes que sus hijos: cierra primero los hijos, o mantén un padre y sus hijos en una misma tarea.
- Cuando termina la ejecución (`main` devuelve, `System.exit`, un fallo de `main`, el límite de pasos, o la primera [señal de parada](/library/io-and-system/files/)), una llamada compute que no ha empezado nunca se hace, los programas hijos se detienen, los archivos se escriben, y la ejecución espera a las llamadas `compute def` en marcha que retienen un recurso. Después se libera cada recurso y búfer que siga abierto, del más nuevo al más antiguo (el orden inverso al de apertura), sea cual sea la tarea que lo posea. Las liberaciones se detienen en el primer recurso que una llamada en marcha todavía retiene y nunca lo saltan, así que ese y todos los más antiguos quedan sin liberar. Así, el `stream` de arriba guarda lo que escribió `fputs` aunque no haya `Native.close`. Un recurso que una llamada así devuelve en ese punto nunca se libera.
- Después de una señal, la ejecución no espera a esas llamadas, y lo que retienen no se libera. La espera y las liberaciones comparten el límite de vaciado de archivos (30 segundos, `--flush-timeout MS`): una llamada o una función de liberación que tarda más se deja atrás, el código de salida se mantiene, y stderr recibe una línea que dice que los recursos nativos quizá no se liberen. Con `--flush-timeout 0` no se libera nada. Una segunda señal termina la ejecución de inmediato.
- Cada resultado de recurso es un puntero nuevo que tu programa posee. Una función que devuelve un puntero que su biblioteca guarda (uno prestado) debe declararse con `-> C.Pointer`, o el puntero se libera dos veces. La función de liberación tampoco puede declararse con `def` en su bloque (`PARSE-EXTERN-FREE`); la comprobación es por bloque, así que no la declares en otro bloque tampoco.
- Un recurso es un tipo: se puede importar como el bloque, y sus líneas van antes de las funciones que lo usan. Los recursos y `C.Pointer` no se convierten uno en otro. `IO.inspect` imprime `<Stream>`; un recurso no tiene `to_s` ni JSON.

### Arenas {#arenas}

`Native.arena do ... end` ejecuta el bloque y devuelve su valor. Al terminar el bloque, cierra cada recurso y búfer propio (incluidos los callbacks y recursos de módulos nativos) que la tarea abrió mientras corría el bloque, salvo los que su valor retiene. Un bucle que crea muchos recursos intermedios, como los tensores de un paso de entrenamiento, los libera después en un punto conocido, sin un `Native.close` para cada uno.

```agentica {mode="check"}
extern "libc.so.6"
  resource Stream, free: fclose
  def fopen(path: C.String, mode: C.String) -> Stream
  def fputs(text: C.String, stream: Stream) -> C.Int32
end

def main() -> Void
  kept = Native.arena do
    log = fopen("/tmp/agentica-log.txt", "w").unwrap!
    fputs("step\n", log)
    fopen("/tmp/agentica-out.txt", "w").unwrap!
  end # log is closed here

  fputs("result\n", kept)
  Native.close(kept)
end
```

- Lo que sale del bloque es lo que retiene su valor, en sus campos de estructura, payloads de enum, `Result`, elementos de `List` y valores de `Map` (el recorrido de `Task.spawn_owning`). Un recurso retenido también retiene los recursos de los que viene, hasta arriba (una sentencia retiene su base de datos), y una vista retenida retiene su búfer. Un recurso que creó una función de un módulo nativo marcada `AN_FRESH` no viene de nada, así que no retiene nada más ([módulos nativos](/library/io-and-system/native/modules/)). Un recurso que solo captura una función o lambda devuelta se cierra.
- El resto se cierra del más nuevo al más antiguo, en orden inverso a la apertura, mediante `Native.close`: una llamada nativa en marcha que retiene uno lo mantiene hasta que la llamada devuelve, y usarlo después falla con `RUNTIME-NATIVE-CLOSED`.
- Una arena dentro de otra le da lo que retiene a la exterior, que lo cierra al final de la suya salvo que su valor también lo retenga.
- Un `try` que falla en el bloque devuelve su error desde el bloque, y la arena cierra todo lo que el error no retiene. Un error de runtime o una cancelación terminan la tarea, y el final de la tarea cierra lo que posee, del más nuevo al más antiguo.
- La arena cierra solo lo que la tarea todavía posee: un recurso entregado con `Task.spawn_owning` pertenece a la nueva tarea. Un recurso que otra tarea recibió por un canal o una closure se cierra para todas al final del bloque, y sus llamadas posteriores con él fallan con `RUNTIME-NATIVE-CLOSED`.

## Parámetros out {#out-parameters}

Una función de C que da un valor por un puntero, como `int sqlite3_open(const char *filename, sqlite3 **db)`, declara ese parámetro con `out`. El llamador no lo pasa: C escribe en un hueco que se pone a cero antes de la llamada, y la llamada devuelve un registro con el resultado de C como `result` y un campo por cada parámetro out, con su mismo nombre.

- El registro es una estructura con el nombre de la función en CamelCase (`sqlite3_open` da `Sqlite3Open`), pública junto con su función. El registro de una función `Void` no tiene `result`.
- Un parámetro out es un tipo entero, `C.Double`, `C.Float`, `C.Bool`, `C.Pointer` o un recurso del bloque; cualquier otra cosa es `PARSE-EXTERN-OUT`. Para un `char **`, usa un `C.Pointer` out.
- Un recurso out es el propio recurso, no un `Result`. Cuando C escribió un puntero, la tarea llamadora lo posee, igual que con un resultado de recurso. Cuando C escribió NULL o dejó el hueco intacto, es un recurso que ya está cerrado: nadie lo libera, `Native.close` no hace nada, y una llamada con él falla con `RUNTIME-NATIVE-CLOSED`. Comprueba `result` antes de usarlo, o `Native.closed?`: `sqlite3_prepare_v2` da `SQLITE_OK` y una sentencia NULL para un SQL que es solo un comentario.
- Una llamada `compute def` cancelada descarta su registro; un recurso out que C creó se libera cuando la llamada devuelve.

## Punteros a función {#function-pointers}

Algunas bibliotecas dan sus funciones como una tabla de punteros a función de C, no por nombre: `OrtGetApiBase()->GetApi(version)` de onnxruntime da la estructura `OrtApi`, y cada llamada es `api->CreateEnv(...)`. Un `def` cuyo primer parámetro es `fn: C.Function` llama a la función en esa dirección, con la firma que declara el `def` (`FFI::Function.new(ret, params, pointer)` de la gema ffi de Ruby). Lee la dirección de la tabla con `Native.get_pointer`. Un puntero ocupa 8 bytes en todos los sistemas con llamadas nativas.

```agentica {mode="check"}
# The slots of struct plugin_api in plugin.h, in order.
OPEN = 0
READ = 1
CLOSE = 2

extern "/opt/plugin/libplugin.so"
  ## A handle that the close slot of the table frees.
  resource Handle, free: C.Function
  def plugin_api(version: C.Int32) -> C.Pointer
  def open(fn: C.Function, path: C.String, out handle: Handle, free: C.Function) -> C.Int32
  compute def read(fn: C.Function, handle: Handle, buf: C.Pointer, size: C.Int64) -> C.Int64
end

def slot(api: C.Pointer, index: Int) -> C.Pointer = Native.get_pointer(api, index * 8)

def main() -> Void
  api = plugin_api(1)
  opened = open(slot(api, OPEN), "/tmp/data", slot(api, CLOSE))
  if opened.result == 0
    Native.memory_pointer(64) do |buf| puts(read(slot(api, READ), opened.handle, buf, 64)) end

    # calls the close slot once
    Native.close(opened.handle)
  end
end
```

- Los demás parámetros, el resultado, los parámetros out, los recursos y `compute def` funcionan como para una función que se encuentra por nombre. El `def` no tiene nombre de C: `= "symbol"` es `PARSE-EXTERN-FUNCTION`.
- `resource Name, free: C.Function` declara un recurso cuya función de liberación también es un puntero a función, como `api->ReleaseSession`. El `def` que crea uno, como su resultado o como un parámetro out, toma esa dirección como último parámetro, después de cualquier parámetro `out`: `free: C.Function`. Un único parámetro `C.Function` de un `def` que devuelve ese recurso es su función de liberación, no la función que se llama: `def thing_new(free: C.Function) -> Thing` llama a `thing_new` por nombre (una llamada a través de un puntero que crea uno toma dos parámetros `C.Function`). `Native.close`, el final de la tarea propietaria y un resultado de `compute def` descartado la llaman una vez, como para una función de liberación encontrada por nombre. Una llamada crea como mucho un recurso así.
- Un `C.Function` es el primer parámetro (la función a llamar) o el último (la función de liberación). En cualquier otro lugar es `PARSE-EXTERN-FUNCTION`. Nunca es un resultado, un parámetro out ni un parámetro variádico. El programa lo ve como un `C.Pointer`. Los nombres de los parámetros son libres: `fn` y `free` son una convención.
- Una dirección NULL hace fallar la llamada con `RUNTIME-NATIVE-NULL` antes de que se ejecute C, y un búfer propio con `RUNTIME-NATIVE-BOUNDS`. Cualquier otra dirección se acepta: una que no es una función de la firma declarada es comportamiento indefinido, como una firma incorrecta.
- Un bloque extern cuyas funciones se llaman todas a través de un puntero nunca abre su biblioteca, así que una ruta de biblioteca incorrecta no se informa.

## Callbacks {#callbacks}

Algunas funciones de C reciben una función tuya a la que llaman de vuelta: `qsort` una comparación, SQLite una collation o un update hook. `callback Name(params) -> result` en el bloque declara el tipo de C de ese puntero a función (`callback` de la gema ffi de Ruby), y `Native.callback(Name, &function)` crea uno a partir de una función de tu programa:

```agentica {mode="check"}
extern "libsqlite3.so.0"
  resource Db, free: sqlite3_close_v2
  callback Compare(arg: C.Pointer, a_len: C.Int32, a: C.Pointer, b_len: C.Int32, b: C.Pointer) -> C.Int32
  def sqlite3_open(filename: C.String, out db: Db) -> C.Int32
  def sqlite3_create_collation(db: Db, name: C.String, enc: C.Int32, arg: C.Pointer, cmp: Compare) -> C.Int32
end

def by_length(arg: C.Pointer, a_len: Int, a: C.Pointer, b_len: Int, b: C.Pointer) -> Int = a_len - b_len

def main() -> Void
  db = sqlite3_open(":memory:").db
  cmp = Native.callback(Compare, &by_length)
  puts(sqlite3_create_collation(db, "by_length", 1, Native.null(), cmp))
  Native.close(db)
  Native.close(cmp)
end
```

- Un callback recibe un tipo entero, `C.Double`, `C.Float`, `C.Bool`, `C.String` o `C.Pointer`, y devuelve uno de ellos salvo `C.String`, o `Void`. Cualquier otra cosa es `PARSE-EXTERN-TYPE`: pasa una estructura, un arreglo o bytes como `C.Pointer` y léelo con `Native.get_*`. No tiene valor predeterminado, ni parámetro `out` ni `...`.
- La función se nombra con `&` y recibe y devuelve los tipos de Agentica del callback (`C.Int32` es `Int`); cualquier otra cosa es `CHECK-TYPE-MISMATCH`. Un valor `Fn` es `CHECK-NATIVE-CALLBACK`, y un bloque también se rechaza, porque pueden guardar valores de su alcance; igual con una función de un bloque extern, ya que un callback no puede esperar. Pasa el contexto por el argumento de datos de usuario `void *` que las bibliotecas de C dan para ello.
- El callback es un recurso de su tipo: `Native.close`, `Native.closed?` y `Task.spawn_owning` lo reciben, y no se convierte a ni desde un `C.Pointer`.
- Un `def` del bloque recibe el callback como parámetro de su tipo, también en la parte variádica. No es un resultado ni un parámetro `out`. Para un puntero a función que puede ser NULL, como la función step de una función escalar de SQLite, declara el parámetro `Optional[Name]` y pasa `none` para NULL o `some(cb)`.
- C llama al callback durante una llamada nativa: la función se ejecuta entonces, en la tarea que hizo la llamada, y C espera su valor. Un argumento `C.String` se copia, y NULL se lee como `""`. Un resultado fuera de su tipo de C es `RUNTIME-INTEGER-OVERFLOW`.
- La función no puede esperar mientras C espera por ella: `Task.sleep`, un canal, una llamada a archivo o red, una llamada `compute def`, o una impresión que debe esperar tras la impresión de otra tarea es `RUNTIME-NATIVE-CALLBACK`. Una impresión que solo espera a que se vacíe el búfer de salida espera en su sitio.
- Cuando la función falla o termina, C recibe cero de ella, y cero de los callbacks posteriores de esa llamada nativa, que no se ejecutan; la llamada nativa entonces falla o termina del mismo modo cuando C devuelve.
- Un callback que C llama desde un hilo propio, o desde la función de liberación de un recurso (`xDestroy` de SQLite cuando se ejecuta `sqlite3_close_v2`), no ejecuta nada y da cero. Un `compute def` se ejecuta en el grupo de hilos de cómputo, donde un callback también da cero, y esa llamada falla entonces con `RUNTIME-NATIVE-CALLBACK`.
- Un callback que tarda mucho se detiene cuando su tarea se cancela o termina la ejecución: C recibe cero, y la tarea termina después de la llamada nativa. Los callbacks se anidan como mucho 128 niveles; el siguiente es `RUNTIME-STACK-OVERFLOW`.
- Después de `Native.close`, o del final de la tarea que posee el callback, C todavía puede llamarlo (un handler que guardó, una función de liberación como el `xDestroy` de SQLite): recibe cero y la función no se ejecuta, sea cual sea el orden de los cierres. El código que C llama se genera una vez por cada función y tipo de callback y se guarda hasta que termina la ejecución, así que la memoria está acotada por el número de funciones de callback distintas, no por los callbacks creados; mientras otro callback de la misma función y del mismo tipo esté abierto, una llamada al código viejo ejecuta la función, lo que es inofensivo porque no toma capturas. En un `compute def` la llamada también da cero y falla con `RUNTIME-NATIVE-CALLBACK`.

## Estructuras de C {#c-structs}

Una función de C que recibe o devuelve una estructura por valor, como `llama_context_default_params()` de llama.cpp, necesita la estructura declarada con `struct` dentro del bloque, con sus campos en el orden de la cabecera de C (`FFI::Struct` con `layout` de la gema ffi de Ruby). Tu programa ve una estructura normal: crea una, lee sus campos, y cambia uno con `.with`. Una llamada la copia a memoria de C, y un resultado de estructura se copia de vuelta a un registro nuevo.

```agentica {mode="check"}
extern "/opt/geo/libgeo.so"
  struct Point
    x: C.Double
    y: C.Double
  end

  struct Shape
    origin: Point
    sides: C.Int32
    scale: C.Float = 1.0
    filled: C.Bool
    tag: C.Pointer
  end

  def geo_default_shape() -> Shape
  def geo_area(shape: Shape) -> C.Double
  compute def geo_grow(shape: Shape, by: C.Double) -> Shape
end

def main() -> Void
  shape = geo_default_shape()
  bigger = shape.with(sides: 6, origin: shape.origin.with(x: 2.5))
  puts(geo_area(bigger))
  puts(geo_grow(bigger, 2.0).scale)
  puts(geo_area(Shape(origin: Point(x: 0.0, y: 0.0), sides: 3, filled: true, tag: Native.null())))
end
```

- Un campo es un tipo entero, `C.Double`, `C.Float`, `C.Bool`, `C.Pointer` o una estructura declarada antes en el mismo bloque. Tu programa ve `Int`, `Float`, `Bool`, `C.Pointer` o esa estructura. Cualquier otra cosa es `PARSE-EXTERN-TYPE`: `C.String`, `C.Bytes`, `C.Function` y los recursos no sobrevivirían a la copia. Declara un campo `char *` como `C.Pointer` y lee su texto con `Native.get_string`. Un campo de arreglo fijo (`char name[16]`) todavía no se puede declarar.
- La estructura tiene la disposición que le da el compilador de C del sistema, con el relleno incluido. Declara cada campo de la cabecera, en su orden: una lista de campos incorrecta es comportamiento indefinido, como una firma incorrecta. Una estructura tiene al menos un campo (`PARSE-EXTERN-TYPE`) y como máximo 1024, contando los anidados, en como máximo 16 niveles (`PARSE-EXTERN-ARITY`).
- Una estructura es un parámetro o un resultado, también de un `compute def` y de una llamada a través de un puntero a función. No es un parámetro out (`PARSE-EXTERN-OUT`; para una estructura que llena C, pasa un `C.Pointer` a un búfer propio y léelo con `Native.get_struct`, [abajo](#structs-through-pointers)) ni un parámetro variádico (`PARSE-EXTERN-VARIADIC-TYPE`).
- Cada campo de un argumento se comprueba como se comprueba un argumento, antes de que se ejecute C: un entero fuera de los bits de su tipo falla con `RUNTIME-INTEGER-OVERFLOW`, un `C.Float` se redondea, y un búfer propio liberado en un campo `C.Pointer` falla con `RUNTIME-NATIVE-CLOSED`. Un campo `C.Bool` de un resultado es `true` cuando su byte no es 0.
- Un campo `C.Pointer` es una dirección que nadie rastrea: la memoria que nombra debe durar más que el uso de C. Una llamada `compute def` mantiene los búferes propios de los campos de sus estructuras que son argumentos hasta que devuelve, igual que mantiene sus argumentos de búfer.
- La estructura es un tipo del bloque, que se usa después de su declaración (`PARSE-EXTERN-TYPE` antes). Se puede importar como el bloque. Los valores predeterminados de los campos funcionan como en cualquier estructura. Un bloque que declara una estructura ocupa el lugar de los tipos como un todo, igual que un bloque con un recurso.

### Estructuras a través de punteros {#structs-through-pointers}

Una estructura de C que está en memoria, como un arreglo de binds de MySQL o el resultado que llena `duckdb_query`, se lee y se escribe con la estructura del bloque (`Struct.size` y `Struct.new(pointer)` de la gema ffi de Ruby):

- `Native.size_of(Name)` es el tamaño de la estructura en bytes, tal como lo da `sizeof` de C en este sistema, con el relleno incluido: un campo `C.Long` hace que difiera entre Windows y los demás. El elemento `k` de un arreglo de C de estructuras está en `k * Native.size_of(Name)`.
- `Native.get_struct(p, offset, Name)` lee la estructura que está a `offset` bytes después de `p` en un registro nuevo, igual que se lee un resultado de estructura.
- `Native.put_struct(p, offset, value)` escribe ahí el registro, como se escribe un argumento de estructura. Cada campo se comprueba antes de escribir el primer byte: un entero fuera de sus bits falla con `RUNTIME-INTEGER-OVERFLOW`, un búfer liberado en un campo `C.Pointer` con `RUNTIME-NATIVE-CLOSED`. Un búfer guardado en un campo `C.Pointer` es una dirección que nadie rastrea, igual que con `put_pointer`.
- Los límites son los de las lecturas y escrituras tipadas de arriba, para el tamaño de la estructura: se comprueban en un búfer propio o una vista, y se aceptan en un puntero que devolvió C.
- El tipo es una estructura de un bloque extern, o un alias de tipo de una. Cualquier otro tipo, o un valor en lugar del nombre del tipo, es `CHECK-TYPE-MISMATCH`.

```agentica {mode="check"}
extern "/opt/db/libdb.so"
  struct Bind
    buffer: C.Pointer
    length: C.Long
    is_null: C.Bool
  end

  def db_bind_params(binds: C.Pointer, count: C.Int32) -> C.Int32
end

def main() -> Void
  size = Native.size_of(Bind)
  Native.memory_pointer(2 * size) do |binds|
    Native.memory_pointer(8) do |text|
      Native.put_string(text, 0, "hello")
      Native.put_struct(binds, 0, Bind(buffer: text, length: 5, is_null: false))
      Native.put_struct(binds, size, Bind(buffer: Native.null(), length: 0, is_null: true))
      puts(db_bind_params(binds, 2))
      puts(Native.get_struct(binds, size, Bind).is_null)
    end
  end
end
```
