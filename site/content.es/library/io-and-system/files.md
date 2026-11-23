---
title: File, Dir y Path
weight: 2
description: Lee y escribe archivos, lista y crea directorios, y crea rutas.
source_hash: "3853f815a06d"
---

Cada función de archivo recibe un tiempo de espera en milisegundos y devuelve un `Result`. Su valor predeterminado es 30000, y puede omitirse. `File.open` también toma `"read"` como modo predeterminado, y `File.each_line` y `File.foreach` toman 65536 como predeterminado de `buffer_bytes`.

- El texto es UTF-8. Una llamada de texto lee o escribe como máximo 1 MiB (`File.sha256` lee bytes en flujo y no tiene límite). Los archivos tienen los permisos del usuario que ejecuta el programa.
- Con `--deny-fs` (o `--sandbox`), cada llamada de esta página, salvo `Path.join`, `Lazy.write_lines` y `Lazy.write_bytes`, devuelve un error que empieza por `denied: --deny-fs`.
- Los archivos regulares usan un grupo de 4 hilos, compartido con las consultas DNS y la carga de certificados TLS, así que las llamadas esperan a que haya un hilo libre cuando se ejecutan muchas. Auméntalo (como máximo 1024) antes de que empiece el programa: `UV_THREADPOOL_SIZE=16 agentica app.agc`.
- Las tuberías, las FIFO y las terminales no usan el grupo y esperan en el bucle de eventos, así que su tiempo de espera siempre termina la espera. `File.read_text` de una tubería lee hasta que el escritor la cierra.
- Las llamadas de archivo aceptan archivos regulares y los enlaces simbólicos a ellos, y también FIFO, tuberías y dispositivos que pueden esperar. Rechazan los directorios, una ruta que no existe para una lectura, y una ruta que vuelve a abrir una tubería que la VM creó para sí misma. `File` es un nombre reservado, con los miembros `File.Handle` y `File.Info`; un handle de archivo es opaco.

## File.write_text {#filewrite_text}

```signature
File.write_text(path: String, text: String, timeout_ms: Int = 30000) -> Result[Void]
```

Crea o reemplaza un archivo con el texto.

```agentica {mode="check"}
def main() -> Void
  r = File.write_text("notes.txt", "first line\n", 1000)
  puts(r)
end
```

```text
ok()
```

## File.replace {#filereplace}

```signature
File.replace(path: String, data: Bytes, timeout_ms: Int = 30000) -> Result[Void]
```

Reemplaza un archivo regular existente con como máximo 16 MiB de bytes en un solo paso, así que un lector ve el archivo antiguo o el nuevo, nunca una parte ni ningún archivo. Úsalo para guardar un archivo que la gente edita, como hace `agentica fmt`.

```agentica {mode="check"}
def main() -> Void
  r = File.replace("notes.txt", "second draft\n".bytes, 1000)
  puts(r)
end
```

- Los bytes van a un archivo nuevo en la misma carpeta, que solo el propietario puede leer mientras se escribe; después toma los bits de permiso del archivo antiguo, se vacía en el disco y se renombra sobre él. Un fallo quita el archivo nuevo y deja el antiguo como estaba. Un proceso terminado a la fuerza durante la escritura puede dejar un archivo oculto `.agc-PID-N.tmp` en la carpeta. Escribir necesita permiso de escritura en la carpeta.
- Un enlace simbólico se sigue y sigue siendo un enlace: se reemplaza el archivo al que apunta. El archivo nuevo pertenece al usuario que ejecuta el programa, y un enlace físico al archivo antiguo conserva los bytes antiguos.
- El archivo debe existir y ser un archivo regular: una ruta que falta da `error("filesystem: cannot resolve path ...")`, y un directorio o una FIFO dan `error("filesystem: path does not refer to a regular file")`. Usa `File.write_text` para crear un archivo.
- En Windows, un archivo de solo lectura es un error, y no se escribe nada. De los atributos del archivo antiguo solo se conserva el bit de solo lectura: la ACL viene de la carpeta, y los atributos de oculto y de sistema se descartan.

## File.append_text {#fileappend_text}

