---
title: System, Time y Random
weight: 5
description: Argumentos del programa, variables de entorno, códigos de salida, relojes y números aleatorios.
source_hash: "2726610279bc"
---

## System.args {#systemargs}

```signature
System.args() -> List[String]
```

Devuelve las palabras que siguen al nombre del archivo: `agentica tool.agc a b` da `["a", "b"]`.

```agentica
def main() -> Void
  args = System.args()
  puts("#{args.size} arguments")
end
```

```output
0 arguments
```

## System.program_name {#systemprogram_name}

```signature
System.program_name() -> String
```

La ruta del programa principal tal como se dio, como `$PROGRAM_NAME` de Ruby: `app/tool.agc` para `agentica app/tool.agc`, y el archivo `.agcb` para `agentica run -- app/tool.agcb`. `System.args` no la incluye. Con `agentica test` es el archivo de prueba (o el archivo de pasos de una ejecución de BDD); en `agentica repl` es `"(repl)"`, y un programa incrustado da `""`. `Path.real` da su ruta completa, a partir de la cual un programa halla los archivos que están junto a él:

```agentica {mode="check"}
def main() -> Void
  puts(Path.real(System.program_name()).unwrap!)
end
```

## System.exit {#systemexit}

```signature
System.exit(code: Int) -> Void
```

Termina el programa de inmediato, con un código de salida.

```agentica
def main() -> Void
  puts("before")
  System.exit(3)
  puts("never printed")
end
```

```output
before
```

## System.env {#systemenv}

```signature
System.env(name: String) -> Result[String]
```

Lee una variable de entorno del programa. Con `--deny-env` (o `--sandbox`) devuelve un error que empieza con `denied: --deny-env`. No hay ninguna llamada que liste todas las variables.

