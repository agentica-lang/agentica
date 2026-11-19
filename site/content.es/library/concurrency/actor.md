---
title: Actor (std)
weight: 5
description: El módulo std/actor, una tarea que posee su estado y atiende los mensajes de un buzón, con cast, call, send y await, stop y un tiempo de espera de recepción.
source_hash: "205a2f758def"
---

`std/actor` está escrito en Agentica, sobre [Task](/library/concurrency/task/) y [Channel](/library/concurrency/channel/): `import Actor from "std/actor"`. Un actor es una tarea que posee su estado y atiende los mensajes de un buzón, uno a la vez, así que su estado no necesita bloqueo ni tabla `ATS`.

- Un `Actor.Behaviour[S, M]` es una estructura de funciones, el contrato de un actor, ya que Agentica no tiene traits: `init` crea el primer estado y `handle` recibe el estado y un mensaje y da el siguiente paso. `S` es el estado y `M` el tipo de mensaje, un enum propio.
- `Actor.start` lo ejecuta en una tarea propia y da un `Actor.Ref[S, M]`. Su `address` es el `Address[M]` del buzón: un dato que puede guardar una tabla, un mensaje o una estructura. `cast`, `call` y `send` reciben esa dirección; `stop` recibe el `Ref`.
- Un módulo suele ocultar el enum de mensajes tras sus propias funciones (`Counter.add`, `Counter.get`), y guarda las direcciones de sus actores por nombre en una tabla constante, una por tipo de mensaje. La biblioteca no incluye un registro de nombres.
- No hay métodos: llama a `Actor.cast(address, message)`.

## Actor.start {#actorstart}

```signature
Actor.start(behaviour: Actor.Behaviour[S, M], options: Actor.Options = Actor.Options()) -> Actor.Ref[S, M]
Actor.Behaviour(init: Fn[S], handle: Fn[S, M, Actor.Step[S]], terminate: Optional[Fn[S, Void]] = none, timeout: Optional[Actor.Timeout[S]] = none)
Actor.Options(capacity: Int = 1024)
Actor.continue(state: S) -> Actor.Step[S]
Actor.done(state: S) -> Actor.Step[S]
```

Inicia el actor en una tarea propia. La tarea ejecuta `init` y después toma los mensajes del buzón en el orden en que llegaron, y entrega cada uno a `handle` junto con el estado. El handler termina con `Actor.continue(state)` para seguir con ese estado, o con `Actor.done(state)` para terminar el actor: entonces ya no atiende más mensajes y ejecuta `terminate` con el último estado. `capacity` es cuántos mensajes caben en el buzón antes de que `cast` y `call` esperen a que haya sitio (de 1 a 1048576; si no, `RUNTIME-INVALID-COUNT`).

La tarea posee el buzón, así que el buzón se cierra cuando el actor termina de cualquier forma: se detuvo, dio `done`, falló o se canceló. Un error de runtime en un handler es un fallo de la tarea del actor (consulta [Task](/library/concurrency/task/)): su diagnóstico se imprime de inmediato, `terminate` no se ejecuta y los mensajes que quedan en el buzón se pierden. Un fallo que nadie observa hace fallar la ejecución cuando `main` termina (`1 task crash was not observed`); `Actor.stop`, `Task.await(actor.task)` o un `Task.monitor` de `actor.task` lo observan.

La tarea del actor es hija de la tarea que llama a `start`: si esa tarea falla o se cancela, el actor también se cancela. Inicia un actor de larga vida desde `main` o desde un [supervisor](/library/concurrency/supervisor/).

Un `Ref` tiene tres campos: `address`, `inbox` (el `Channel[M]`) y `task`. Envía por `address`. El `inbox` existe solo para `Task.monitor`: nunca recibas de él, porque se llevaría un mensaje del actor.

## Actor.inbox {#actorinbox}

```signature
Actor.inbox() -> Channel[M]
```

El buzón del actor en ejecución, como el `self()` de Erlang: `init`, un handler, `terminate` o un tiempo de espera pueden vigilar una tarea y enviar el aviso a él, `Task.monitor(task, inbox) do |down| Msg.Down(down) end`, o entregar `inbox.address`. Nunca recibas de él. `M` viene del tipo esperado, `inbox: Channel[Msg] = Actor.inbox`, y no se comprueba: debe ser el tipo de mensaje del actor, o un valor enviado por él hace fallar el handler del actor con `RUNTIME-INTERNAL`. Si se llama fuera de la tarea de un actor, también en una tarea que el actor lanzó, es `RUNTIME-UNWRAP-ERROR` (`actor: not in an actor`).

