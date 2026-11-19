---
title: Tarea
weight: 1
description: Inicia, espera (con o sin tiempo de espera), pausa, cancela, vigila y cuenta tareas ligeras; aplica un bloque a cada elemento de una lista con concurrencia acotada; transfiere un handle a una tarea, y encuentra sus fallos.
source_hash: "c55780594d31"
---

Las tareas ejecutan funciones al mismo tiempo. Consulta la página del tour [Tareas](/tour/tasks/).

Las tareas son cooperativas: una tarea cede el control cuando espera E/S, un temporizador, un canal u otra tarea, y al final de cada turno. Se ejecutan en los planificadores de la VM, uno por núcleo lógico salvo que `--schedulers N` fije la cantidad, así que las tareas pueden ejecutarse en paralelo y el orden de salida entre tareas no está fijado. Con `--schedulers 1`, una tarea se ejecuta a la vez: concurrencia de E/S sin paralelismo de CPU, en el orden de una sola cola de ejecución. Cada tarea tiene sus propios alcances, profundidad de llamadas y manejo de retornos. Las tareas heredan puertos, argumentos y servicios integrados, y todas comparten el contador `--max-steps`. Los flujos compartidos no garantizan orden entre tareas. `Task` es un nombre reservado, y una tarea no tiene constructor, igualdad, campos, indexación ni codificación JSON.

## Task.spawn {#taskspawn}

```signature
Task.spawn(function: Fn[R]) -> Task[R]
Task.spawn(function: Fn[A, R], argument: A) -> Task[R]
```

Inicia `function(argument)` en una tarea nueva y devuelve su handle de `Task`. Sin argumento, la función no recibe parámetros: `Task.spawn(&work)` inicia `work()`. La función recibe como máximo un parámetro; usa una estructura para varios valores.

Un bloque también es la función: `Task.spawn do ... end` ejecuta el bloque como una tarea, como `Thread.new { }` de Ruby, y puede capturar variables locales. Da un bloque o una referencia a función, no las dos cosas (`CHECK-BLOCK-TARGET`). `Task.spawn_owning` siempre toma el handle.

- Un archivo, socket, listener, proceso o servidor pertenece a la tarea que lo abrió y se cierra cuando esa tarea termina (devuelve un valor, falla o se cancela). Por eso, abre un handle de larga vida en la tarea que lo conserva, no en un auxiliar: no se entrega a la tarea padre, y un handle abierto en un auxiliar y devuelto por `Task.await` se cierra cuando termina el auxiliar.
- Un archivo regular se cierra con su salida escrita antes de que `Task.await` de la tarea terminada devuelva el control, así que lo que un auxiliar escribió en un archivo regular está en disco cuando el await del padre devuelve. El await no espera el vaciado a un FIFO o a una tubería.
- La propiedad decide quién cierra un handle, no quién puede usarlo: cualquier tarea que tenga el handle puede usarlo hasta que su propietario lo cierre.
- `Task.spawn` no mueve nada: un handle en el argumento, o en una estructura o lista de él, se queda con quien llama. Para cederlo, usa `Task.spawn_owning`, que también recibe esa estructura o lista.

```agentica
def greet(name: String) -> String = "hi #{name}"

def main() -> Void
  task = Task.spawn(&greet, "Ana")
  puts(Task.await(task))
end
```

```output
hi Ana
```

## Task.spawn_owning {#taskspawn_owning}

```signature
Task.spawn_owning(function: Fn[A, R], handle: A) -> Task[R]
```

Inicia `function(handle)` como `Task.spawn` y entrega `handle` a la tarea nueva en la misma llamada.

