---
title: Envolver una biblioteca de C
weight: 5
description: Oculta los hábitos de C de una biblioteca (códigos de retorno, punteros out, argumentos variádicos) tras una API normal de Agentica, y entrégala en un paquete.
source_hash: "35b71cc3c343"
---

C le da forma a una biblioteca de C. Tiene códigos de retorno, punteros que C llena, handles con una función de liberación y funciones variádicas. Un buen envoltorio oculta todo eso. El bloque `extern` es la capa cruda. Las funciones públicas encima de ella se ven como el resto de Agentica. [SQLite](/library/io-and-system/native/sqlite/) es una biblioteca completa hecha así. Esta página da las reglas. Los ejemplos nombran las bibliotecas de Linux (`libc.so.6`, `libm.so.6`).

## Dos capas {#two-layers}

La capa cruda es un bloque `extern` por biblioteca. Copia cada firma de la cabecera de C y conserva los nombres de C. Un nombre no tiene `?` ni `!` (`PARSE-EXTERN-NAME`). La capa cruda no forma parte de tu API. La capa pública es Agentica simple. Un `String` con un carácter NUL detiene el programa al cruzar a C (`RUNTIME-INVALID-CHARACTER`), así que un envoltorio que no debe detenerse comprueba antes sus entradas `String`; los ejemplos omiten esa comprobación.