## Actor.cast and Actor.call {#actorcast-and-actorcall}

```signature
Actor.cast(address: Address[M], message: M, timeout_ms: Int = 5000) -> Result[Void]
Actor.call(address: Address[M], timeout_ms: Int, make: Fn[Channel[R], M]) -> Result[R]
Actor.reply(channel: Channel[R], value: R) -> Bool
```

`cast` pone un mensaje en el buzón y regresa; espera como máximo `timeout_ms` a que haya sitio cuando el buzón está lleno. `call` crea un canal de respuesta, construye el mensaje alrededor de él con el bloque, lo envía y espera la respuesta, todo dentro de `timeout_ms`. El handler responde con `Actor.reply(channel, value)`, que nunca espera: indica si quien llama recibe el valor, y cierra el canal. Una llamada tiene una sola respuesta, así que una segunda da `false`. Una llamada que se rinde cierra su canal de respuesta, así que un `reply` posterior da `false` y el valor sigue siendo del actor (un pool devuelve al trabajador a su lugar); una respuesta que llegó justo antes de que la llamada se rindiera la devuelve la propia llamada. Así, una respuesta nunca se pierde: o la llamada la devuelve, o `reply` da `false`. La única excepción es quien llama y se cancela mientras espera: su canal sigue abierto, y `reply` da `true` por un valor que nadie lee. Cada llamada tiene su propio canal de respuesta, así que una respuesta nunca llega a una llamada posterior. Un `timeout_ms` de 0 lo intenta una vez: `cast` envía solo cuando hay sitio, y `call(address, 0)` igual pone el mensaje en el buzón y, después, casi siempre da `actor: timeout`. Da a `call` un tiempo de espera mayor que 0; uno negativo es `RUNTIME-INVALID-DURATION`.

Errores: `actor: timeout` (clase `channel.timeout`) cuando el buzón sigue lleno o la respuesta no llega a tiempo, y `address: gone` (clase `channel.gone`) cuando el actor ha terminado. Una llamada cuyo actor falla o termina antes de responder espera hasta su tiempo de espera. Una llamada a la dirección del propio actor desde su handler, o dos actores que se llaman entre sí, también esperan hasta su tiempo de espera, ya que un actor atiende un mensaje de uno en uno; envía el trabajo a otra tarea.

El tipo de la respuesta viene del tipo esperado (el tipo de retorno de la función que devuelve la llamada, o una anotación), o si no, del bloque: en `Msg.Get(reply)`, el payload de la variante hace que `reply` sea un `Channel[Int]`, así que `puts(Actor.call(address, 1000) do |reply| Msg.Get(reply) end)` también funciona.

```agentica
import Actor from "std/actor"

enum Msg
  Add(Int)
  Get(Channel[Int])
end

def handle(count: Int, msg: Msg) -> Actor.Step[Int]
  case msg
    Msg.Add(n) -> Actor.continue(count + n)
    Msg.Get(reply) ->
      Actor.reply(reply, count)
      Actor.continue(count)
  end
end

def zero() -> Int = 0

def total(address: Address[Msg]) -> Result[Int] = Actor.call(address, 1000) do |reply| Msg.Get(reply) end

def main() -> Void
  actor = Actor.start(Actor.Behaviour(init: &zero, handle: &handle))
  for n in 1..4
    _ = Actor.cast(actor.address, Msg.Add(n))
  end

  puts(total(actor.address))
  puts(Actor.stop(actor, 1000))
  puts(total(actor.address))
end
```

```output
ok(10)
ok()
error("address: gone", kind: "channel.gone")
```

## Actor.send and Actor.await {#actorsend-and-actorawait}

```signature
Actor.send(address: Address[M], make: Fn[Channel[R], M], timeout_ms: Int = 5000) -> Result[Actor.Request[R]]
Actor.await(request: Actor.Request[R], timeout_ms: Int) -> Result[R]
```

Las dos mitades de `call`, para solicitudes a varios actores a la vez: primero `send` a cada solicitud, y luego `await` a las respuestas en orden, así las esperas se solapan. `send` crea un canal de respuesta, construye el mensaje alrededor de él con el bloque, espera como máximo `timeout_ms` a que haya sitio en el buzón y da un `Actor.Request[R]`; sus errores son los de `cast`. `await` espera como máximo `timeout_ms` la respuesta y mantiene las garantías de `call`: un await que se rinde cierra el canal de respuesta, así que un `reply` posterior da `false`, y una respuesta que llegó justo antes se devuelve. Una solicitud tiene una sola respuesta: un segundo `await` da `actor: timeout` de inmediato. `call(address, timeout_ms) do ... end` es un `send` y un `await` dentro de un solo `timeout_ms`. `send` recibe `make` antes que `timeout_ms`, así que con la forma de bloque pasa el tiempo de espera por nombre: `Actor.send(address, timeout_ms: 100) do |reply| Msg.Get(reply) end`.