- El argumento debe ser un `File.Handle`, `TCP.Socket`, `TCP.Listener`, `Process`, `HTTP.Server`, `Channel[T]`, un `C.Pointer` o un [recurso nativo o un búfer propio](/library/io-and-system/native/types/), o una estructura, enum, `List`, `Map` o `Result` cuyo tipo contenga uno (a través de campos, payloads de variantes y argumentos de tipo). Cualquier otra cosa (un `Int`, una estructura sin handle, un `HTTP.Client`) es `CHECK-NOT-A-HANDLE`. Ni un fallo ni el fin de una tarea cierran un `HTTP.Client`.
- Un valor que guarda handles transfiere todos: la tarea nueva recibe el valor y los cierra todos cuando termina. Una variante de enum sin handle no transfiere nada. La [`Address`](/library/concurrency/channel/#channeladdress) de un canal es un dato, no un handle: pon en el valor la dirección de un canal que otras tareas siguen usando, y el canal sigue abierto ([un handle con dueño, un canal compartido](/library/concurrency/channel/#one-handle-owned-one-channel-shared)).
- Quien llama debe ser dueño de cada handle, y puede seguir usándolo mientras corre la tarea nueva. Si no (no es suyo, ya se transfirió o está cerrado), quien llama se detiene con `RUNTIME-HANDLE-NOT-OWNED`: no se crea ninguna tarea y ningún handle se mueve: todos o ninguno. De los valores `C.Pointer`, solo un búfer propio (`Native.memory_pointer`) se puede transferir; un puntero que dio C, o una vista de un búfer (`Native.offset`), es `RUNTIME-HANDLE-NOT-OWNED`.
- Un bucle de servidor puede dar cada conexión aceptada a su propia tarea, así que un fallo cierra solo esa conexión. Un servidor transferido se lleva su listener y sigue atendiendo cuando termina quien lo creó.
- Un [Channel](/library/concurrency/channel/) no tiene quien lo abra, así que cualquier tarea puede hacer la primera transferencia. Las reglas de propiedad están en [un productor que posee el canal](/library/concurrency/channel/#a-producer-that-owns-the-channel).

```agentica
def echo(socket: TCP.Socket) -> Result[String]
  line = try TCP.read_line(socket, 2000)
  try TCP.send(socket, "echo: #{line}\n", 2000)
  ok(line)
end

def main() -> Void
  listener = TCP.listen("127.0.0.1", 0).unwrap!
  client = TCP.connect("127.0.0.1", TCP.local_port(listener), 2000).unwrap!
  connection = TCP.accept(listener, 2000).unwrap!
  worker = Task.spawn_owning(&echo, connection)
  _ = TCP.send(client, "hello\n", 2000)
  puts(TCP.read_line(client, 2000))
  puts(Task.await(worker))
  puts(TCP.read_line(client, 2000))
  TCP.close(client)
  TCP.close_listener(listener)
end
```

```output
ok("echo: hello")
ok("hello")
error("network: end of input", kind: "net.eof")
```

`echo` nunca cierra la conexión. Su fin sí la cierra, así que el cliente lee el fin de la entrada.

## Task.await {#taskawait}

```signature
Task.await(task: Task[R]) -> R
```

Espera a la tarea y da su resultado. Esperar otra vez da el mismo valor, y `false`, `nil` y `error` son resultados normales.

- Un error de runtime en una tarea distinta de `main` es un fallo. Solo termina esa tarea: el error va a stderr de inmediato, con ` in a task` después del código (`--json` añade `"task": true`); las tareas hijas que siguen en marcha se cancelan y los handles de la tarea se cierran. Esto es seguro porque los valores son inmutables: una tarea fallida no puede dejar un valor compartido a medio actualizar, y el único estado mutable vive en los handles.
- Esperar una tarea fallida que devuelve un `Result` da un error de clase `task.crashed` con el mensaje `"task crashed: CODE at FILE:LINE:COLUMN: MESSAGE"`. Para cualquier otro tipo, la tarea que espera se detiene con `RUNTIME-TASK-CRASHED`.
- Un fallo que ningún await ve hace que la ejecución termine con código 1 cuando `main` termina.
- Esperarse a uno mismo, directamente o a través de otras tareas (un handle puede llegar por un [Channel](/library/concurrency/channel/), o dentro de un closure que lo captura), se detiene con `RUNTIME-TASK-AWAIT-CYCLE`.

```agentica
def parse(text: String) -> Result[Int] = ok(100 / text.to_i!)

def main() -> Void
  task = Task.spawn(&parse, "0")
  case Task.await(task)
    ok(n) -> puts(n)
    error(e) -> puts(e.message.start_with?("task crashed: RUNTIME-DIVISION-BY-ZERO"))
  end

  puts("still running")
end
```

```output
true
still running
```

## Task.await with a timeout {#taskawait-with-a-timeout}

```signature
Task.await(task: Task[R], timeout_ms: Int) -> Await[R]
```

Espera como máximo `timeout_ms` milisegundos.

- `Await[R]` es un enum integrado: `Await.Done(value)` guarda el resultado, y `Await.TimedOut` (sin payload ni paréntesis) significa que el tiempo se acabó antes.
- Un `case` debe cubrir las dos variantes, o usar `_`. `Await` es un nombre reservado (ninguna estructura, enum o alias de importación puede usarlo), y `try` no se aplica a él.
- El resultado puede llevar anotación (`outcome: Await[Int]`), y se puede imprimir e interpolar: `IO.inspect` muestra `Await.Done(42)` o `Await.TimedOut`. Usar `try` sobre él es `CHECK-TYPE-MISMATCH` en la llamada.
- `timeout_ms` debe ser mayor que 0; si no, `RUNTIME-INVALID-DURATION` en el argumento. Llámalo una sola vez con el tiempo total que puedas dar; no hagas sondeos.
- Un tiempo de espera agotado no cancela la tarea. Sigue en marcha, y un await posterior da su resultado. Una tarea terminada nunca da un tiempo de espera agotado.
- Si la tarea falla o se cancela antes, recibes el resultado de un await normal: `Await.Done(error(text))` para una tarea de `Result`; si no, `RUNTIME-TASK-CRASHED` o `RUNTIME-TASK-CANCELLED`. Un fallo después de `Await.TimedOut` no llega a quien llama.
- Un await con tiempo omite la comprobación de ciclos: una tarea que se espera a sí misma con tiempo de espera recibe `Await.TimedOut`, y un await normal a una tarea que espera con tiempo de espera no es `RUNTIME-TASK-AWAIT-CYCLE`.

El trabajador espera en un [Channel](/library/concurrency/channel/). La primera espera se queda sin tiempo, el trabajador sigue esperando, y la segunda espera recibe su resultado:

```agentica
def double(inbox: Channel[Int]) -> Int
  n = inbox.recv(10000).unwrap!
  n * 2
end

def main() -> Void
  inbox: Channel[Int] = Channel.new(1)
  task = Task.spawn(&double, inbox)
  case Task.await(task, 20)
    Await.Done(n) -> puts("done #{n}")
    Await.TimedOut -> puts("still working")
  end

  _ = inbox.send(21, 1000)
  case Task.await(task, 10000)
    Await.Done(n) -> puts("done #{n}")
    Await.TimedOut -> puts("gave up")
  end
end
```

```output
still working
done 42
```

En una tarea de `Result`, `Await.Done` guarda el `Result`: haz otro `case` sobre él.

```agentica
def parse(text: String) -> Result[Int] = ok(100 / text.to_i!)

def main() -> Void
  task = Task.spawn(&parse, "4")
  case Task.await(task, 1000)
    Await.Done(result) ->
      case result
        ok(n) -> puts("parsed #{n}")
        error(e) -> puts(e)
      end

    Await.TimedOut -> puts("timed out")
  end

  IO.inspect(Task.await(task, 1))
end
```

```output
parsed 25
Await.Done(ok(25))
```

Una tarea de `Void` da `Await[Void]`: cubre su payload con `_` (`Await.Done(_)`). Poner un nombre ahí es `CHECK-VOID-TYPE`.

## Task.map {#taskmap}

```signature
Task.map(items: List[A], limit: Int, timeout_ms: Int, block: Fn[A, Result[R]]) -> List[Result[R]]
```

Ejecuta la función para cada elemento en su propia tarea, como máximo `limit` a la vez. Da un `Result` por elemento, en el orden de `items`.

- Nunca es un método: `xs.map` sigue siendo el `List.map` secuencial.
- La función suele ser el bloque final. Da un `Result[R]` (`try` funciona dentro; termina un bloque que no puede fallar con `ok(x)`). Cualquier otro último valor es `CHECK-TYPE-MISMATCH`.

```agentica
def slow_double(n: Int) -> Result[Int]
  Task.sleep(100)
  ok(n * 2)
end

def main() -> Void
  results = Task.map([1, 2, 3, 4], 2, 1000) do |n| slow_double(n) end

  puts(results)
end
```

```output
[ok(2), ok(4), ok(6), ok(8)]
```

Unos 200 ms, no 400: una ventana deslizante de dos, no lotes. Los elementos empiezan en el orden de entrada.

- El `error(...)` de un elemento no detiene a los demás. Un error de runtime (`RUNTIME-DIVISION-BY-ZERO`) hace fallar solo ese elemento: su hueco es un error de clase `task.crashed` (`"task crashed: ..."`), el fallo cuenta como observado, y los demás siguen. Un elemento que se cancela por su cuenta (a través de su `Task.current`) da de inmediato `error("task: cancelled", kind: "task.cancelled")`.
- La llamada espera a todos los elementos, y los elementos son hijos de quien llama. Para usar los resultados según llegan, envíalos por un [Channel](/library/concurrency/channel/).
- Una lista vacía necesita un tipo, como cualquier lista vacía (`CHECK-EMPTY-LIST-TYPE`). El efecto es `concurrency`, igual que en `Task.spawn`.

```agentica
def main() -> Void
  results = Task.map(["30", "x", "10"], 3, 1000) do |text|
    n = try text.to_i
    Task.sleep(40 - n)
    ok(n * 2)
  end

  for result in results
    case result
      ok(n) -> puts("value #{n}")
      error(message) -> puts("failed: #{message}")
    end
  end
end
```

```output
value 60
failed: cannot convert "x" to Int
value 20
```

`R` viene del tipo esperado de la llamada, o si no, del primer `ok(...)` que da el bloque. Si el bloque solo da `error(...)`, el comprobador da `CHECK-RESULT-TYPE`: anota la variable (`results: List[Result[Int]] = Task.map(...)`). Un valor de función también funciona: `Task.map(ids, 8, 5000, &fetch)`.

`timeout_ms` es por elemento, desde el inicio de su tarea hasta su fin, incluido el tiempo que espera para ejecutarse. Un elemento lento se cancela y su hueco es `error("task: timed out", kind: "task.timeout")`; un bloque que devuelve ese mismo error por sí solo se ve igual. Un elemento que termina después de su plazo, pero antes de que quien llama mire el reloj, conserva su resultado. No hay tiempo total: una llamada tarda como máximo unos `ceil(items / limit) * timeout_ms`.

```agentica
def fetch(n: Int) -> Result[String]
  if n == 2
    Task.sleep(10000)
  end

  ok("page #{n}")
end

def main() -> Void
  pages = Task.map([1, 2, 3], 3, 200, &fetch)
  puts(pages)
end
```

```output
[ok("page 1"), error("task: timed out", kind: "task.timeout"), ok("page 3")]
```

Límites, que se comprueban antes de que empiece ningún elemento (también con una lista vacía, que da `[]`):

- `limit` va de 1 a 1024; si no, `RUNTIME-INVALID-COUNT`. Un `limit` mayor que el tamaño de la lista inicia todos los elementos a la vez.
- `timeout_ms` debe ser mayor que 0; si no, `RUNTIME-INVALID-DURATION`.

Cancelación (de un elemento que agotó su tiempo):

- No ejecuta más código, ni tampoco las tareas que inició (ni siquiera un nieto cuyo padre ya terminó, ya que una tarea que termina entrega sus hijos en marcha a su padre). Sus handles se cierran. Un elemento cuenta como terminado solo después de que se escriban y cierren los archivos regulares que abrió, así que un archivo que escribió un elemento está en disco, y su bloqueo liberado, cuando la llamada devuelve el control. Un elemento que agotó su tiempo es la excepción: su hueco se fija en el plazo, y la llamada no espera a sus archivos, que se cierran un poco después.
- Un `Task.map` que llamó el elemento se detiene: no empieza ningún elemento pendiente y los elementos en curso se cancelan.
- La E/S en curso termina o agota su tiempo por sí sola, y su resultado se descarta. Nunca cierra un handle que compartan otros elementos. Un `TCP.accept` o una lectura de socket que todavía no ha tomado nada se descarta de inmediato, así que la siguiente conexión o los bytes posteriores van a la siguiente llamada. Una conexión de `HTTP.get` que agotó su tiempo se cierra y no vuelve al pool.
- Esperar una tarea cancelada junto con el elemento se detiene con `RUNTIME-TASK-CANCELLED`, o da `error("task: cancelled")` en una tarea de `Result`.

Consejos:

- `limit` sirve sobre todo para E/S. El trabajo de CPU se ejecuta como máximo en un elemento por planificador a la vez, y un `limit` mayor que el número de planificadores hace más probables los tiempos de espera agotados.
- Abre los handles dentro del elemento. Un handle que comparten varios elementos los hace ejecutarse por turnos (por su bloqueo). Si muchas tareas necesitan un mismo handle, dáselo a una sola tarea propietaria y háblale por un [Channel](/library/concurrency/channel/).
- Los elementos, las variables capturadas y los resultados son inmutables y se comparten sin copias. Un elemento puede llamar a `Task.map`; los límites se multiplican.
- Iniciar un elemento cuesta un paso de `--max-steps`, más los del propio bloque, así que una llamada en la que ningún elemento agota su tiempo tiene un número fijo de pasos. Quien llama no gasta pasos mientras espera, y construir la lista de resultados cuesta una unidad del presupuesto de turnos por elemento. Con `--seed`, cada elemento recibe su propio generador aleatorio, dividido en orden de entrada, así que salen los mismos números sea cual sea el orden en que terminen los elementos.

## Task.sleep {#tasksleep}

```signature
Task.sleep(milliseconds: Int) -> Void
```

Pausa la tarea actual. `0` deja que otras tareas se ejecuten; un valor negativo es `RUNTIME-INVALID-DURATION`.

```agentica
def late(label: String) -> String
  Task.sleep(30)
  puts(label)
  label
end

def main() -> Void
  task = Task.spawn(&late, "second")
  puts("first")
  _done = Task.await(task)
end
```

```output
first
second
```

Un bloque también puede ejecutarse en una tarea, cuando lo pasas por un parámetro de función:

```agentica
def start(f: Fn[Int, Int]) -> Task[Int] = Task.spawn(f, 20)

def main() -> Void
  task = start do |n| n + 1 end
  puts(Task.await(task))
end
```

```output
21
```

## Task.cancel {#taskcancel}

```signature
Task.cancel(task: Task[R]) -> Void
```

Detiene una tarea que ya no necesitas, y todas las tareas que inició. No espera: la tarea queda marcada y la llamada devuelve el control.

- Una tarea se cancela con `Task.cancel`, con el fallo de uno de sus antecesores, con el tiempo de espera agotado de su elemento de `Task.map` y con `HTTP.close_server` (las tareas de los handlers). También acepta el `TaskRef` de [Task.current](#taskcurrent). `main` no se puede cancelar: cancelar su `Task.current` no hace nada. Un tipo de argumento incorrecto es `CHECK-TYPE-MISMATCH` en el argumento.
- Una pausa, una espera de canal, un await o una espera de E/S terminan de inmediato; una tarea ocupada en un bucle de otro planificador se detiene al final de su turno actual, así que puede terminar como cancelada aunque haya llegado a su return.
- Una cancelación que llega durante el turno gana aunque el turno haya devuelto el control, así que se pierde un elemento que una llamada que consume (lecturas de `Channel`, `TCP` o `Process`) ya tomó. Para detener un lector sin perder ningún elemento, da a la lectura un tiempo de espera (`Process.poll_line`, una recepción con tiempo de espera) y deja que la tarea termine por sí sola.
- Sus handles se cierran como al terminar cualquier tarea, así que un canal que posee (de `Task.spawn_owning`) se cierra y sus receptores reciben `error("channel: closed")`.
- Esperarla da `error("task: cancelled")` en una tarea de `Result`, y si no, detiene el programa con `RUNTIME-TASK-CANCELLED`.
- Cancelar una tarea que ya terminó, o cancelarla dos veces, no hace nada. Cualquier tarea que tenga el handle puede cancelarla. Una tarea que se cancela a sí misma, o la que la inició, se detiene justo después de la llamada.
- Una cancelación no es un fallo: no hay informe de fallo y el código de salida no cambia.

```agentica
def keep(inbox: Channel[Int]) -> Result[Int]
  total = 0
  while true
    total += try inbox.recv(60000)
  end

  ok(total)
end

def main() -> Void
  inbox: Channel[Int] = Channel.new(4)
  keeper = Task.spawn(&keep, inbox)
  _ = inbox.send(5, 1000)
  Task.cancel(keeper)
  puts(Task.await(keeper))
end
```

```output
error("task: cancelled", kind: "task.cancelled")
```

## Task.monitor {#taskmonitor}

```signature
Task.monitor(task: Task[R], channel: Channel[M], message: Fn[TaskDown, M]) -> Void
```

Cuando `task` termina por cualquier motivo (devuelve un valor, falla o se cancela), el runtime envía `message(TaskDown(...))` a `channel` una sola vez. No hay `select`, así que el canal suele ser el único canal de quien llama, un enum con una variante para el aviso: `Task.monitor(task, inbox) do |down| Msg.Down(down) end`.

- `TaskDown` es un registro integrado: `task_id: Int` (el `task.id` de la tarea), `reason: TaskExit`, y luego el diagnóstico de un fallo: `code: String` (el código estable, como `RUNTIME-DIVISION-BY-ZERO`, para comparar), `message: String`, y `file: String`, `line: Int` y `column: Int`, donde se lanzó el error. Para `TaskExit.Ok` y `TaskExit.Cancelled` las cadenas son `""` y los números `0`. `TaskExit` es un enum integrado: `TaskExit.Ok`, `TaskExit.Crashed` o `TaskExit.Cancelled`, que se leen en el mismo orden que `Task.await` (primero un fallo, luego una cancelación). Los dos nombres están reservados.
- Una tarea que ya terminó recibe su aviso de inmediato, y una tarea puede tener varios monitores, cada uno con su propio aviso. Un monitor no se puede quitar.
- El envío nunca espera y nunca falla. Un aviso que encuentra el canal lleno entra igual, por encima de su capacidad, después de los valores que ya hay en él; así que no se pierde mientras el canal esté abierto: un `send` sigue encontrando el canal lleno hasta que el receptor haya tomado los valores que exceden la capacidad. La capacidad no limita estos avisos: cada uno que queda por encima ocupa un valor más en memoria. Un aviso para un canal cerrado, o para el canal de [System.subscribe](/library/io-and-system/system/#systemsubscribe), se descarta sin error.
- Un fallo cuyo aviso entra en el canal cuenta como observado, igual que un await, así que no hace que la ejecución termine con código 1. Cuenta en cuanto el aviso está en el canal, aunque nadie lo reciba nunca. Un monitor a través de un `TaskRef` no observa el fallo: solo lo observa quien tiene el `Task[R]`, que puede esperarla.
- `task` también puede ser el `TaskRef` de [Task.current](#taskcurrent).
- El aviso llega en cuanto la tarea terminada ha cerrado lo que posee, igual que en `Task.await`. El bloque `message` se ejecuta en una tarea propia, fuera del árbol de quien llama, así que una cancelación nunca lo alcanza; limítalo a construir el mensaje. Un error de runtime en `message` es un fallo de esa tarea, y el aviso se pierde.

Un coordinador que reinicia un trabajador que falló:

```agentica
struct Job
  id: Int
  attempt: Int
end

enum Msg
  Done(Int, Int)
  Down(TaskDown)
end

def work(job: Job, inbox: Channel[Msg]) -> Void
  if job.attempt == 1 and job.id == 2
    puts("never #{10 / (job.id - 2)}")
  end

  _ = inbox.send(Msg.Done(job.id, job.id * 10), 1000)
end

def start(job: Job, inbox: Channel[Msg], running: Map[Int, Job]) -> Map[Int, Job]
  task = Task.spawn do work(job, inbox) end
  Task.monitor(task, inbox) do |down| Msg.Down(down) end
  running.put(task.id, job)
end

def main() -> Void
  inbox: Channel[Msg] = Channel.new(16)
  running: Map[Int, Job] = {}
  for id in 1..3
    running = start(Job(id: id, attempt: 1), inbox, running)
  end

  results: List[String] = []
  while running.size > 0
    case inbox.recv(5000).unwrap!
      Msg.Done(id, value) -> results = results.push("job #{id}: #{value}")
      Msg.Down(down) ->
        job = running[down.task_id]
        running = running.delete(down.task_id)
        if down.reason == TaskExit.Crashed
          puts("restart job #{job.id} after #{down.code}")
          running = start(job.with(attempt: job.attempt + 1), inbox, running)
        end
    end
  end

  puts(results.sort)
end
```

```output
restart job 2 after RUNTIME-DIVISION-BY-ZERO
["job 1: 10", "job 2: 20", "job 3: 30"]
```

El fallo del primer intento sigue yendo a stderr en el momento en que ocurre.

## Task.current {#taskcurrent}

```signature
Task.current() -> TaskRef
task.id() -> Int
```

`Task.current` da la tarea en ejecución como un `TaskRef`, para que otra tarea pueda vigilarla. `TaskRef` es un tipo integrado y reservado, para una tarea cuyo tipo de resultado no se conoce en el lugar de la llamada: `Task.monitor`, `Task.cancel` e `id` lo reciben, y un await sobre él es `CHECK-TYPE-MISMATCH` en el argumento (no tiene resultado que dar; vigílalo para saber cuándo termina). Se imprime como `<Task>` y no tiene igualdad. `task.id` da el número que identifica una tarea en la ejecución, para un `Task[R]` o un `TaskRef`: el `task_id` de su `TaskDown`.

Un hijo vigila la tarea que lo inició:

```agentica
def watch(parent: TaskRef, report: Channel[String]) -> Void
  downs: Channel[TaskDown] = Channel.new(1)
  Task.monitor(parent, downs) do |down| down end
  down = downs.recv(5000).unwrap!
  _ = report.send("parent ended: #{down.reason}", 1000)
end

def parent(report: Channel[String]) -> Int
  me = Task.current
  _child = Task.spawn do watch(me, report) end
  7
end

def main() -> Void
  report: Channel[String] = Channel.new(1)
  task = Task.spawn(&parent, report)
  puts(Task.await(task))
  puts(report.recv(5000).unwrap!)
end
```

```output
7
parent ended: TaskExit.Ok
```

## Task.pending_count {#taskpending_count}

```signature
Task.pending_count() -> Int
```

Da cuántas tareas aún no han terminado, sin contar `main`.

- Las tareas en espera, en pausa o haciendo await cuentan, y también quien pregunta, salvo que sea `main`. Las tareas que devolvieron un valor o fallaron no cuentan, estén esperadas o no.
- Las tareas que `std/http` inicia para un `HTTP.Client` nunca cuentan, y `Test.test` no las ve como sobrantes.

```agentica
def wait_for(task: Task[Int]) -> Int = Task.await(task)

def nap(ms: Int) -> Int
  Task.sleep(ms)
  ms
end

def main() -> Void
  puts(Task.pending_count())
  first = Task.spawn(&nap, 20)
  second = Task.spawn(&wait_for, first)
  puts(Task.pending_count())
  puts(Task.await(second))
  puts(Task.pending_count())
end
```

```output
0
2
20
0
```

## Task.unobserved_crash {#taskunobserved_crash}

```signature
Task.unobserved_crash() -> Result[String]
```

Da `ok(text)` con el primer fallo que ningún `Task.await` ha visto; si no, `error("no unobserved crash")`. Preguntar no cuenta como verlo.

```agentica
def boom(n: Int) -> Int = 10 / n

def main() -> Void
  puts(Task.unobserved_crash().ok?)
  _task = Task.spawn(&boom, 0)
  while !Task.unobserved_crash().ok?
    Task.sleep(1)
  end

  puts(Task.unobserved_crash().ok?)
  System.exit(0)
end
```

```output
false
true
```

## How a run ends {#how-a-run-ends}

Algunos errores terminan toda la ejecución, sin importar qué tarea los lance: un error de runtime en `main`, `RUNTIME-STEP-LIMIT`, un error interno de la VM y `System.exit` en cualquier tarea. El primero de ellos gana.

Un fallo se observa cuando un await devuelve su error o se detiene, cuando el aviso de su [monitor](#taskmonitor) a través de un `Task[R]` entra en el canal, o cuando `Test.run` lo informa. Si `main` termina con un fallo que nunca se observó, la ejecución termina con código 1 e imprime una línea en stderr: `2 task crashes were not observed; first: task crashed: ...` (con `--json`, `{"unobserved_crashes":2,"first":"task crashed: ..."}`).

Cuando `main` termina, la ejecución termina, y las tareas pendientes ya no se ejecutan. Al final de cualquier ejecución, la VM vacía y cierra los archivos abiertos, y espera a que la salida almacenada en búfer de stdout y stderr llegue a la tubería o al archivo (acotado por el límite de vaciado, 30 segundos por defecto, `--flush-timeout`), libera lo que el código nativo aún posee dentro del mismo límite, cierra sockets y listeners, y detiene y recoge los procesos hijos que inició. Los flujos estándar siguen abiertos.