```signature
File.append_text(path: String, text: String, timeout_ms: Int = 30000) -> Result[Void]
```

Añade texto al final de un archivo. Crea el archivo si no existe.

## File.read_text {#fileread_text}

```signature
File.read_text(path: String, timeout_ms: Int = 30000) -> Result[String]
```

Lee un archivo entero como texto.

```agentica {mode="check"}
def main() -> Void
  case File.read_text("notes.txt", 1000)
    ok(text) -> puts("#{text.strip.split("\n").size} lines")
    error(message) -> IO.warn("cannot read: #{message}")
  end
end
```

## File.sha256 {#filesha256}

```signature
File.sha256(path: String, timeout_ms: Int = 30000) -> Result[Bytes]
```

Calcula el hash de un archivo entero con SHA-256 y devuelve los 32 bytes del resumen criptográfico como un [`Bytes`](/library/data-structures/bytes/), los mismos bytes que da `OpenSSL.Digest.sha256` para el mismo contenido; `OpenSSL.Digest.hexencode` los escribe en hexadecimal. Lee el archivo en trozos de 64 KiB, así que un archivo que supera con mucho el límite de texto de 1 MiB también se puede calcular.

```agentica {mode="check"}
def main() -> Void
  case File.sha256("notes.txt", 1000)
    ok(digest) -> puts(OpenSSL.Digest.hexencode(digest))
    error(message) -> IO.warn("cannot hash: #{message}")
  end
end
```

- Solo se calculan los archivos regulares; los enlaces simbólicos se siguen. Una ruta que falta, un directorio, una FIFO, una tubería o un dispositivo dan `error("filesystem: path does not refer to a regular file")`, igual que `File.read_text`.
- `timeout_ms` cubre la llamada entera y debe ser positivo, si no `error("filesystem: timeout must be positive milliseconds")`. Cuando se agota, la llamada devuelve `error("filesystem: operation timed out")` y el hash en curso se descarta. Una tarea cancelada se quita de la misma forma.
- No hay instantánea: un escritor concurrente cambia el resumen criptográfico. Para verificar una descarga, escríbela con un nombre temporal, calcula su hash y después muévela a su sitio con `Path.rename` o `Path.replace`.

## File.stat {#filestat}

```signature
File.stat(path: String, timeout_ms: Int = 30000) -> Result[File.Info]
```

Devuelve un `File.Info`: `kind`, `size_bytes`, `modified_seconds`, `mode`, `user_id`, `group_id`. Un enlace simbólico se sigue.

- `kind` usa el nombre de `File::Stat#ftype` de Ruby: `"file"` (solo un archivo regular), `"directory"`, `"fifo"`, `"socket"`, `"characterSpecial"` (como `/dev/null`), `"blockSpecial"` o `"unknown"`. Windows da `"file"`, `"directory"`, `"link"` (`File.lstat` de un punto de reanálisis) y `"characterSpecial"` para `NUL`. Comprueba `kind == "file"` antes de leer una ruta que tú no creaste: una lectura de una FIFO puede esperar a un escritor.

- `mode` son los bits de permiso como un `Int`, con setuid, setgid y sticky: `rw-------` es 384 (octal 600).
- Windows no tiene bits de Unix ni ids de propietario: `mode` es solo el atributo de solo lectura (438 escribible, 292 de solo lectura; no dice nada sobre la ACL), y `user_id` y `group_id` son siempre 0, que no es el propietario.

```agentica {mode="check"}
def main() -> Void
  info = File.stat("notes.txt", 1000).unwrap!
  puts("#{info.kind}: #{info.size_bytes} bytes, mode #{info.mode}")
end
```

## File.lstat {#filelstat}

```signature
File.lstat(path: String, timeout_ms: Int = 30000) -> Result[File.Info]
```

Igual que `File.stat`, pero no sigue el enlace simbólico: `kind` es `"link"`, `size_bytes` es la longitud del texto del enlace, y los demás campos son los del propio enlace.

## File.open y File.close {#fileopen-and-fileclose}