| En C | En la API pública |
|---|---|
| Un código de retorno o un NULL | `Result[T]`, con un texto de error que nombra el valor incorrecto |
| Un handle y la función que lo libera | un [recurso](/library/io-and-system/native/types/#resources), devuelto en un `Result` |
| Un `int` que responde sí o no | una función llamada `name?` que devuelve `Bool` |
| Un puntero que C llena | un [parámetro `out`](/library/io-and-system/native/types/#out-parameters), convertido en los campos de tu propia estructura |
| Memoria que da el llamador y C llena | un `String` o una `List` copiados de un bloque `Native.memory_pointer` (ver más abajo Búferes y formas de bloque) |
| Una llamada que puede tardar | un [`compute def`](/library/io-and-system/native/compute/) en la capa cruda, para que las demás tareas sigan ejecutándose; el envoltorio la llama como a cualquier función |
| Una función variádica | funciones de una forma normal (ver más abajo Funciones variádicas) |
| Una estructura de opciones pasada por valor, con una función que da los valores predeterminados | una estructura propia con las opciones que puede fijar el llamador, copiada a la [estructura de C](/library/io-and-system/native/types/#c-structs) por el envoltorio (ver más abajo Estructuras de opciones) |
| Una tabla de punteros a función (`api->CreateEnv(...)`) | llamadas a [`C.Function`](/library/io-and-system/native/types/#function-pointers) en la capa cruda, con los huecos como constantes del envoltorio (ver más abajo Tablas de punteros a función) |

Un bloque con un recurso o una estructura va con los tipos del archivo, arriba y antes de cada función, y sus `def` no cuentan como funciones en el orden de declaración (`CHECK-DECL-ORDER`). Así, el envoltorio puede ir en el mismo archivo que el bloque. El bloque es público como cualquier declaración, así que el llamador puede nombrar el tipo, y los `def` crudos también se pueden importar. Un bloque sin ninguno de los dos no tiene esa regla. Sus `def` cuentan como funciones, así que va al final del archivo, después de `private` cuando los `def` crudos no forman parte de la API, como en los ejemplos que siguen a este.

```agentica {mode="check"}
extern "libc.so.6"
  resource Stream, free: fclose
  def fopen(path: C.String, mode: C.String) -> Stream
  def fputs(text: C.String, stream: Stream) -> C.Int32
  compute def fflush(stream: Stream) -> C.Int32
  def isatty(fd: C.Int32) -> C.Int32
end

## Opens a file for appending, or says which path failed.
def open_append(path: String) -> Result[Stream]
  case fopen(path, "a")
    Result.Ok(stream) -> ok(stream)
    Result.Err(_) -> error("cannot open #{path}")
  end
end

## Writes one line.
def write_line(stream: Stream, text: String) -> Result[Void]
  return error("cannot write to the stream") if fputs("#{text}\n", stream) < 0

  ok()
end

## Pushes the buffered text to the file.
def flush(stream: Stream) -> Result[Void]
  return error("cannot flush the stream") if fflush(stream) != 0

  ok()
end

## True when the descriptor is a terminal.
def tty?(fd: Int) -> Bool = isatty(fd) == 1
```

`fopen` se declara con `-> Stream`, así que la llamada cruda ya da un `Result[Stream]`. El envoltorio solo cambia su mensaje por uno que nombra la ruta. `Stream` es público, así que el llamador puede nombrar el tipo. El llamador cierra el flujo con `Native.close`, o la tarea que lo posee lo libera al terminar. `fflush` es un `compute def` en la capa cruda, y `flush` la llama como a cualquier función.

## Parámetros out {#out-parameters}

Un parámetro `out` se queda en la capa cruda: el envoltorio copia los campos del registro a una estructura propia.

```agentica {mode="check"}
struct Split
  whole: Float
  fraction: Float
end

## Splits x into its whole part and its fraction, both with the sign of x.
def split(x: Float) -> Split
  parts = modf(x)
  Split(whole: parts.whole, fraction: parts.result)
end

private

extern "libm.so.6"
  def modf(x: C.Double, out whole: C.Double) -> C.Double
end
```

## Búferes y formas de bloque {#buffers-and-block-forms}

Una función de C que llena memoria que le da el llamador, como `getcwd`, usa un [búfer propio](/library/io-and-system/native/types/#owned-buffers-and-typed-memory). El envoltorio lo crea con la forma de bloque, `Native.memory_pointer(size) do |buf| ... end`, que libera el búfer al terminar el bloque, también cuando el bloque devuelve un error antes de tiempo, y devuelve el valor del bloque. El bloque copia lo que escribió C, así que el llamador recibe un `String` o una `List` y nunca ve el búfer.

```agentica {mode="check"}
## The working directory, or an error when it is longer than 4095 bytes.
def cwd() -> Result[String]
  Native.memory_pointer(4096) do |buf|
    return error("the working directory is longer than 4095 bytes") if Native.null?(getcwd(buf, 4096))

    ok(Native.get_string(buf, 0))
  end
end

private

extern "libc.so.6"
  def getcwd(buf: C.Pointer, size: C.Int64) -> C.Pointer
end
```

Un envoltorio puede dar a un recurso una forma de bloque propia, como lo hace `File.open` de Ruby: abre el recurso, se lo da al bloque, lo cierra al terminar el bloque y devuelve lo que devolvió el bloque, así que el llamador no puede olvidar el cierre. Si el bloque se detiene con un error de runtime, el final de la tarea libera el recurso.

```agentica {mode="check"}
extern "libc.so.6"
  resource Stream, free: fclose
  def fopen(path: C.String, mode: C.String) -> Stream
  def fputs(text: C.String, stream: Stream) -> C.Int32
end

## Opens a file for appending, gives the stream to the block and closes it when the block ends.
def append_to(path: String, f: Fn[Stream, Result[Void]]) -> Result[Void]
  stream = try fopen(path, "a")
  done = f.call(stream)
  Native.close(stream)
  done
end

def main() -> Void
  written = append_to("/tmp/agentica-log.txt") do |stream|
    return error("cannot write the log") if fputs("started\n", stream) < 0

    ok()
  end

  IO.inspect(written)
end
```

## Funciones variádicas {#variadic-functions}

Las funciones de Agentica no tienen parámetros variádicos, y un envoltorio no añade ninguno. Declara la función de C una vez por cada [forma](/library/io-and-system/native/types/#variadic-functions-and-c-names) que necesite tu envoltorio, con `...` y `= "symbol"`, y mantén las formas privadas. La función pública toma un parámetro normal en su lugar:

- Parámetros con valores predeterminados, cuando un argumento es opcional (`on: Bool = true`).
- Una estructura, cuando hay muchas opciones. Dale a sus campos valores predeterminados. El llamador nombra solo los campos que cambian: `OpenOptions(create: true)`, o `OpenOptions()` para todos los predeterminados.
- Una `List[T]`, cuando cambia la cantidad de argumentos. El envoltorio elige la forma según la longitud de la lista y devuelve un `error` para una longitud para la que no tiene forma.

```agentica {mode="check"}
## Read only by default, and mode 0600 when the file is created.
struct OpenOptions
  write: Bool = false
  create: Bool = false
  mode: Int = 384
end

## Opens a file and gives its descriptor.
def open_file(path: String, options: OpenOptions) -> Result[Int]
  flags = 0
  if options.write
    flags = flags + O_WRONLY
  end

  if options.create
    flags = flags + O_CREAT
  end

  fd = open(path, flags, options.mode)
  return error("cannot open #{path}") if fd < 0

  ok(fd)
end

## Sets or clears close-on-exec.
def set_close_on_exec(fd: Int, on: Bool = true) -> Result[Void]
  flag = 0
  if on
    flag = FD_CLOEXEC
  end

  return error("cannot set close-on-exec on #{fd}") if fcntl_set(fd, F_SETFD, flag) < 0

  ok()
end

## Writes one or two fields to fd, separated by a tab and ended by a newline.
def write_fields(fd: Int, fields: List[String]) -> Result[Void]
  written = -1
  if fields.length == 1
    written = dprintf1(fd, "%s\n", fields[0])
  elsif fields.length == 2
    written = dprintf2(fd, "%s\t%s\n", fields[0], fields[1])
  end

  return error("cannot write #{fields.length} fields to #{fd}") if written < 0

  ok()
end

private

O_WRONLY = 1
O_CREAT = 64 # the Linux value; macOS uses 0x200
F_SETFD = 2
FD_CLOEXEC = 1

extern "libc.so.6"
  def open(path: C.String, flags: C.Int32, ..., mode: C.Int32) -> C.Int32
  def fcntl_set(fd: C.Int32, cmd: C.Int32, ..., arg: C.Int32) -> C.Int32 = "fcntl"
  def dprintf1(fd: C.Int32, format: C.String, ..., a: C.String) -> C.Int32 = "dprintf"
  def dprintf2(fd: C.Int32, format: C.String, ..., a: C.String, b: C.String) -> C.Int32 = "dprintf"
end
```

`open_file` da un descriptor; el ejemplo omite una función que lo cierra. `write_fields` nunca deja que el llamador elija el formato. El formato es una constante del envoltorio, y el texto del llamador entra como argumentos `%s`, así que un `%` en un campo es solo texto.

## Estructuras de opciones {#structs-of-options}

Algunas bibliotecas reciben sus opciones como una estructura por valor, con una función que da los predeterminados: llama.cpp tiene `llama_context_default_params()` y `llama_init_from_model(model, params)`. La capa cruda declara la estructura de C en el bloque, con cada campo en el orden de la cabecera ([estructuras de C](/library/io-and-system/native/types/#c-structs)). El envoltorio toma los predeterminados, fija los campos que eligió el llamador con `.with`, y pasa el registro. El llamador solo ve una estructura propia, con las opciones que puede fijar.

```agentica {mode="check"}
struct ContextOptions
  size: Int = 4096
  threads: Int = 4
end

extern "/opt/infer/libinfer.so"
  resource Model, free: infer_model_free
  resource Context, free: infer_free
  struct ContextParams
    n_ctx: C.Int32
    n_batch: C.Int32
    n_threads: C.Int32
    rope_freq_base: C.Float
    embeddings: C.Bool
    offload: C.Bool
    callback_data: C.Pointer
  end

  def infer_context_default_params() -> ContextParams
  compute def infer_init_from_model(model: Model, params: ContextParams) -> Context
end

## A context of the model with the caller's options; the other parameters keep the library's defaults.
def context(model: Model, options: ContextOptions) -> Result[Context]
  params = infer_context_default_params().with(n_ctx: options.size, n_threads: options.threads)
  case infer_init_from_model(model, params)
    Result.Ok(made) -> ok(made)
    Result.Err(_) -> error("cannot make a context of #{options.size} tokens")
  end
end
```

Un tamaño que no cabe en un `C.Int32` detiene el programa en la llamada (`RUNTIME-INTEGER-OVERFLOW`), así que un envoltorio que no debe detenerse comprueba antes las opciones; el ejemplo omite esa comprobación.

## Tablas de punteros a función {#tables-of-function-pointers}

Una biblioteca cuya API es una estructura de punteros a función, como onnxruntime, se envuelve igual. La capa cruda declara cada hueco que usa el envoltorio como un `def` cuyo primer parámetro es `fn: C.Function`, y cada handle como `resource Name, free: C.Function`, liberado a través del hueco de liberación de la tabla. El envoltorio obtiene la tabla una vez, guarda los números de hueco como constantes en el orden de la cabecera de C, y pasa `Native.get_pointer(api, slot * 8)` a los `def` crudos, así que el llamador nunca ve un puntero a función. Un número de hueco de otra versión de la cabecera es comportamiento indefinido, como una firma incorrecta: pide la versión de la que vienen los huecos, como lo hace `GetApi(version)` de onnxruntime, y convierte su NULL en un `error`.

## Entregarla en un paquete {#shipping-it-in-a-package}

Un paquete nombra la biblioteca para cada sistema en `[native.NAME]` de su `agentica.toml`. Su bloque `extern` la abre después con `extern "NAME"`. Mira la [referencia de módulos](/reference/modules/) para la forma, el lock y los códigos de error. Documenta el archivo del envoltorio como la API del paquete.