```agentica
import Actor from "std/actor"

enum Msg
  Work(Int, Channel[Int])
end

def handle(state: Int, msg: Msg) -> Actor.Step[Int]
  case msg
    Msg.Work(n, reply) ->
      Task.sleep(300)
      Actor.reply(reply, n * 10)
      Actor.continue(state)
  end
end

def main() -> Void
  behaviour: Actor.Behaviour[Int, Msg] = Actor.Behaviour(init: -> { 0 }, handle: &handle)
  shards = [Actor.start(behaviour), Actor.start(behaviour)]
  started = Time.monotonic_ms
  first = Actor.send(shards[0].address) do |reply| Msg.Work(1, reply) end
  second = Actor.send(shards[1].address) do |reply| Msg.Work(2, reply) end
  puts(Actor.await(first.unwrap!, 1000))
  puts(Actor.await(second.unwrap!, 1000))
  # Two calls one by one take at least 600 ms.
  puts(Time.monotonic_ms - started < 600)
  for shard in shards
    _ = Actor.stop(shard, 1000)
  end
end
```

```output
ok(10)
ok(20)
true
```

## Actor.stop {#actorstop}

```signature
Actor.stop(actor: Actor.Ref[S, M], timeout_ms: Int) -> Result[Void]
```

Cierra el buzón y espera como máximo `timeout_ms` a que el actor termine: atiende los mensajes que ya están en su buzón (así una llamada que espera allí recibe su respuesta), ejecuta `terminate` y termina. Un `cast`, `call` o `send` después del cierre da `error("address: gone")`. Un actor que sigue en marcha pasado `timeout_ms` se cancela, y `stop` da `actor: timeout` (clase `task.timeout`). Un actor que falló da su error `task crashed: ...`, y detenerlo observa el fallo. Detener un actor que ya terminó da cómo terminó. `timeout_ms` debe ser mayor que 0; si no, `RUNTIME-INVALID-DURATION`.

Solo quien tiene el `Ref` puede detener el actor. Para detenerlo a través de una dirección, da al enum de mensajes una variante `Stop` cuyo handler dé `Actor.done(state)`.

## Names and addresses {#names-and-addresses}

Un módulo guarda las direcciones de sus actores en una tabla `ATS` constante y envuelve los mensajes en sus propias funciones, así que quien llama nunca ve el enum. Quien busca el nombre en cada llamada llega al actor que tiene ese nombre en ese momento.

```agentica
import Actor from "std/actor"

module Counter
  def start(name: String, initial: Int) -> Result[Void]
    actor = Actor.start(Actor.Behaviour(init: -> { initial }, handle: &handle))
    return ok() if NAMES.put_new(name, actor.address)

    _ = Actor.stop(actor, 1000)
    error("counter: #{name} is taken")
  end

  def add(name: String, n: Int) -> Result[Void]
    address = try NAMES.get(name)
    Actor.cast(address, Msg.Add(n))
  end

  def get(name: String) -> Result[Int]
    address = try NAMES.get(name)
    Actor.call(address, 1000) do |reply| Msg.Get(reply) end
  end

  def stop(name: String) -> Result[Void]
    address = try NAMES.get(name)
    NAMES.delete(name)
    Actor.cast(address, Msg.Stop)
  end

  private

  NAMES: ATS[String, Address[Msg]] = ATS.new()

  enum Msg
    Add(Int)
    Get(Channel[Int])
    Stop
  end

  def handle(count: Int, msg: Msg) -> Actor.Step[Int]
    case msg
      Msg.Add(n) -> Actor.continue(count + n)
      Msg.Get(reply) ->
        Actor.reply(reply, count)
        Actor.continue(count)
      Msg.Stop -> Actor.done(count)
    end
  end
end

def main() -> Void
  _ = Counter.start("visits", 100)
  puts(Counter.start("visits", 0))
  _ = Counter.add("visits", 5)
  puts(Counter.get("visits"))
  puts(Counter.stop("visits"))
  puts(Counter.get("visits").ok?)
end
```

```output
error("counter: visits is taken")
ok(105)
ok()
false
```

## Actor.Timeout {#actortimeout}