```signature
File.open(path: String, mode: String = "read", timeout_ms: Int = 30000) -> Result[File.Handle]
File.close(handle: File.Handle, timeout_ms: Int = 30000) -> Result[Void]
```

Abre un archivo para trabajar en flujo.

| Modo | Significado |
|---|---|
| `"read"` | leer un archivo existente |
| `"write"` | crear el archivo, o vaciarlo |
| `"append"` | escribir al final del archivo |
| `"create_private"` | un archivo nuevo que solo tú puedes leer y escribir |

`"create_private"` falla cuando la ruta ya existe (también un enlace colgado) y nunca sigue un enlace, así que otro usuario no puede desviar la escritura. En Unix: modo 0600, o menos cuando la umask quita bits. En Windows: una DACL protegida que solo concede acceso al usuario actual; la creación falla salvo que el objeto abierto tenga ese propietario y esa DACL.

`close` escribe los datos pendientes. Cerrar dos veces está bien. Los tiempos de espera son milisegundos positivos e incluyen la espera del bloqueo del handle: un tiempo de espera durante una E/S activa cierra el handle, y uno mientras se espera el bloqueo lo deja abierto.

- Un archivo pertenece a la tarea que lo abrió y se cierra, con sus datos escritos, cuando esa tarea termina. `Task.await` de esa tarea devuelve el control después de que se escriban los datos de un archivo regular (no un vaciado a una FIFO o a una tubería), así que un padre que espera a un auxiliar lee todo lo que este escribió. Un `close` sobre un archivo que ya se está cerrando espera a ese cierre.
- Al final del programa, la ejecución espera a que se escriban los archivos abiertos y a que la salida de `puts` e `IO.warn` llegue a su tubería o a su archivo, como máximo 30 segundos (`--flush-timeout MS` o `AGENTICA_FLUSH_TIMEOUT_MS`; el flag tiene prioridad). Cuando se acaba el tiempo, el código de salida se mantiene y el error estándar recibe una línea que dice que los datos del archivo podrían no escribirse.
- Ante `SIGINT`, `SIGTERM`, `SIGHUP`, `SIGUSR1` o `SIGUSR2` a los que el programa no se ha suscrito ([`System.subscribe`](/library/io-and-system/system/#systemsubscribe)): primero se detienen los procesos hijos, después se escriben los archivos y luego el programa termina por esa señal. `SIGQUIT` hace lo mismo y termina con código 131, sin volcado de núcleo. Una segunda señal lo termina de inmediato, cuando los hijos ya se hayan detenido. Con `agentica`, Ctrl-C llega directamente al programa; `agentica` espera 2 segundos, envía `SIGTERM`, espera 2 más y después lo mata.
- Una ruta que vuelve a abrir una de las tuberías internas del programa, o el descriptor que hay detrás de stdout o stderr (`/proc/self/fd/5`), da `error("filesystem: path does not refer to a regular file")`. Las tuberías que el programa recibió al empezar (stdin, stdout, stderr, un `<(...)` de la shell) se abren por ruta.
- Windows: las llamadas de archivo solo aceptan archivos regulares (y carpetas donde se pretende una carpeta); una tubería con nombre o un dispositivo se rechazan de inmediato.

```agentica {mode="check"}
def main() -> Void
  file = File.open("out.txt", "write", 1000).unwrap!
  _ = File.write(file, "hello\n", 1000)
  closed = File.close(file, 1000)
  puts(closed.ok?)
end
```

## File.open con un bloque {#fileopen-with-a-block}

```signature
File.open(path: String, mode: String = "read", timeout_ms: Int = 30000) do |file| ... end -> Result[T]
```

Abre el archivo, llama al bloque con el handle, cierra el handle con `File.close(file, timeout_ms)` cuando termina el bloque, y devuelve el `Result` del bloque. Úsalo para leer o escribir un archivo a través de un handle; abre y cierra un handle a mano solo cuando deba sobrevivir a un bloque, como uno compartido con tareas.

```agentica {mode="check"}
def main() -> Void
  r = File.open("out.txt", "write", 1000) do |file|
    try File.write(file, "hello\n")
    try File.write(file, "world\n")
    ok(2)
  end

  puts(r)
end
```

- El bloque devuelve un `Result[T]`, y `try` funciona en él. `T` viene del tipo esperado de la llamada (`r: Result[List[String]] = File.open(...) do ...`), o si no, del bloque. Un bloque que nunca devuelve `ok` (solo devuelve `error(...)`) no fija ningún `T`, y el `error(...)` del bloque es `CHECK-RESULT-TYPE` hasta que la variable tenga un tipo: `r: Result[Int] = File.open(...) do ... end`.
- `timeout_ms` limita la apertura y el cierre, cada uno por su lado; no limita el bloque, así que la llamada entera puede tardar más que `timeout_ms`. Las llamadas dentro del bloque tienen sus propios tiempos de espera.
- Si la apertura falla, el bloque no se ejecuta y la llamada devuelve el error de apertura.
- El handle se cierra tanto si el bloque devuelve `ok` como si devuelve `error`, incluidos un `return` anticipado y un `try` fallido. Después de `ok(value)`, la llamada devuelve `ok(value)`, o el error de cierre si el cierre falla: el cierre escribe los datos pendientes, así que su error importa. Después de un error, la llamada devuelve el error del bloque y descarta un error de cierre.
- Un error de runtime en el bloque termina la tarea, y el handle se cierra con la tarea, como se dijo antes. Un handle que se guarda después del bloque (devuelto en el `Result`) está cerrado: una llamada sobre él da `error("filesystem: file handle is closed")`.

## File.write y File.flush {#filewrite-and-fileflush}

```signature
File.write(handle: File.Handle, text: String, timeout_ms: Int = 30000) -> Result[Void]
File.flush(handle: File.Handle, timeout_ms: Int = 30000) -> Result[Void]
```

`write` añade texto a un archivo abierto. `flush` vacía al disco lo que está en búfer.

```agentica {mode="check"}
def save_lines(path: String, lines: List[String]) -> Result[Void]
  file = try File.open(path, "write", 1000)
  for line in lines
    try File.write(file, line + "\n", 1000)
  end

  try File.flush(file, 1000)
  File.close(file, 1000)
end

def main() -> Void
  puts(save_lines("list.txt", ["a", "b"]))
end
```

## File.try_lock {#filetry_lock}

```signature
File.try_lock(handle: File.Handle, timeout_ms: Int = 30000) -> Result[Bool]
```

Toma un bloqueo exclusivo sobre el archivo abierto, sin esperar. `ok(true)` significa que es tuyo (también si este handle ya lo tiene), y `ok(false)` que otro handle o proceso lo tiene.

- Termina cuando el handle se cierra, cuando termina la tarea que lo abrió o cuando termina el programa, aunque se haya terminado a la fuerza. Un hijo de `Process.spawn` no lo retiene. No hay ninguna llamada para desbloquear.
- Unix: consultivo (`flock`), así que solo detiene el código que también lo pide. Windows: `LockFileEx` sobre todo el rango, y el sistema operativo rechaza las lecturas y escrituras a través de otros handles.
- Funciona cualquier modo de handle. Solo se puede bloquear un archivo regular (una tubería, una FIFO o `/dev/null` dan error).

```agentica {mode="check"}
def main() -> Void
  file = File.open("app.lock", "append", 1000).unwrap!
  if File.try_lock(file, 1000).unwrap!
    puts("running alone")
  else
    puts("another copy is running")
  end

  _ = File.close(file, 1000)
end
```

## File.read_line {#fileread_line}

```signature
File.read_line(handle: File.Handle, timeout_ms: Int = 30000) -> Result[String]
```

Lee una línea sin su terminador (LF o CRLF; una última línea sin terminador también cuenta). El texto es UTF-8 estricto. Al final del archivo, o ante un UTF-8 no válido, devuelve un resultado de error. Recorre con `while line.ok?`, o usa `File.each_line`.

## File.each_line {#fileeach_line}

```signature
File.each_line(path: String, buffer_bytes: Int = 65536, timeout_ms: Int = 30000) do |line| ... end -> Result[Void]
```

Llama al bloque con cada línea, sin su terminador (LF y CRLF; una última línea sin terminador también se pasa). El archivo nunca se lee entero, así que funciona un archivo más grande que la memoria, y también las FIFO y las tuberías. El archivo se cierra por cualquier vía de salida.

- El bloque devuelve un `Result[Void]`: `ok()` sigue, y un `error(...)` se detiene y es el resultado. `try` y `return error(...)` funcionan en el bloque.
- `buffer_bytes` es la línea más larga, contando su terminador: de 1024 a 16777216; si no, `RUNTIME-INVALID-COUNT` antes de abrir el archivo. Una línea más larga termina la llamada con `error("filesystem: line exceeds buffer_bytes")`.
- `timeout_ms` limita cada lectura, la apertura y el cierre, no la llamada entera. Debe ser positivo, si no `error("filesystem: timeout must be positive milliseconds")`. Una tubería sin datos termina la llamada con un error.
- El texto es UTF-8 estricto: los bytes no válidos terminan la llamada con un error.
- Para encadenar pasos sobre las líneas (`select`, `map`, `first(n)` ...), usa [`File.foreach`](/library/data-structures/lazy/#fileforeach), un `Lazy[String]` con las mismas lecturas. Para escribir las líneas de un `Lazy[String]` en un archivo, usa [`write_lines`](/library/data-structures/lazy/#write_lines).

```agentica {mode="check"}
def main() -> Void
  r = File.each_line("notes.txt", 4096, 1000) do |line|
    return error("comment found: #{line}") if line.start_with?("#")

    ok()
  end

  puts(r)
end
```

## File.read_bytes y File.write_bytes {#fileread_bytes-and-filewrite_bytes}

```signature
File.read_bytes(handle: File.Handle, max_bytes: Int, timeout_ms: Int = 30000) -> Result[Bytes]
File.write_bytes(handle: File.Handle, bytes: Bytes, timeout_ms: Int = 30000) -> Result[Void]
```

Ambos reciben y devuelven un [`Bytes`](/library/data-structures/bytes/). `read_bytes` lee de 1 a 1048576 bytes y devuelve bytes vacíos al final del archivo; `write_bytes` escribe como máximo 1048576 bytes por llamada.

```agentica {mode="check"}
def main() -> Void
  out = File.open("data.bin", "write", 1000).unwrap!
  _ = File.write_bytes(out, Bytes.from_list([0, 1, 255]).unwrap!, 1000)
  _ = File.close(out, 1000)
  input = File.open("data.bin", "read", 1000).unwrap!
  puts(File.read_bytes(input, 16, 1000).unwrap!.to_a)
end
```

```text
[0, 1, 255]
```

## File.seek {#fileseek}

```signature
File.seek(handle: File.Handle, offset: Int, timeout_ms: Int = 30000) -> Result[Void]
```

Mueve un handle de lectura a `offset` bytes desde el inicio del archivo, así que la siguiente `read_bytes` o `read_line` empieza ahí. Úsalo para leer una parte de un archivo grande, como un tensor de un checkpoint, sin leer lo que va antes.

```agentica {mode="check"}
def main() -> Void
  input = File.open("data.bin", "read", 1000).unwrap!
  _ = File.seek(input, 2, 1000)
  puts(File.read_bytes(input, 16, 1000).unwrap!.to_a)
end
```

- Un offset después del final es válido: la siguiente `read_bytes` devuelve bytes vacíos, como al final del archivo.
- Un offset negativo detiene el programa con `RUNTIME-INDEX-OUT-OF-RANGE` en el offset.
- Solo un handle abierto con `"read"` puede hacer seek; un handle de escritura, de `"append"` o de `"create_private"` devuelve `error("filesystem: only a handle open for reading can seek")`. Una tubería, un FIFO o una terminal devuelve `error("filesystem: cannot seek a pipe, FIFO or terminal")`.
- El seek descarta lo que el handle había leído por adelantado, así que la siguiente lectura siempre empieza en `offset`.

## Dir.list {#dirlist}

```signature
Dir.list(path: String, timeout_ms: Int = 30000) -> Result[List[String]]
```

Devuelve los nombres de un directorio, ordenados.

```agentica {mode="check"}
def main() -> Void
  for name in Dir.list(".", 1000).unwrap!
    puts(name)
  end
end
```

## Dir.mkdir {#dirmkdir}

```signature
Dir.mkdir(path: String, timeout_ms: Int = 30000) -> Result[Void]
```

Crea un directorio y los padres que falten. Un directorio que ya existe está bien.

## Dir.mkdir_private {#dirmkdir_private}

```signature
Dir.mkdir_private(path: String, timeout_ms: Int = 30000) -> Result[Void]
```

Crea un directorio al que solo tú puedes entrar, para un directorio temporal en un lugar compartido como `/tmp`. No crea padres, y una ruta que ya existe es un error, así que el éxito significa que el directorio es nuevo y tuyo. Unix: modo 0700, o menos cuando la umask quita bits. Windows: la comprobación de propietario y DACL de `File.open`.

```agentica {mode="check"}
def main() -> Void
  name = "/tmp/app-#{Random.int(0, 999999999)}"
  case Dir.mkdir_private(name, 1000)
    ok(_) -> puts("made #{name}")
    error(message) -> IO.warn("cannot make it: #{message}")
  end
end
```

## Path.join {#pathjoin}

```signature
Path.join(list: List[String]) -> Result[String]
```

Une las partes con el separador del sistema.

```agentica
def main() -> Void
  puts(Path.join(["build", "reports", "a.txt"]))
end
```

```output
ok("build/reports/a.txt")
```

## Path.cwd and Path.resolve {#pathcwd-and-pathresolve}

```signature
Path.cwd() -> Result[String]
Path.resolve(path: String) -> Result[String]
```

`cwd` devuelve el directorio actual. `resolve` crea una ruta absoluta, sin seguir enlaces. Ninguna termina en `/` salvo en una raíz; `resolve` conserva una `/` final solo cuando la ruta termina en una.

## Path.real {#pathreal}

```signature
Path.real(path: String) -> Result[String]
```

Como `realpath` de POSIX: la ruta absoluta con cada enlace simbólico resuelto y los `.`, `..` y separadores repetidos quitados. A diferencia de `resolve`, lee el disco, así que la ruta debe existir (una ruta que falta, un bucle de enlaces o algo que no es un directorio dan error). Una ruta relativa empieza en el directorio de trabajo, y un `..` después de un enlace sigue el destino del enlace. Una ruta vacía o con NUL da el mismo error `filesystem: invalid path` que `File.stat`. La VM no pone límite de búfer a la ruta; se aplica el límite del propio sistema a su forma absoluta. Los bytes UTF-8 no válidos se convierten en U+FFFD. No tiene tiempo de espera; se ejecuta en el grupo de hilos de archivos y no detiene otras tareas.

Se ven las reglas propias del sistema:

- macOS falla con una ruta de 1024 bytes o más, y acepta una `/` después de un archivo (`file/` da el archivo); Linux y Windows dan error para ella.
- Windows quita `.` y `..` del texto escrito antes de seguir un enlace, así que `link/..` es la carpeta que contiene el enlace y `missing/..` no es un error. Un nombre bajo un archivo da ENOENT (Linux y macOS: ENOTDIR). El resultado empieza por una letra de unidad (`/` es la unidad del directorio de trabajo, como `C:/`). El binario activa las rutas largas en su manifiesto. Una ruta de 260 caracteres o más solo funciona cuando la máquina pone `LongPathsEnabled` a 1; si no, es un error, como lo es `Dir.mkdir` de una así.

```agentica
def main() -> Void
  puts(Path.real("/"))
  puts(Path.real("/does/not/exist").ok?)
end
```

```output
ok("/")
false
```

## Path.remove {#pathremove}

```signature
Path.remove(path: String, timeout_ms: Int = 30000) -> Result[Void]
```

Quita un archivo, un enlace simbólico o un directorio con todo lo que contiene. Una ruta que falta devuelve `ok()`.

- Nunca sigue un enlace: el propio enlace se quita, y lo que nombra se deja como está.
- Rechaza una raíz del sistema de archivos, un separador final, `.` y `..` (también como final de `dir/..`), y un árbol de más de 128 niveles de profundidad (que queda parcialmente quitado).
- Una llamada fallida conserva lo que ya quitó; el error nombra el elemento que falló con el error del sistema. Un tiempo de espera da un error, pero la eliminación ya iniciada llega hasta el final.
- Una ruta bajo un archivo (`file/child`) es un error (`Not a directory`), y también lo es un separador final en un enlace simbólico: `link/` nunca debe devolver `ok()`. Un fallo dentro del árbol nombra el elemento que falló.
- Unix cruza los puntos de montaje, como lo hace `rm -rf`. Windows quita las uniones y otros puntos de reanálisis sin recorrerlos, rechaza las raíces de unidad o de recurso compartido, la sintaxis de flujos de datos alternativos y los componentes que terminan en punto o en espacio.

```agentica {mode="check"}
def main() -> Void
  puts(Path.remove("build", 5000))
  puts(Path.remove("old.log", 1000))
end
```

## Path.rename {#pathrename}

```signature
Path.rename(from: String, to: String, timeout_ms: Int = 30000) -> Result[Void]
```

Renombra un archivo, un enlace simbólico o un directorio a una ruta que todavía no existe, en un solo paso.

- Nunca reemplaza nada: cuando `to` existe (incluso un directorio vacío) la llamada falla y no cambia nada, así que dos programas que compiten por un nombre tienen exactamente un ganador.
- Un enlace simbólico se mueve como enlace.
- Ambas rutas deben estar en un mismo sistema de archivos; no hay una copia de respaldo. Linux usa `renameat2` con `RENAME_NOREPLACE`, macOS `renameatx_np` con `RENAME_EXCL`, y Windows `MoveFileExW` sin flags, así que no reemplaza un destino ni copia entre volúmenes.

```agentica {mode="check"}
def main() -> Void
  _ = Dir.mkdir_private("/tmp/job-new", 1000)
  claimed = Path.rename("/tmp/job-new", "/tmp/job", 1000)
  puts(claimed.ok?)
end
```

## Path.replace {#pathreplace}

```signature
Path.replace(from: String, to: String, timeout_ms: Int = 30000) -> Result[Void]
```

Renombra el archivo regular `from` a `to` en un solo paso, reemplazando lo que hay en `to`, como hace `File.rename` de Ruby. Quien lee `to` ve el archivo antiguo o el nuevo, nunca ninguno de los dos, así que es el último paso para escribir un archivo completo: escribe un archivo nuevo junto a `to` y después reemplaza.

- Se reemplaza un archivo en `to`, y también un enlace simbólico: el propio enlace, nunca su destino (a diferencia de `File.replace`, que escribe a través de un enlace). Un `to` que falta se crea.
- Un directorio en `to` es un error `io.is_directory` y queda como estaba. Un directorio `from` también es `io.is_directory`, y un `from` que es un enlace simbólico u otro archivo que no es regular es `io.failed`.
- `from` se sincroniza con el disco antes de renombrar. En POSIX, la carpeta se vacía después, así que un corte de energía deja el archivo antiguo o el nuevo completo; Windows no tiene vaciado de carpeta.
- El archivo nuevo conserva sus propios bits de permiso y su propietario. Ambas rutas deben estar en un mismo sistema de archivos; no hay una copia de respaldo. POSIX usa `rename`, y Windows `MoveFileExW` con `MOVEFILE_REPLACE_EXISTING`.
- En Windows, `from` se abre para escritura a fin de vaciarlo, así que un `from` de solo lectura, o uno que otro programa tiene abierto sin compartir la escritura, es `io.permission`. También se rechazan un `to` de solo lectura, un `to` que otro programa tiene abierto sin `FILE_SHARE_DELETE`, y un enlace de directorio o una unión en `to`.
- Un tiempo de espera da un error, pero no detiene un renombrado en curso, que entonces se completa entero.

```agentica {mode="check"}
def main() -> Void
  _ = File.write_text("/tmp/settings.json.new", "{}", 1000)
  puts(Path.replace("/tmp/settings.json.new", "/tmp/settings.json", 1000).ok?)
end
```
