---
title: Process
weight: 3
description: Inicia otros programas, habla con ellos por su entrada y su salida, y espera a que terminen.
source_hash: "b625822ed0e4"
---

Un `Process` es un handle opaco, sin constructor, campos, igualdad ni codificación JSON; `IO.inspect` imprime `<Process>`. Un programa puede iniciar otros programas, salvo que se ejecute con `--deny-run` (o `--sandbox`, o `agentica run --deny-run`). Entonces cada inicio devuelve un error que empieza con `denied: --deny-run`, en todas las tareas, y los bloques extern se rechazan como con `--deny-native`. El flag va antes del archivo fuente; los argumentos posteriores llegan a `System.args`. Con `agentica test`, un programa de pasos no puede iniciar un programa bajo prueba:

```sh
agentica --deny-run tool.agc
```

- Los tiempos de espera son milisegundos positivos e incluyen la espera del bloqueo del handle. Un tiempo de espera durante la E/S de un flujo mata y cierra el programa; uno durante la espera del bloqueo lo mantiene; una espera de salida que vence no lo termina.
- Los argumentos llegan al programa tal cual. No interviene ningún shell. Toda función de espera recibe un tiempo de espera en milisegundos; las de inicio lo reciben en [Process.Options](#processoptions), cuyo valor predeterminado es 30000.
- Un programa que inicias pertenece a la tarea que lo inició y se detiene cuando esa tarea termina, sea como sea que termine. Los programas que sigan en ejecución se detienen cuando termine el tuyo. [Task.spawn_owning](/library/concurrency/task/#taskspawn_owning) lo entrega a una tarea nueva.

## Process.Options {#processoptions}

```signature
Process.Options(timeout_ms: Int = 30000, chdir: String = ".", env: Map[String, String] = {}, out: String = "", err: String = "", pgroup: Bool = false, pty: Bool = false)
```

Las opciones de `Process.spawn`, `Process.spawn_captured` y `Process.spawn_channel`, su último argumento, cuyo valor predeterminado es `Process.Options()`. Indica solo los campos que necesites: `Process.Options(chdir: "build", err: "err.txt")`. Los campos son las opciones de `spawn` de Ruby (`chdir:`, `out:`, `err:`, `pgroup:`), más `timeout_ms`, `env` (Ruby recibe el entorno como primer argumento) y `pty`. Un tiempo de espera, o una carpeta en lugar de las opciones, da `CHECK-TYPE-MISMATCH`.

## Process.spawn {#processspawn}

```signature
Process.spawn(command: String, args: List[String], options: Process.Options = Process.Options()) -> Result[Process]
```

Inicia un programa con el entorno de tu programa, más las variables de `env`.

- El programa inicia en la carpeta `chdir` (`"."`, el valor predeterminado, es la actual). Un `chdir` vacío o con un byte NUL da `error("process: chdir must be nonempty and cannot contain NUL")`, y uno que no es una carpeta, `error("process: directory is unavailable")`. El comando se busca desde la carpeta actual, no desde `chdir`.
- Un nombre sin `/` (`"echo"`) se busca en cada carpeta de `PATH`, en orden. La carpeta actual nunca se añade y las carpetas vacías se omiten; una carpeta relativa, como `bin`, se busca dentro de la carpeta actual, como en el shell.
- Un comando con `/` es una ruta (en Windows también `\` y una unidad como `C:`), relativa a la carpeta actual: para ejecutar un programa local usa `"./tool"`.
- `env` define variables solo para ese programa, sobre una copia de tu entorno: un par clave-valor reemplaza la variable del mismo nombre (Windows ignora mayúsculas y minúsculas, también en letras como `Ä`, y un mapa con dos nombres que solo difieren en mayúsculas es un `error`), y un valor vacío es un valor. Tu entorno no cambia, y un `PATH` en `env` no cambia cómo se encuentra el comando: lo resuelve tu `PATH`, y solo el programa ve el nuevo. Un nombre vacío, un nombre con `=`, o un byte NUL en un nombre o en un valor es un `error`, y también lo son `AGENTICA_CHANNEL`, `AGENTICA_VM_METRICS`, `AGENTICA_VM_METRICS_FILE` y `UV_USE_IO_URING`, que administra la VM.
- Un nombre no encontrado, o uno que nombra una carpeta, da `error("process: executable is unavailable")`. Un archivo que no se puede ejecutar (sin permiso de ejecución) es un error de `spawn`.
- Un comando vacío, o un byte NUL en el comando o en un argumento, da `error("process: command must be nonempty and arguments cannot contain NUL")`.
- `out` y `err`, si no están vacíos, son archivos que reciben la salida estándar y el error estándar del programa, sin shell y sin el límite de 1 MiB de una lectura o de un flujo capturado (como `spawn(cmd, out: path)` de Ruby). Cada uno se crea o se trunca; en Unix con modo 0666 menos los bits que quita la umask, como lo hacen `File.write_text` y el `>` de un shell; un archivo que ya existe conserva su modo. Una ruta relativa parte de la carpeta actual. `out` y `err` que nombran el mismo archivo lo comparten, como lo hace `> file 2>&1`. Un flujo enviado a un archivo no se puede leer: `read_line` da el fin de la salida de inmediato, y nada llega a tu error estándar. Una carpeta, el descriptor detrás de tu salida o error estándar (`/proc/self/fd/5`), una de las tuberías internas del programa, o en Windows una ruta que empieza con `\\.\` o `\\?\`, da `error("process: out does not refer to a regular file")` (o `err`), como lo rechazan las llamadas de `File`. Un archivo que no se puede abrir (falta la carpeta padre, sin permiso) da un error que empieza con `process: cannot open the out file` (o `err`) y nombra el error del sistema. En ambos casos no se inicia ningún programa. Un byte NUL da `error("process: out and err cannot contain NUL")`, y `--deny-fs` los desactiva. Los archivos se abren justo antes del inicio, así que un inicio que luego falla (un archivo que no se puede ejecutar) puede dejarlos creados o truncados, como lo hace el `>` de un shell. Solo `Process.spawn` los acepta: `spawn_captured` y `spawn_channel` dan `error("process: out and err need Process.spawn")`.
- `pgroup: true` (también para `spawn_captured` y `spawn_channel`) inicia el programa en su propio grupo de procesos, como una sesión nueva en Linux y macOS. A diferencia del `pgroup: true` de Ruby, la sesión nueva deja al programa sin terminal de control, así que un prompt en `/dev/tty` falla. Como con cualquier grupo propio, un Ctrl-C o un corte de la terminal solo le llega cuando tu programa detiene a sus hijos, y un `SIGKILL` a tu programa deja el grupo en marcha. Al detener el programa mientras corre (`close`, un tiempo de espera de flujo, el fin de la ejecución, una señal a tu programa), la señal va a todo el grupo, así que los programas que inició terminan con él: el controlador de un compilador y su `cc1`, o `sh` y su `sleep`. Tras un `SIGTERM`, el grupo recibe `SIGKILL` cuando vence el plazo de gracia, aunque el programa mismo ya haya terminado. Un descendiente que queda vivo tras un programa que terminó por su cuenta, antes de cualquier detención, no se detiene. Un programa iniciado sin `pgroup` se detiene solo, y sus propios hijos pueden sobrevivirle. En Windows `pgroup` no cambia nada: el programa se detiene solo.
- `pty: true` ejecuta el programa en una pseudoterminal, como lo hace `PTY.spawn` de Ruby, así que los programas interactivos funcionan: un prompt de contraseña (`ssh`, `sudo`), un REPL, un editor o un programa de pantalla completa. Consulta [Proceso en un pty](#process-on-a-pty).
- Windows: solo se ejecutan `.exe` y `.com` (no se lee `PATHEXT`; un nombre sin extensión prueba `.exe` primero; usa `cmd.exe` por su nombre para un shell). Fallan: un nombre que termina en punto, en espacio, en `.cmd` o en `.bat`; uno que empieza con `\\?\` o `\\.\`; un `:` que no es una unidad.

```agentica {mode="check"}
def main() -> Void
  p = Process.spawn("echo", ["hello"]).unwrap!
  puts(Process.read_line(p, 1000))
  puts(Process.wait(p, 1000))
end
```

```text
ok("hello")
ok(0)
```

```agentica {mode="check"}
def main() -> Void
  p = Process.spawn("sh", ["-c", "echo $GREETING"], Process.Options(env: {"GREETING": "hello"})).unwrap!
  puts(Process.read_line(p, 1000))
end
```

```text
ok("hello")
```

```agentica {mode="check"}
def main() -> Void
  options = Process.Options(out: "out.txt", err: "err.txt")
  p = Process.spawn("sh", ["-c", "echo report; echo warning >&2"], options).unwrap!
  puts(Process.wait(p, 1000))
  puts(File.read_text("out.txt"))
end
```

```text
ok(0)
ok("report\n")
```

## Process.send y Process.send_bytes {#processsend-and-processsend_bytes}

```signature
Process.send(process: Process, text: String, timeout_ms: Int) -> Result[Void]
Process.send_bytes(process: Process, bytes: Bytes, timeout_ms: Int) -> Result[Void]
```

Escribe en la entrada estándar del programa y vacía el búfer. Un envío acepta como máximo 1048576 bytes, texto UTF-8 o un `Bytes`; los datos no válidos no consumen nada.

```agentica {mode="check"}
def main() -> Void
  p = Process.spawn("cat", []).unwrap!
  _ = Process.send(p, "ping\n", 1000)
  puts(Process.read_line(p, 1000))
  Process.close(p)
end
```

```text
ok("ping")
```

## Process.read_line y Process.read_bytes {#processread_line-and-processread_bytes}

```signature
Process.read_line(process: Process, timeout_ms: Int) -> Result[String]
Process.read_bytes(process: Process, count: Int, timeout_ms: Int) -> Result[Bytes]
```

Lee de la salida estándar del programa.

- `read_line` quita el fin de línea (LF o CRLF), toma como máximo 1 MiB y decodifica de forma estricta. Al final de la salida da un error, y una línea de más de 1 MiB cierra el programa.
- `read_bytes` acepta un `count` de 0 a 1048576, espera esa cantidad de bytes o el fin de la salida, y los devuelve como [`Bytes`](/library/data-structures/bytes/). Al final de la salida vuelven vacíos.

## Process.poll_line {#processpoll_line}

```signature
Process.poll_line(process: Process, timeout_ms: Int) -> Result[String]
```

Lee una línea como lo hace `read_line`, pero un tiempo de espera conserva el programa y lo que ya escribió de la línea siguiente: el error tiene la clase `process.timeout`, y una lectura posterior recibe la línea entera. Al final de la salida la clase es `process.eof`. Así, un bucle puede hacer otro trabajo entre sondeos.

```agentica {mode="check"}
def main() -> Void
  p = Process.spawn("sh", ["-c", "printf 'wor'; sleep 1; echo king"]).unwrap!
  case Process.poll_line(p, 100)
    ok(line) -> puts(line)
    error(e) -> puts(e.kind)
  end

  puts(Process.poll_line(p, 5000))
end
```

```text
process.timeout
ok("working")
```

## Process.close_stdin {#processclose_stdin}

```signature
Process.close_stdin(process: Process, timeout_ms: Int) -> Result[Void]
```

Cierra la entrada del programa, para que vea el fin de la entrada. Antes vacía el búfer, y cerrarla dos veces no tiene problema.

```agentica {mode="check"}
def main() -> Void
  p = Process.spawn("wc", ["-l"]).unwrap!
  _ = Process.send(p, "a\nb\n", 1000)
  _ = Process.close_stdin(p, 1000)
  puts(Process.read_line(p, 1000).unwrap!.strip)
end
```

```text
2
```

## Process.wait {#processwait}

```signature
Process.wait(process: Process, timeout_ms: Int) -> Result[Int]
```

Devuelve el código de salida, también los distintos de cero (`false` da `ok(1)`), y se puede repetir. Un tiempo de espera deja el programa en ejecución. La salida sin leer sigue disponible después de `wait`. Un programa se bloquea cuando su tubería de salida estándar está llena, así que léela en una tarea mientras envías o esperas.

## Process.close {#processclose}

```signature
Process.close(process: Process) -> Void
```

Detiene el programa si aún corre, y lo libera. Cerrarlo dos veces no tiene problema. Un programa en ejecución se mata, la llamada espera a que termine (otras tareas corren mientras tanto) y cierra los puertos que posee; un tiempo de espera también lo cierra, pero no espera a que termine. Un fallo de la limpieza explícita es `RUNTIME-PROCESS-CLOSE` en la llamada.

Al salir de `main`, con `System.exit`, con un diagnóstico, con un fallo de tarea, al agotarse el presupuesto de pasos y ante una interrupción externa se limpian los programas iniciados directamente; sus descendientes solo quedan cubiertos con `pgroup` o `Process.spawn_group`, mientras el programa corre. En Windows una detención es siempre inmediata (sin el plazo de gracia de `SIGTERM`). Cuando libuv puede asignar su objeto de trabajo, los hijos directos de la VM mueren al terminar la VM, y un hijo que es a su vez un programa de Agentica detiene a sus propios hijos de la misma forma.

Su error estándar va al tuyo, salvo que se inicie con `Process.spawn_captured` o con un archivo `err`. Pasa por el búfer de stderr de tu programa: mientras nadie lea tu stderr, el hijo y `Process.wait` sobre él esperan, y las demás tareas siguen corriendo.

En un programa de `Process.spawn`, la tarea que lo cierra espera hasta un segundo a que termine; las demás tareas siguen.

## Proceso en un pty {#process-on-a-pty}

Con `pty: true` el programa inicia en una sesión nueva cuya terminal de control es una pseudoterminal nueva de 24 filas y 80 columnas, que también es su entrada, salida y error estándar, así que el error estándar se mezcla con la salida. `send` y `send_bytes` escriben en la terminal, y `read_line`, `read_bytes`, `poll_line` y `read_available` leen lo que muestra. Como con `spawn_captured`, la salida se lee todo el tiempo a un búfer de 1 MiB, así que el programa nunca se bloquea con una terminal llena; más allá de 1 MiB de salida sin leer, el resto se descarta y cada lectura da `error("process: output exceeds 1048576 bytes")`, `close` envía `SIGTERM` y luego `SIGKILL`, y, como con `pgroup: true`, una detención señala a todo el grupo. La salida termina cuando el programa y cada programa que inició con la terminal han terminado.

- Una terminal repite lo que envías, salvo que el programa desactivó el eco (un prompt de contraseña lo hace), y termina las líneas con `\r\n`; `read_line` quita el `\r`. Un prompt no tiene aún fin de línea: léelo con `read_bytes` o `read_available`. Ctrl-C es `"\x03"` y Ctrl-D (el fin de la entrada al inicio de una línea) es `"\x04"`; `close_stdin` no termina la entrada del programa.
- El programa recibe las variables de tu entorno, así que dale `TERM` en `env` cuando lo necesite.
- `spawn_captured` y `spawn_channel` con `pty`, o `pty` con `out` o `err`, dan `error("process: pty needs Process.spawn without out and err")`. No hay API para los modos de la terminal. Solo Linux y macOS: en otros sistemas, `pty` da `error("process: pty is not supported on this system")` con la clase `process.failed`.

```agentica {mode="check"}
def main() -> Void
  p = Process.spawn(
    "sh",
    ["-c", "stty -echo; printf 'name: '; read name; echo hi $name"],
    Process.Options(pty: true),
  ).unwrap!

  puts(Process.read_bytes(p, 6, 1000).unwrap!.size)
  Process.send(p, "Ada\n", 1000).unwrap!
  puts(Process.read_line(p, 1000))
end
```

```text
6
ok("hi Ada")
```

## Process.resize {#processresize}

```signature
Process.resize(process: Process, rows: Int, cols: Int) -> Result[Void]
```

Fija el tamaño de la terminal de un programa con `pty: true`, como lo hace una ventana de terminal al cambiar de tamaño: el programa recibe `SIGWINCH`, y `stty size` muestra el tamaño nuevo. Filas y columnas van de 1 a 65535; si no, `error("process: rows and cols must be 1..65535")`. Un programa sin pty da `error("process: the child has no pty")` con la clase `process.failed`, y uno cerrado `error("process: process is closed")`.

## Process.signal y Process.signal_group {#processsignal-and-processsignal_group}

```signature
Process.signal(process: Process, signal: System.Signal) -> Result[Void]
Process.signal_group(process: Process, signal: System.Signal) -> Result[Void]
```

`Process.signal` envía una señal (`System.Signal`, consulta [System.subscribe](system.md#systemsubscribe)) al programa; `signal_group` la envía al grupo de procesos que encabeza el programa, así que los programas que inició también la reciben. Una señal que el programa no maneja lo termina, y `Process.wait` da entonces `128 +` el número de la señal (143 para `Term`). Ninguna de las dos llamadas espera a que el programa termine: sigue con `Process.wait` y un plazo, y con `Process.close` si el programa se retrasa.

- Un programa cerrado devuelve `error("process: process is closed")`. Un programa que ya terminó devuelve `error("process: the child has exited")` con la clase `process.failed`: su pid puede pertenecer ya a otro proceso.
- `signal_group` necesita un programa que encabece su propio grupo, iniciado con `Process.spawn_group` o `pgroup: true`; cualquier otro devuelve `error("process: the child does not lead a process group")` con la clase `process.failed`.
- En Windows las dos devuelven `error("signal: not supported on this system")` con la clase `system.signal`.

## Process.pid {#processpid}

```signature
Process.pid(process: Process) -> Result[Int]
```

El id de proceso del sistema operativo del programa, como `Process::Status#pid` de Ruby: para los registros, para `/proc/<pid>/status` o para otra herramienta. En Windows es el id de `GetProcessId`.

- Un programa que ya terminó y cuyo estado recogió el sistema devuelve `error("process: the child has exited")` con la clase `process.failed`, como `Process.signal`: su pid puede pertenecer ya a otro proceso.
- Un programa cerrado devuelve `error("process: process is closed")`.

```agentica {mode="check"}
def main() -> Void
  child = Process.spawn("sleep", ["1"]).unwrap!
  puts("started #{Process.pid(child).unwrap!}")
  _ = Process.wait(child, 5000)
end
```

## Process.spawn_group {#processspawn_group}

```signature
Process.spawn_group(command: String, args: List[String], dir: String = ".", timeout_ms: Int = 30000) -> Result[Process]
```

Inicia un programa en una sesión nueva, así que encabeza su propio grupo de procesos, como `Popen(start_new_session=True)` de Python. Comparte la entrada, la salida y el error estándar de tu programa: su salida va adonde va la tuya (una terminal, el registro de un contenedor), nada puede llenarse, y `read_line`, `read_bytes`, `read_available`, `output`, `send`, `send_bytes` y `close_stdin` devuelven `error("process: the child uses the program's stdin, stdout and stderr")` con la clase `process.failed`. `dir` es la carpeta donde inicia; el comando se busca desde la carpeta de tu programa, así que da una ruta absoluta cuando `dir` no sea `"."`. `--deny-run` lo desactiva, y en Windows devuelve `error("process: process groups are not supported on this system")` con la clase `system.signal`.

La sesión nueva deja al hijo sin terminal de control: tiene los descriptores 0 a 2, pero abrir `/dev/tty` falla (`ENXIO`), así que un programa que lo necesita (un prompt de contraseña de `ssh`, `less`, `sudo`, un editor) no puede usarlo, y no hay control de trabajos de terminal. `Ctrl-C` le llega solo por la ruta de detención de la VM, que envía `SIGKILL` al grupo. El hijo lee la misma entrada estándar que tu programa, así que un `IO.gets` pendiente reparte la entrada con él, y tu salida con búfer puede aparecer después de la del hijo: vacía antes de iniciar.

`Process.close`, el fin de la tarea que lo posee y el fin de la ejecución envían `SIGKILL` a todo el grupo mientras el programa corre. Este es el inicio del punto de entrada de un contenedor: detiene el programa con `signal_group`, espera con un plazo, y mata el grupo si se retrasa.

```agentica {mode="check"}
def main() -> Void
  signals = System.subscribe([System.Signal.Term, System.Signal.Int]).unwrap!
  child = Process.spawn_group("/usr/bin/runner", ["--once"]).unwrap!
  case signals.recv(3600000)
    ok(signal) ->
      _ = Process.signal_group(child, signal)
      if !Process.wait(child, 30000).ok?
        Process.close(child)
      end

      System.exit(128 + System.signal_number(signal))
    error(_) -> nil
  end
end
```

## Process.spawn_captured {#processspawn_captured}

```signature
Process.spawn_captured(command: String, args: List[String], options: Process.Options = Process.Options()) -> Result[Process]
```

Inicia un programa como lo hace `Process.spawn`, en la carpeta `chdir`, y conserva su salida.

- La salida estándar y el error estándar se leen todo el tiempo a búferes de 1 MiB cada uno, así que el programa nunca se bloquea con una tubería llena, y su error estándar nunca se imprime. `read_line` y `read_bytes` leen la salida estándar como de costumbre.
- Más allá de 1 MiB de salida estándar o de error pendientes de lectura, el resto se descarta, y cada lectura de la salida estándar da `error("process: output exceeds 1048576 bytes")`. `Process.read_bytes(p, 0, timeout)` lo da de inmediato, para comprobarlo sin esperar.
- `close` envía `SIGTERM` y mata al programa un segundo después si aún corre, así que un programa de Agentica puede detener a sus propios hijos. `close` y un tiempo de espera nunca esperan; al final de una ejecución un programa capturado tiene un segundo aproximadamente, mientras que un programa de `Process.spawn` se mata de inmediato. Windows no tiene `SIGTERM`: el programa termina de inmediato, y donde libuv puede asignar su objeto de trabajo, los programas que inició la VM mueren cuando termina la VM (los demás descendientes no quedan cubiertos).

## Process.output {#processoutput}

```signature
Process.output(process: Process, timeout_ms: Int) -> Result[Process.Output]
```

Espera a que un programa capturado cierre su salida estándar y su error, y devuelve `Process.Output(stdout: String, stderr: String, truncated: Bool)`: `stdout` es lo que aún no has leído, `stderr` todo, `truncated` indica si se descartó salida (el UTF-8 no válido en `stderr` pasa a U+FFFD). No consume nada, así que llámala otra vez si hace falta. Un tiempo de espera es `error("process: operation timed out")` y mantiene el programa. Un programa de `Process.spawn` da `error("process: output is not captured")`.

```agentica {mode="check"}
def main() -> Void
  p = Process.spawn_captured("sh", ["-c", "echo one; echo two; echo oops >&2"]).unwrap!
  puts(Process.read_line(p, 1000))
  out = Process.output(p, 1000).unwrap!
  puts(out.stdout)
  puts(out.stderr)
  puts(out.truncated)
  Process.close(p)
end
```

```text
ok("one")
two

oops

false
```

## Process.spawn_channel {#processspawn_channel}

```signature
Process.spawn_channel(command: String, args: List[String], options: Process.Options = Process.Options()) -> Result[Process]
```

Como `Process.spawn_captured`, y además abre un canal privado hacia el programa, aparte de su entrada, salida y error estándar. Transporta líneas de texto en ambos sentidos, en Linux, macOS y Windows: una tubería en cada sentido, así que el programa lee el descriptor 3, escribe en el 4 y ve `AGENTICA_CHANNEL=3,4`.

`Process.spawn` y `Process.spawn_captured` quitan esa variable de lo que pasan, así que un programa solo ve un canal que abrió su propio padre. Su entrada y su salida estándar siguen libres.

## Process.channel_read_line, Process.channel_send y Process.channel_close {#processchannel_read_line-processchannel_send-and-processchannel_close}

```signature
Process.channel_read_line(process: Process, timeout_ms: Int) -> Result[String]
Process.channel_send(process: Process, text: String, timeout_ms: Int) -> Result[Void]
Process.channel_close(process: Process, timeout_ms: Int) -> Result[Void]
```

- `channel_read_line` lee una línea (como máximo 1 MiB, sin el fin de línea), como lo hace `Process.read_line`. Al final da `error("process: end of input")`; una última línea que la salida del programa cortó, sin fin de línea, no se devuelve como línea: da `error("process: line cut off")`. Si la salida estándar o el error se cortaron (consulta `Process.read_available`) y no hay una línea completa, da `error("process: output exceeds 1048576 bytes")` de inmediato, así que un programa que imprime sin parar se nota sin esperar al tiempo de espera.
- `channel_send` envía como máximo 1048576 bytes exactamente como se dan: añade tu propio `"\n"`.
- `channel_close` cierra solo el lado que envía: el programa lee el fin de la entrada, y tú aún puedes leer lo que envía. Cerrarlo dos veces, o después de que el programa termine, no tiene problema.
- Un tiempo de espera en `channel_read_line` o `channel_send` cierra el canal, no el programa. Las llamadas siguientes dan `error("process: channel is closed")`.
- Sin canal, las tres dan `error("process: the child has no channel")`.

```agentica {mode="check"}
def main() -> Void
  script = "read line <&3; echo \"got $line\" >&4"
  p = Process.spawn_channel("sh", ["-c", script]).unwrap!
  _ = Process.channel_send(p, "hello\n", 1000)
  puts(Process.channel_read_line(p, 1000))
  Process.close(p)
end
```

```text
ok("got hello")
```

## Process.read_available {#processread_available}

```signature
Process.read_available(process: Process, timeout_ms: Int) -> Result[String]
```

Devuelve, y quita, la salida estándar de un programa capturado que llegó desde la última llamada.

- Nunca espera más salida; el tiempo de espera solo acota la espera del bloqueo de lectura. Una llamada toma como máximo unos 2 MiB.
- Los bytes que terminan a mitad de un carácter esperan a la llamada siguiente, así que un carácter nunca se parte (salvo que la salida haya terminado).
- La salida escrita antes de una línea de canal está en el texto en cuanto lees esa línea, así que vaciar antes de enviar un registro vincula la salida al registro.
- Tras un truncamiento da `error("process: output exceeds 1048576 bytes")`. En un programa de `Process.spawn`, `error("process: output is not captured")`.

```agentica {mode="check"}
def main() -> Void
  script = "echo working; echo done >&4"
  p = Process.spawn_channel("sh", ["-c", script]).unwrap!
  puts(Process.channel_read_line(p, 1000))
  puts(Process.read_available(p, 1000))
  Process.close(p)
end
```

```text
ok("done")
ok("working\n")
```

## Process.parent_read_line y Process.parent_send {#processparent_read_line-and-processparent_send}

```signature
Process.parent_read_line(timeout_ms: Int) -> Result[String]
Process.parent_send(text: String, timeout_ms: Int) -> Result[Void]
```

El lado del programa del canal que su padre abrió con `Process.spawn_channel`, con las reglas de `channel_read_line` y `channel_send`. El tiempo de espera debe ser positivo, y un tiempo de espera cierra el canal para siempre. Sin canal: `error("process: no parent channel")`.

- La VM toma el canal al arrancar solo si `AGENTICA_CHANNEL` es `3,4` y el descriptor 3 está abierto para lectura y el 4 para escritura, cada uno una tubería, una FIFO o un socket (en Windows, una tubería). En Linux y macOS también toma `3` con un socket o una FIFO abiertos en ambos sentidos en el descriptor 3. Cualquier otra cosa (un archivo regular, un dispositivo, una tubería al revés) se ignora: no hay canal.
- Los hijos del propio programa no heredan los descriptores ni la variable.

Estas llamadas son para el código del ejecutor de pruebas, como el de `agentica test`. Una prueba que las llame puede romper el protocolo entre el ejecutor de pruebas y su archivo, y nada lo impide.

```agentica {mode="check"}
def main() -> Void
  line = Process.parent_read_line(5000)
  if line.ok?
    _ = Process.parent_send("echo " + line.unwrap! + "\n", 5000)
  end
end
```
