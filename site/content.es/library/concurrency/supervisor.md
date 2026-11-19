---
title: Supervisor (std)
weight: 6
description: El módulo std/supervisor, una tarea que inicia actores y reinicia solo el que falla (one for one), dentro de un límite de reinicios.
source_hash: "9b8aa0dfe9f1"
---

`std/supervisor` está escrito en Agentica, sobre [Actor](/library/concurrency/actor/): `import Supervisor from "std/supervisor"`. Un supervisor es una tarea que inicia actores, sus hijos, y vuelve a iniciar un hijo que falla; los otros hijos siguen ejecutándose (one for one).

- Un hijo es un actor con un nombre y un bloque de registro. El supervisor ejecuta el bloque con la dirección de cada actor nuevo, así que un módulo la pone en su tabla de nombres. Después de un reinicio el actor tiene un buzón nuevo, y por tanto una dirección nueva: quien busca el nombre en cada llamada llega al actor nuevo, y quien conservó la dirección vieja recibe `error("address: gone")`.
- Solo un fallo vuelve a iniciar un hijo. Un hijo que termina sin fallo (su handler devolvió `Actor.done`) se queda parado.
- Una llamada que espera cuando su actor falla termina con su tiempo de espera, y los mensajes del buzón viejo se pierden.
- El supervisor es hijo de la tarea que llama a `Supervisor.start`: un fallo o una cancelación de esa tarea cancela el supervisor y sus actores. Inícialo desde `main`.

## Supervisor.child {#supervisorchild}

```signature
Supervisor.child(name: String, behaviour: Actor.Behaviour[S, M], register: Fn[Address[M], Void]) -> Supervisor.Child
```

Un hijo que ejecuta `behaviour` (ver [Actor](/library/concurrency/actor/)) y llama a `register` con la dirección de cada actor nuevo. El bloque se ejecuta en una tarea propia, antes de que el supervisor siga, durante 5 segundos como máximo: un bloque que falla, o que todavía sigue en marcha entonces (se cancela), es un inicio fallido. El bloque es obligatorio: un hijo al que nadie alcanza por nombre usa `do |_address| nil end`. Una `List[Supervisor.Child]` guarda hijos de cualquier tipo de estado y de mensaje.

## Supervisor.start {#supervisorstart}

```signature
Supervisor.start(children: List[Supervisor.Child], options: Supervisor.Options = Supervisor.Options()) -> Supervisor.Ref
Supervisor.Options(max_restarts: Int = 3, within_ms: Int = 5000)
```

Inicia el supervisor en una tarea propia, que inicia los hijos en el orden de la lista, y devuelve cuando ha terminado el primer inicio de cada uno, o pasados 60 segundos. Un inicio falla cuando el `init` del actor falla o cuando el bloque de registro falla; un inicio fallido cuenta como un fallo de ese hijo, y el supervisor lo intenta de nuevo dentro del límite, después de haber leído los mensajes que llegaron antes (así, un `Supervisor.stop` no se retrasa por un hijo que sigue fallando). `max_restarts` debe ser 0 o más y `within_ms` mayor que 0; si no, `start` se detiene con `RUNTIME-UNWRAP-ERROR` (`supervisor: within_ms must be above 0, not 0`).

El límite es por hijo: un hijo que falla más de `max_restarts` veces dentro de `within_ms` milisegundos, o que no arranca más de `max_restarts` veces seguidas (sea cual sea el tiempo entre ellas; un inicio que tiene éxito cierra la serie), hace que el supervisor se rinda. Detiene los otros hijos en orden inverso, en 5 segundos como máximo, y luego falla, así que una rendición nunca es silenciosa: su diagnóstico es `RUNTIME-UNWRAP-ERROR` con el mensaje `supervisor: NAME crashed N times in M ms` (`1 time` cuando es una vez) o `supervisor: NAME failed to start N times in a row`; un `Task.monitor` de `sup.task` ve `TaskExit.Crashed` con ese código y mensaje, y una rendición que nadie observa (`Supervisor.stop`, `Task.await(sup.task)` o un monitor) hace fallar la ejecución cuando `main` devuelve.

## Supervisor.stop {#supervisorstop}

```signature
Supervisor.stop(supervisor: Supervisor.Ref, timeout_ms: Int) -> Result[Void]
```

Detiene los hijos en orden inverso, cada uno como lo hace `Actor.stop` (atiende su buzón y ejecuta `terminate`), y luego el supervisor, todo dentro de `timeout_ms`, que debe ser mayor que 0, y da el primer error de la detención de un hijo (`task crashed: ...` para un hijo que falló en `terminate` o mientras atendía los mensajes que quedaron en su buzón). Los hijos comparten el tiempo por turnos: cuando uno ha gastado el suyo, cada hijo que queda recibe 1 ms, así que normalmente se cancela sin `terminate`. Un supervisor que sigue en marcha al final se cancela con sus hijos, y `stop` da `error("supervisor: timeout")`; un supervisor ocupado con un inicio espera a que termine (cada inicio dura como máximo unos 6 segundos: los 5 de su bloque de registro, y hasta 1 más para detener el actor de un inicio fallido). Un supervisor que se rindió da su motivo (`error("supervisor: NAME crashed N times in M ms")`), y detenerlo observa el fallo.

```agentica
import Actor from "std/actor"
import Supervisor from "std/supervisor"

NAMES: ATS[String, Address[Msg]] = ATS.new()

enum Msg
  Add(Int)
  Get(Channel[Int])
  Divide(Int)
end

def handle(count: Int, msg: Msg) -> Actor.Step[Int]
  case msg
    Msg.Add(n) -> Actor.continue(count + n)
    Msg.Get(reply) ->
      Actor.reply(reply, count)
      Actor.continue(count)
    Msg.Divide(n) -> Actor.continue(count / n)
  end
end

def zero() -> Int = 0

def counter(name: String) -> Supervisor.Child
  behaviour: Actor.Behaviour[Int, Msg] = Actor.Behaviour(init: &zero, handle: &handle)
  Supervisor.child(name, behaviour) do |address| NAMES.put(name, address) end
end

def get(name: String) -> Result[Int]
  address = try NAMES.get(name)
  Actor.call(address, 1000) do |reply| Msg.Get(reply) end
end

# The restart comes from the supervisor's task: wait until the name holds a new address.
def restarted(name: String, old: Address[Msg]) -> Result[Int]
  for _ in 1..100
    address = try NAMES.get(name)
    return get(name) if address != old

    Task.sleep(10)
  end

  error("#{name} was not restarted")
end

def main() -> Void
  sup = Supervisor.start([counter("visits"), counter("errors")])
  visits = NAMES.get("visits").unwrap!
  _ = Actor.cast(visits, Msg.Add(5))
  puts(get("visits"))
  _ = Actor.cast(visits, Msg.Divide(0))
  puts(restarted("visits", visits))
  puts(Actor.cast(visits, Msg.Add(1)))
  puts(Supervisor.stop(sup, 1000))
end
```

```output
ok(5)
ok(0)
error("address: gone", kind: "channel.gone")
ok()
```

El fallo de `visits` imprime su diagnóstico `RUNTIME-DIVISION-BY-ZERO` en stderr; el supervisor lo observa, así que la ejecución termina con código de salida 0.