- Una variable sin definir es un error. Una variable definida con la cadena vacía es `ok("")`.
- Un nombre vacío, o que tiene `=` o NUL, es un error.
- Un valor que no es UTF-8 válido no es un error. Cada secuencia no válida se convierte en un U+FFFD, como lo hace [`bytes.scrub`](/library/data-structures/bytes/#scrub).
- El directorio personal es `System.env("HOME")`.

```agentica
def main() -> Void
  editor = System.env("AGENTICA_EXAMPLE_NOT_SET").unwrap_or("vi")
  puts(editor)
  puts(System.env("A=B").ok?)
end
```

```output
vi
false
```

La VM oculta las variables que guarda para sí:

- `AGENTICA_CHANNEL`, y `UV_USE_IO_URING` cuando lo fijó la VM. Un programa iniciado con `Process.spawn` tampoco las recibe.
- `AGENTICA_VM_METRICS` y `AGENTICA_VM_METRICS_FILE` están reservadas para las métricas de la VM. Un programa iniciado con `Process.spawn` no las recibe, pero `System.env` sigue mostrándoselas a tu programa.

## System.hostname {#systemhostname}

```signature
System.hostname() -> Result[String]
```

El nombre de host de la máquina, como `Socket.gethostname` de Ruby: el nombre que fijó el runtime (Docker: el id del contenedor, salvo `--hostname`). No necesita ningún flag, y `--deny-env` lo deja activo, como a `System.os`.

- El nombre no se busca en la red: es el que guarda el sistema operativo, sin dominio añadido.
- Un nombre que no es UTF-8 válido no es un error. Cada secuencia inválida se convierte en un U+FFFD.
- El error, que un sistema no da en la práctica, es un error `io` con el errno como su `code` (`io.failed` para cualquier errno que la tabla no nombre).

```agentica
def main() -> Void
  puts(System.hostname().unwrap!.length > 0)
end
```

```output
true
```

## System.os {#systemos}

```signature
System.os() -> String
```

El sistema operativo del programa en ejecución. No necesita ningún flag.

- `"linux"`, `"macos"` o `"windows"`.
- En cualquier otro sistema, el nombre en minúsculas que devuelve `uname`.
- `"unknown"` cuando el sistema no puede decirlo, o cuando el nombre no está formado por ASCII imprimible.

```agentica
def main() -> Void
  puts(System.os().length > 0)
end
```

```output
true
```

## System.pid {#systempid}

```signature
System.pid() -> Int
```

El id de proceso del programa en ejecución. No necesita ningún flag. Pásalo a `--driver-pid` al iniciar una VM. Esa VM comprueba entonces que su padre es este programa.

```agentica
def main() -> Void
  puts(System.pid() > 0)
end
```

```output
true
```

## System.subscribe {#systemsubscribe}

```signature
System.subscribe(signals: List[System.Signal]) -> Result[Channel[System.Signal]]
```

Recibe las señales del sistema operativo que indiques como valores en un canal nuevo, en lugar de dejar que detengan el programa. `System.Signal` es un enum: `Term`, `Int` (Ctrl-C), `Hup`, `Usr1`, `Usr2`, `Winch`, `Quit` y `Kill`; las seis primeras pueden suscribirse. `Winch` es un cambio de tamaño de la terminal ([Terminal](/library/io-and-system/terminal/#resize-events)): nunca detiene el programa y, sin una suscripción, no hace nada. Un programa que debe limpiar al recibir Ctrl-C o al detenerse un contenedor recibe el primer valor, limpia y termina con `128 + System.signal_number(signal)`, el código que espera un shell.

- El canal guarda un valor pendiente por señal: un valor se encola solo cuando esa señal no tiene ninguno esperando, así que una ráfaga de una señal da un valor, y la señal nunca espera al programa. El canal no cuenta cuántas veces llegó una señal.
- Cada suscripción recibe todas las señales que indica, así que dos tareas que se suscriben a `Term` reciben ambas. Una señal indicada dos veces cuenta una vez.
- La tarea que hace la llamada posee el canal, como un handle. Cuando esa tarea termina, de cualquier forma, o el canal se cierra, la suscripción termina: los valores que aún están en cola se pueden recibir, y después `recv` devuelve `channel: closed`. Cuando termina la última suscripción a una señal, esa señal vuelve a detener el programa.
- Una señal que llega antes de la suscripción detiene el programa, como ocurre sin ella. Mientras una suscripción está abierta, la ejecución espera sus señales, así que un programa cuyas tareas esperan a una no termina.
- `send` en el canal, o en su dirección, devuelve `error("signal: channel is read only")` con la clase `argument`.
- `Quit` o `Kill` en la lista detienen la ejecución con `RUNTIME-INVALID-SIGNAL`. `Quit` (`Ctrl-\`) es la detención forzosa: detiene los programas hijos, escribe los archivos y sale con 131, también en un programa que se suscribió a `Term` e `Int`, salvo que el programa se iniciara con `Quit` ignorada (un trabajo que un shell ejecuta en segundo plano). `Kill` no se puede capturar.
- Una lista vacía devuelve `error("signal: no signals")` con la clase `argument`. Una señal que el programa tenía ignorada al iniciarse (`nohup`; `Int` y `Quit` en un trabajo que un shell ejecuta en segundo plano) sigue ignorada, y las demás señales indicadas se suscriben; cuando todas las indicadas se ignoraron, la llamada devuelve `error("signal: ignored when the program started")` con la clase `system.signal`. En Windows solo `Winch` puede suscribirse: una lista con otra señal devuelve `error("signal: not supported on this system")` con la clase `system.signal`, y Ctrl-C y Ctrl-Break detienen el programa.
- No necesita ningún flag, tampoco con `--sandbox`: solo cambia lo que el programa hace con sus propias señales.
- `SIGPIPE`, `SIGCHLD` y las señales del recolector de basura de la VM no tienen valor de `System.Signal`, así que un programa no puede tomarlas. Un programa iniciado con `Process.spawn` arranca con la acción predeterminada para cada señal.

```agentica
def main() -> Void
  signals = System.subscribe([System.Signal.Term]).unwrap!
  case signals.recv(100)
    ok(signal) -> System.exit(128 + System.signal_number(signal))
    error(e) -> puts(e.message)
  end
end
```

```output
channel: timed out
```

## System.signal_number {#systemsignal_number}

```signature
System.signal_number(signal: System.Signal) -> Int
```

El número de la señal: `Term` es 15, `Int` 2, `Hup` 1, `Winch` 28, `Quit` 3 y `Kill` 9. `Usr1` y `Usr2` son 10 y 12 en Linux y Windows, 30 y 31 en macOS. Un proceso que una señal terminó tiene el código de salida `128 +` ese número.

```agentica
def main() -> Void
  puts(System.signal_number(System.Signal.Term))
end
```

```output
15
```

## System.signal {#systemsignal}

```signature
System.signal(pid: Int, signal: System.Signal, comm: String) -> Result[Void]
```

Envía una señal a un proceso que no es hijo de tu programa, como un programa que inició un hijo. `comm` es el nombre del proceso tal como Linux lo guarda en `/proc/<pid>/comm`: el nombre del archivo del programa, cortado a 15 bytes (`Runner.Listener`). La señal solo va al proceso que tiene ese pid y ese nombre cuando corre la llamada: la VM mantiene el proceso con un pidfd mientras compara el nombre, y señala a través de él, así que nunca llega a un proceso que tomó un pid reutilizado. Para los hijos de tu propio programa usa `Process.signal`.

- Un pid de 0 o menor, o el de tu propio programa, devuelve `error("signal: pid must be above 0 and not the program's own")`, y un `comm` vacío o de más de 15 bytes devuelve `error("signal: comm must be 1 to 15 bytes without NUL")`; ambos con la clase `argument`.
- Otro nombre devuelve `error("signal: the process has another name")` con la clase `system.signal`, y el proceso no recibe nada. Un proceso que ya terminó, o uno de otro usuario, devuelve un error que empieza con `signal: cannot signal the process`, con la clase `process.failed` y el número de error del sistema como código.
- `--deny-run` lo desactiva: devuelve `error("denied: --deny-run turns off signalling processes")`.
- Necesita Linux 5.3 o posterior. En un kernel más antiguo, bajo un filtro seccomp que rechaza los pidfd, y en macOS y Windows devuelve `error("signal: pidfd is unavailable")` con la clase `system.signal`.

```agentica {mode="check"}
def main() -> Void
  pid = System.args()[0].to_i!
  case System.signal(pid, System.Signal.Term, "Runner.Listener")
    ok(_) -> puts("sent")
    error(e) -> puts(e.message)
  end
end
```

## Std.source {#stdsource}

```signature
Std.source(path: String) -> Result[String]
```

El texto de un código fuente de `std/` que lleva el binario `agentica`, por su ruta exacta en `stdlib/`: `"queue.agc"`, `"bdd/gherkin.agc"`, `"prelude/list.agc"`; `"internal/compiler/..."` es el núcleo privado del front end que usa `std/analysis`. Cualquier otra ruta es un error, incluidas `"std/queue.agc"` y `"queue"`. No necesita ningún flag y solo lee datos del binario, así que las tareas pueden llamarla a la vez. Una herramienta de documentación o de lint puede leer así los fuentes de std del binario que la ejecuta.

```agentica
def main() -> Void
  text = Std.source("queue.agc").unwrap_or("")
  puts(text.start_with?("## "))
  puts(Std.source("nope.agc").ok?)
end
```

```output
true
false
```

## FrontEnd {#frontend}

`FrontEnd.hand_off(program, options, arguments)`, `FrontEnd.std_source(path)` y `FrontEnd.stdin_bytes()` pertenecen al front end del binario `agentica`. Ese binario compila un programa y se lo pasa a la VM: `hand_off` toma el programa compilado (un `Bytes`) y lo ejecuta en un runtime nuevo con las opciones de VM y los argumentos dados, `std_source` lee un código fuente de `std/` incrustado por su ruta en `stdlib/`, y `stdin_bytes` lee la entrada estándar hasta el final como un `Result[Bytes]` (un error si supera los 16 MiB o si la lectura falla; una llamada posterior sigue leyendo desde donde quedó). `FrontEnd.spawn_session(command, options, json)` inicia el hijo que mantiene la sesión de `agentica repl`, que termina cuando termina el front end, y `FrontEnd.serve_session()` es el bucle principal de ese hijo (`agentica run --session`): carga cada fragmento sobre el programa en ejecución y responde por el canal del padre. El hijo siempre corre en un solo planificador, sin JIT, sin perfil ni cobertura. No son para tus programas: un programa que las llame, y cualquier front end que ejecute `agentica run`, se detiene con `RUNTIME-FRONT-END-ONLY`. No necesitan ningún flag.

## Time.now_ms {#timenow_ms}

```signature
Time.now_ms() -> Int
```

Tiempo de reloj en milisegundos desde 1970. Puede saltar cuando cambia el reloj del sistema. `&Time.now_ms` es el reloj como valor (`Fn[Int]`), para pasarlo a código al que una prueba le da un reloj fijo.

```agentica
def main() -> Void
  puts(Time.now_ms() > 1700000000000)
end
```

```output
true
```

## Time.monotonic_ms {#timemonotonic_ms}

```signature
Time.monotonic_ms() -> Int
```

Milisegundos desde un origen desconocido. El valor nunca retrocede. Úsalo para medir cuánto tarda algo. En un host Linux donde leer el reloj exacto es una llamada al sistema (como una fuente de reloj HPET), viene del reloj aproximado del kernel, que es barato de leer y va detrás del tiempo exacto hasta unos dos tics del kernel (como máximo unos 20 ms), pero nunca queda por detrás de un `Time.monotonic_ns` anterior ni de un `Task.sleep` que terminó: tras `Task.sleep(ms)` ha avanzado al menos `ms`. Usa `Time.monotonic_ns` para lapsos de unos pocos milisegundos.

```agentica
def main() -> Void
  start = Time.monotonic_ms()
  Task.sleep(5)
  elapsed = Time.monotonic_ms() - start
  puts(elapsed >= 5)
end
```

```output
true
```

## Time.monotonic_ns {#timemonotonic_ns}

```signature
Time.monotonic_ns() -> Int
```

Nanosegundos desde el mismo reloj y el mismo origen desconocido que `Time.monotonic_ms`. Nunca retroceden. Úsalos para trabajos demasiado cortos para milisegundos. Un `Int` guarda unos 292 años de nanosegundos, así que el valor no desborda en la práctica.

```agentica
def main() -> Void
  start = Time.monotonic_ns()
  Task.sleep(5)
  elapsed = Time.monotonic_ns() - start
  puts(elapsed >= 4000000)
end
```

```output
true
```

## Random.int {#randomint}

```signature
Random.int(min: Int, max: Int) -> Int
```

Un `Int` aleatorio desde `min` hasta `max`, uniforme. Ambos extremos están incluidos. `min > max` detiene el programa con `RUNTIME-INVALID-RANGE`.

```agentica
def main() -> Void
  roll = Random.int(1, 6)
  puts(roll >= 1 and roll <= 6)
end
```

```output
true
```

## Random.float {#randomfloat}

```signature
Random.float() -> Float
```

Un `Float` aleatorio desde `0.0` hasta, sin incluir, `1.0`.

```agentica
def main() -> Void
  x = Random.float()
  puts(x >= 0.0 and x < 1.0)
end
```

```output
true
```

## Random.seed {#randomseed}

```signature
Random.seed() -> Int
```

La semilla de la ejecución, de `0` a `2147483647`: la `N` de `--seed N`, o la que se toma del sistema operativo cuando no hay `--seed`. Todas las tareas dan el mismo número. Imprímelo cuando algo falle, y luego ejecuta de nuevo con `--seed` y ese número para obtener los mismos números aleatorios.

```agentica
def main() -> Void
  seed = Random.seed
  puts(seed >= 0 and seed <= 2147483647)
end
```

```output
true
```

Cada ejecución da otros números. Ejecuta con `agentica --seed 42 file.agc` para obtener siempre los mismos números (`N` va de `0 .. 2147483647`; si no, el código de salida es 2). Sin `--seed`, el generador se inicializa desde el sistema operativo.

- Cada tarea tiene su propio generador. Se deriva del de su padre al iniciar la tarea, así que cada tarea repite sus propios números: la tarea principal arranca desde la semilla, y cada inicio toma un número del de su padre. Los temporizadores, la E/S y más de un planificador pueden seguir cambiando cómo se intercalan las tareas, así que una ejecución de varias tareas, en conjunto, no es repetible.
- No uses `Random` para secretos: se inicializa con una semilla, y `--seed` la repite. Usa [OpenSSL.Random](/library/text-and-data/crypto/#random) para claves, tokens e IDs.