```signature
Actor.Timeout(after_ms: Fn[S, Optional[Int]], handle: Fn[S, Actor.Step[S]])
```

Un tiempo de espera de recepción despierta al actor cuando no llegó ningún mensaje a tiempo, sin ninguna tarea temporizadora. Después de `init` y después de cada mensaje (o tiempo de espera), el actor llama a `after_ms` con su estado: `some(ms)` espera como máximo ese tiempo al siguiente mensaje, y `none` espera sin límite. Si no llega ningún mensaje en ese tiempo, `handle` se ejecuta con el estado, en lugar de un mensaje, y da el siguiente paso igual que un handler de mensajes. Un mensaje vuelve a empezar la espera, como lo hace `receive ... after` en Erlang. Para un plazo que los mensajes no deben alargar, guarda el plazo en el estado y da lo que le queda: `some(deadline - Time.monotonic_ms)`, y hazlo también en el handler de mensajes cuando ya ha pasado. Una espera de 0 o menos toma solo un mensaje que ya está en el buzón, como `after 0` de Erlang: si no hay ninguno, `handle` se ejecuta de inmediato. Así, un plazo que pasó mientras se atendía un mensaje ejecuta el tiempo de espera a continuación. Un `after_ms` que siempre da 0 o menos mantiene ocupado al actor, igual que un bucle que nunca espera. Una detención o un fallo con una espera pendiente no deja nada, y un actor que un [supervisor](/library/concurrency/supervisor/) vuelve a iniciar espera desde su nuevo `init`.

```agentica
import Actor from "std/actor"

enum Msg
  Get(Channel[Int])
end

def handle(ticks: Int, msg: Msg) -> Actor.Step[Int]
  case msg
    Msg.Get(reply) ->
      Actor.reply(reply, ticks)
      Actor.continue(ticks)
  end
end

# Three ticks, 10 ms apart when no message comes, then no more.
def after_ms(ticks: Int) -> Optional[Int]
  return none if ticks == 3

  some(10)
end

def tick(ticks: Int) -> Actor.Step[Int] = Actor.continue(ticks + 1)

def main() -> Void
  timeout = Actor.Timeout(after_ms: &after_ms, handle: &tick)
  actor = Actor.start(Actor.Behaviour(init: -> { 0 }, handle: &handle, timeout: some(timeout)))
  Task.sleep(100)
  puts(Actor.call(actor.address, 1000) do |reply| Msg.Get(reply) end)
  puts(Actor.stop(actor, 1000))
end
```

```output
ok(3)
ok()
```

## Monitors and timers {#monitors-and-timers}

No hay `select`: todo lo que un actor espera llega como una variante de su enum de mensajes. `Task.monitor(task, actor.inbox) do |down| Msg.Down(down) end` envía un aviso al buzón cuando la tarea termina; un aviso que encuentra el buzón lleno entra igual, por encima de su capacidad. Para despertar cuando no llegó ningún mensaje, da al comportamiento un [`Actor.Timeout`](#actortimeout); un temporizador que envía un mensaje propio es una tarea que duerme y luego lo envía a la dirección.

```agentica
import Actor from "std/actor"

enum Msg
  Down(TaskDown)
  Tick
  Seen(Channel[Int])
end

def handle(seen: Int, msg: Msg) -> Actor.Step[Int]
  case msg
    Msg.Down(_) -> Actor.continue(seen + 1)
    Msg.Tick -> Actor.continue(seen + 10)
    Msg.Seen(reply) ->
      Actor.reply(reply, seen)
      Actor.continue(seen)
  end
end

def zero() -> Int = 0

def tick(address: Address[Msg]) -> Result[Void]
  Task.sleep(10)
  Actor.cast(address, Msg.Tick)
end

# The notice and the tick come from tasks of their own: ask until both are in.
def seen(address: Address[Msg]) -> Result[Int]
  for _ in 1..100
    count: Int = try Actor.call(address, 1000) do |reply| Msg.Seen(reply) end
    return ok(count) if count == 11

    Task.sleep(10)
  end

  error("not seen")
end

def main() -> Void
  actor = Actor.start(Actor.Behaviour(init: &zero, handle: &handle))
  worker = Task.spawn do 42 end
  Task.monitor(worker, actor.inbox) do |down| Msg.Down(down) end
  timer = Task.spawn(&tick, actor.address)
  _ = Task.await(worker)
  _ = Task.await(timer)
  puts(seen(actor.address))
  puts(Actor.stop(actor, 1000))
end
```

```output
ok(11)
ok()
```
