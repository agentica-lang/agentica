---
title: Canal
weight: 2
description: Envía valores de una tarea a otra por una cola.
source_hash: "ea6208418f56"
---

Un canal es una cola, acotada o sin límite: una tarea envía valores y otra los recibe. Consulta también [Tareas](/tour/tasks/).

- `Channel[T]` guarda valores de un solo tipo, cualquier tipo que pueda tener una variable: se admite un handle de tarea, un socket, un archivo u otro canal, y `Channel[Void]` es `CHECK-VOID-TYPE`.
- Un canal es un handle: pasarlo a una función o a una tarea lo comparte. `Channel` es un nombre reservado: una `struct`, `enum` o alias de importación de usuario que se llame `Channel` es `CHECK-REDEFINED-NAME`.
- `puts`, `print`, la interpolación y `==` sobre un canal dan `CHECK-TYPE-MISMATCH`, `.to_s` da `CHECK-UNKNOWN-METHOD`, y una estructura con un campo de canal es `CHECK-NOT-ENCODABLE` como JSON. `IO.inspect` imprime `<Channel>`.
- `send`, `recv`, `close` y `Address.send` llevan el efecto `concurrency`; `new`, `closed?`, `empty?` y `address` no llevan ninguno.
- No hay `select`, ni `for x in channel`, ni canales sin búfer.
- `send`, `recv`, `close`, `closed?`, `empty?` y `address` también funcionan como métodos: `jobs.send(5, 1000)` es `Channel.send(jobs, 5, 1000)`.
- La [dirección](#channeladdress) de un canal es un dato que lo nombra: una tabla, un mensaje o una tabla constante pueden guardarla donde el canal en sí no puede ir.

## Channel.new {#channelnew}

```signature
Channel.new(capacity: Int) -> Channel[T]
Channel.new() -> Channel[T]
```

Con una capacidad, el canal guarda de 1 a 1048576 valores; si no, `RUNTIME-INVALID-COUNT`, y un canal lleno hace esperar al emisor. Sin ella, el canal no tiene límite, como `Queue.new` de Ruby (un buzón de Erlang): un envío nunca espera, y su `timeout_ms` se sigue comprobando pero nunca se usa. Necesita un tipo esperado (anotación, parámetro, campo o tipo de retorno); si no, `CHECK-EXPECTED-TYPE`.

Un canal sin límite guarda cada valor hasta que se recibe: su búfer crece para guardarlos y nunca se encoge. Cuando se agota la memoria de la ejecución, con `--max-heap` ([Opciones](/cli/#options)) la ejecución se detiene con `RUNTIME-HEAP-LIMIT`. Si el receptor puede quedarse atrás, elige una capacidad: un canal lleno frena a los emisores en vez de hacerlos crecer.

```agentica {expect="CHECK-EXPECTED-TYPE"}
def main() -> Void
  jobs = Channel.new(4)
end
```

```agentica
def main() -> Void
  jobs: Channel[Int] = Channel.new(4)
  puts(jobs.closed?)
  mailbox: Channel[String] = Channel.new
  (1..1000).each do |n| _ = mailbox.send("message #{n}", 0) end
  puts(mailbox.recv(0).unwrap!)
end
```

```output
false
message 1
```

## Channel.send {#channelsend}

```signature
Channel.send(channel: Channel[T], value: T, timeout_ms: Int) -> Result[Void]
```

Añade el valor al final y da `ok()`. Si un canal acotado está lleno, la tarea espera a que haya sitio, a que se cierre el canal o a `timeout_ms`. El valor no se añade en estos casos:

- `error("channel: closed")`, la razón de un [cierre con razón](#channelclose), o `error("channel: timed out")`.

`timeout_ms` es 0 o más; `0` lo intenta una vez y nunca espera. Un valor negativo es `RUNTIME-INVALID-DURATION`. Nada espera para siempre.

```agentica
def main() -> Void
  jobs: Channel[String] = Channel.new(2)
  puts(jobs.send("a", 0).ok?)
  puts(jobs.send("b", 0).ok?)
  puts(jobs.send("c", 0).message)
end
```

```output
true
true
channel: timed out
```

## Channel.recv {#channelrecv}

```signature
Channel.recv(channel: Channel[T], timeout_ms: Int) -> Result[T]
```

Toma el valor más antiguo (primero en entrar, primero en salir) y da `ok(value)`. Si está vacío, la tarea espera a un valor, a un cierre o a `timeout_ms`. Las tareas en espera se atienden en el orden en que empezaron a esperar, y lo mismo los emisores en espera, sin colarse: un valor enviado va directo al primer receptor en espera. Una espera que se va antes de ejecutarse, porque la cancelaron o porque antes se agotó su tiempo de espera, pasa lo que recibió a la siguiente. Un receptor al que le dieron un valor lo devuelve aunque su plazo pase antes de que se ejecute. Ningún valor se pierde ni se añade dos veces. Errores:

- `error("channel: closed")` cuando el canal está cerrado y se han tomado todos los valores (la razón, en un [cierre con razón](#channelclose)), o `error("channel: timed out")`.

```agentica
def main() -> Void
  jobs: Channel[Int] = Channel.new(4)
  _ = jobs.send(10, 0)
  _ = jobs.send(20, 0)
  puts(jobs.recv(0).unwrap!)
  puts(jobs.recv(0).unwrap!)
  puts(jobs.recv(0).message)
end
```

```output
10
20
channel: timed out
```

## Channel.close {#channelclose}

```signature
Channel.close(channel: Channel[T]) -> Void
Channel.close(channel: Channel[T], error: Error) -> Void
```

Cerrar otra vez no hace nada, con razón o sin ella: se queda el primer cierre. Los emisores en espera reciben el error de cierre, y lo mismo los emisores despertados que aún no se han ejecutado. Los receptores reciben los valores que quedan y después el error de cierre.

Con un [`Error`](/library/errors/error/), los emisores reciben `error(error)`, con ese mismo `Error`, en lugar de `error("channel: closed")`, y lo mismo los receptores una vez tomados los valores que quedan: el receptor sabe por qué terminó el flujo. El error se guarda aparte de los valores, así que un canal lleno se puede cerrar con él. [`ch.lazy`](/library/data-structures/lazy/#chlazy) da los valores que quedan y después termina el método final con él.

- El lado emisor debe cerrar en todos los caminos; los receptores no deben hacerlo. Si nadie lo cierra, un bucle de recepción nunca termina.
- Un canal con propietario también se cierra cuando su propietario termina ([Un productor que posee el canal](#a-producer-that-owns-the-channel)).

```agentica
def main() -> Void
  jobs: Channel[Int] = Channel.new(4)
  _ = jobs.send(1, 0)
  jobs.close
  puts(jobs.send(2, 0).message)
  puts(jobs.recv(0).unwrap!)
  puts(jobs.recv(0).message)
end
```

```output
channel: closed
1
channel: closed
```

Un productor que falla pasa su error:

```agentica
def fetch(n: Int) -> Result[Int]
  return error("connection reset", kind: "net.closed") if n == 3

  ok(n * 10)
end

def send_all(jobs: Channel[Int]) -> Result[Void]
  for n in 1..5
    try jobs.send(try fetch(n), 1000)
  end

  ok()
end

def produce(jobs: Channel[Int]) -> Void
  case send_all(jobs)
    ok(_) -> jobs.close
    error(e) -> jobs.close(e)
  end
end

def main() -> Void
  jobs: Channel[Int] = Channel.new(4)
  Task.spawn(&produce, jobs)
  puts(jobs.recv(1000).unwrap!)
  puts(jobs.recv(1000).unwrap!)
  case jobs.recv(1000)
    ok(n) -> puts(n)
    error(e) -> puts("#{e.kind}: #{e.message}")
  end
end
```

```output
10
20
net.closed: connection reset
```

## Channel.closed? {#channelclosed}

```signature
Channel.closed?(channel: Channel[T]) -> Bool
```

Da `true` en cuanto el canal está cerrado, aunque aún tenga valores, igual que `Queue#closed?` de Ruby; y se queda en `true`. Un productor que está ocupado entre envíos (decodificando el siguiente token, leyendo el siguiente trozo de un archivo) lo lee para saber que el receptor cerró el canal antes de que su próximo `send` falle.

```agentica
def main() -> Void
  jobs: Channel[Int] = Channel.new(4)
  _ = jobs.send(1, 0)
  jobs.close
  puts(jobs.closed?)
  puts(jobs.empty?)
  puts(jobs.recv(0).unwrap!)
  puts(jobs.empty?)
end
```

```output
true
false
1
true
```

## Channel.empty? {#channelempty}

```signature
Channel.empty?(channel: Channel[T]) -> Bool
```

Da `true` cuando no queda ningún valor por recibir: el búfer está vacío y ningún valor está reservado para un receptor despertado. Una vez cerrado el canal no llega ningún valor, así que `closed? and empty?` dice que el flujo terminó, y se queda en `true`. Pregunta primero por `closed?`: un valor y el cierre pueden llegar los dos entre un `empty?` que da `true` y un `closed?` posterior. Tras un error de `recv`, `closed? and empty?` distingue el fin del flujo de un tiempo de espera agotado.

## Channel.address {#channeladdress}

```signature
Channel.address(channel: Channel[T]) -> Address[T]
```

Una referencia solo de envío al canal, como un pid en Erlang. El canal sigue siendo un handle con un solo receptor; su dirección es un dato:

- Un valor de [ATS](/library/concurrency/ats/), un elemento de `List`, un valor de `Map`, un campo de estructura, el payload de una variante de enum y un mensaje pueden guardarla, y una [tabla constante](/library/concurrency/ats/#a-constant-table) de direcciones es un registro por nombre.
- `==` da `true` para dos direcciones de un mismo canal. `puts` e `IO.inspect` imprimen `<Address N>`, donde `N` cuenta las direcciones de la ejecución desde 1.
- No es codificable como JSON (`CHECK-NOT-ENCODABLE`), no es clave de `Map` ni elemento de `Set` (`CHECK-MAP-KEY-TYPE`, `CHECK-SET-ELEMENT-TYPE`), y no se permite en una constante (`CHECK-CONSTANT-TYPE`).
- No mantiene vivo el canal y tampoco es un handle: `Task.spawn_owning` no la transfiere ([un handle con propietario, un canal compartido](#one-handle-owned-one-channel-shared)).
- `Address` no es un nombre reservado: una `struct Address` de usuario está permitida, y `Address[T]` con un argumento de tipo siempre es este tipo, así que una estructura genérica, un enum o un alias llamado `Address` es `CHECK-REDEFINED-NAME`.

## Address.send {#addresssend}

```signature
Address.send(address: Address[T], value: T, timeout_ms: Int) -> Result[Void]
```

[`Channel.send`](#channelsend) al canal de la dirección, con las mismas esperas, tiempos de espera y errores: `error("channel: closed")` una vez cerrado el canal. `error("address: gone")` cuando nada más llega al canal y el recolector de basura lo ha liberado, así que ninguna tarea puede recibir de él ya. Un envío desde otra ejecución es `RUNTIME-ADDRESS-CONTEXT`. No hay `recv` sobre una dirección.

```agentica
def main() -> Void
  inbox: Channel[Int] = Channel.new(4)
  names: ATS[String, Address[Int]] = ATS.new()
  names.put("counter", inbox.address)
  to = names.get("counter").unwrap!
  puts(to == inbox.address)
  puts(to.send(7, 1000).ok?)
  puts(inbox.recv(0).unwrap!)
  inbox.close
  puts(to.send(8, 1000).message)
end
```

```output
true
true
7
channel: closed
```

## Un productor y un consumidor {#a-producer-and-a-consumer}

El bucle de recepción: ante un error, `closed? and empty?` dice si el flujo terminó; si no, fue un tiempo de espera agotado y el bucle vuelve a recibir. El productor cierra en todos los caminos: `send_all` contiene los `try`, así que `produce` siempre llega a `jobs.close`.

```agentica
def send_all(jobs: Channel[Int]) -> Result[Void]
  for n in 1..5
    try jobs.send(n, 1000)
  end

  ok()
end

def produce(jobs: Channel[Int]) -> Result[Void]
  result = send_all(jobs)
  jobs.close
  result
end

def main() -> Void
  jobs: Channel[Int] = Channel.new(2)
  producer = Task.spawn(&produce, jobs)
  total = 0
  while true
    case jobs.recv(1000)
      ok(n) -> total += n
      error(_) -> break if jobs.closed? and jobs.empty?
    end
  end

  puts(total)
  puts(Task.await(producer).ok?)
end
```

```output
15
true
```

El mismo consumidor, hecho con un [`Lazy`](/library/data-structures/lazy/#chlazy), no necesita bucle: `jobs.lazy(1000).reduce(0) do |total, n| total + n end` es `ok(15)`.

## Un productor que posee el canal {#a-producer-that-owns-the-channel}

`Task.spawn_owning(&produce, jobs)` hace que la tarea sea la propietaria. Cuando termina de cualquier forma (devuelve un valor, falla o se cancela), el canal se cierra. El receptor recibe los valores ya enviados y, después, el error de cierre de inmediato, sin esperar al tiempo de espera cuando el productor falló.

```agentica
def produce(jobs: Channel[Int]) -> Result[Void]
  try jobs.send(1, 1000)
  try jobs.send(2, 1000)
  zero = 0
  try jobs.send(100 / zero, 1000)
  ok()
end

def main() -> Void
  jobs: Channel[Int] = Channel.new(4)
  producer = Task.spawn_owning(&produce, jobs)
  while true
    case jobs.recv(5000)
      ok(n) -> puts(n)
      error(e) ->
        puts(e)
        break
    end
  end

  puts(Task.await(producer).ok?)
end
```

```output
1
2
channel: closed
false
```

Reglas de propiedad:

- Un canal que nunca se ha transferido no tiene propietario: solo `close` lo cierra. `Task.spawn(&f, jobs)` no crea un propietario.
- El primer `Task.spawn_owning` puede venir de cualquier tarea. Después, solo el propietario puede transferirlo; cualquier otra tarea, o cualquier tarea una vez cerrado el canal, se detiene con `RUNTIME-HANDLE-NOT-OWNED`. Cualquier tarea puede seguir llamando a `Channel.close`.
- Hay un solo propietario. Para varios productores, usa el patrón siguiente.

## Un handle con propietario, un canal compartido {#one-handle-owned-one-channel-shared}

`Task.spawn_owning` transfiere cada handle de su argumento, así que un canal en ese argumento se cierra cuando termina la tarea. Para dar a una tarea su propio handle (un socket, un canal propio) y además un canal que otras tareas siguen usando, pon la dirección del canal compartido en el argumento: una dirección es un dato, así que el canal compartido sigue abierto.

```agentica
struct Link
  jobs: Channel[Int]
  results: Address[Int]
end

def serve(link: Link) -> Result[Int]
  n = try link.jobs.recv(1000)
  try link.results.send(n * 10, 1000)
  ok(n)
end

def main() -> Void
  results: Channel[Int] = Channel.new(4)
  jobs: Channel[Int] = Channel.new(1)
  _ = jobs.send(4, 0)
  worker = Task.spawn_owning(&serve, Link(jobs: jobs, results: results.address))
  puts(Task.await(worker).ok?)
  puts(jobs.closed?)
  puts(results.closed?)
  puts(results.recv(0).unwrap!)
end
```

```output
true
true
false
40
```

## Varias fuentes {#several-sources}

No hay `select`. Une las fuentes en un solo canal de un enum, con una variante por cada clase de evento. Un coordinador espera a cada fuente y luego cierra el canal, así el bucle de recepción termina.

```agentica
enum Event
  Item(String, Int)
  Failed(String)
end

struct Source
  name: String
  count: Int
  events: Channel[Event]
end

struct Coordinator
  sources: List[Task[Void]]
  events: Channel[Event]
end

def emit(source: Source) -> Void
  i = 1
  while i <= source.count
    _ = source.events.send(Event.Item(source.name, i * 10), 1000)
    i += 1
  end

  if source.count == 0
    _ = source.events.send(Event.Failed("#{source.name} has nothing"), 1000)
  end
end

def coordinate(c: Coordinator) -> Void
  c.sources.each do |source| Task.await(source) end

  c.events.close
end

def main() -> Void
  events: Channel[Event] = Channel.new(2)
  sources = [
    Task.spawn(&emit, Source(name: "a", count: 3, events: events)),
    Task.spawn(&emit, Source(name: "b", count: 0, events: events)),
    Task.spawn(&emit, Source(name: "c", count: 2, events: events)),
  ]

  coordinator = Task.spawn(&coordinate, Coordinator(sources: sources, events: events))
  totals: Map[String, Int] = {}
  while true
    case events.recv(1000)
      ok(event) ->
        case event
          Event.Item(name, value) -> totals = totals.put(name, totals.get(name, 0) + value)
          Event.Failed(text) -> puts(text)
        end

      error(_) -> break if events.closed? and events.empty?
    end
  end

  Task.await(coordinator)
  totals.keys.sort.each do |name| puts("#{name}: #{totals.get(name, 0)}") end
end
```

```output
b has nothing
a: 60
c: 30
```

## Estado que posee una sola tarea {#state-owned-by-one-task}

Las tareas no comparten valores mutables, salvo las tablas [ATS](/library/concurrency/ats/). Por eso, el estado que varias tareas actualizan con más de una llamada a una tabla pertenece a una sola tarea propietaria, que recibe mensajes por un canal y guarda el estado en sus propias variables.

```agentica
def count(inbox: Channel[Int]) -> Int
  total = 0
  while true
    case inbox.recv(1000)
      ok(n) -> total += n
      error(_) -> break if inbox.closed? and inbox.empty?
    end
  end

  total
end

def send_three(inbox: Channel[Int]) -> Void
  _ = inbox.send(1, 1000)
  _ = inbox.send(2, 1000)
  _ = inbox.send(3, 1000)
end

def main() -> Void
  inbox: Channel[Int] = Channel.new(4)
  counter = Task.spawn(&count, inbox)
  sender = Task.spawn(&send_three, inbox)
  Task.await(sender)
  inbox.close
  puts(Task.await(counter))
end
```

```output
6
```

## Tareas que se esperan entre sí {#waiting-on-each-other}

Una tarea que espera a un canal siempre tiene un temporizador, así que las tareas que se esperan entre sí terminan con errores de tiempo de espera en vez de quedarse colgadas.

```agentica
def wait_for(inbox: Channel[Int]) -> Result[Int] = inbox.recv(20)

def main() -> Void
  inbox: Channel[Int] = Channel.new(1)
  task = Task.spawn(&wait_for, inbox)
  puts(Task.await(task).message)
end
```

```output
channel: timed out
```

Una tarea que recibe su propio handle por un canal y lo espera se detiene con `RUNTIME-TASK-AWAIT-CYCLE`; en una tarea de `Result`, quien espera recibe el fallo como un error.

```agentica
def follow(inbox: Channel[Task[Result[Int]]]) -> Result[Int]
  me = inbox.recv(1000).unwrap!
  Task.await(me)
end

def main() -> Void
  inbox: Channel[Task[Result[Int]]] = Channel.new(1)
  task = Task.spawn(&follow, inbox)
  _ = inbox.send(task, 1000)
  puts(Task.await(task).message.start_with?("task crashed: RUNTIME-TASK-AWAIT-CYCLE"))
end
```

```output
true
```
