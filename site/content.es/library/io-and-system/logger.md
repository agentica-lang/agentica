---
title: Logger
weight: 6
description: Niveles, manejadores con nombre y líneas de texto o JSON en el error estándar con std/logger.
source_hash: "185737e01ac1"
---

`std/logger` es un logger al estilo de Elixir escrito en Agentica. Impórtalo con `import Logger from "std/logger"`.

La primera llamada a cualquier función de `Logger` añade un manejador llamado `console`. Escribe líneas de texto en el error estándar con el nivel `info`. Un programa que solo registra no necesita configuración.

## Levels {#levels}

```signature
Logger.debug(message: String, fields: Map[String, String] = {}) -> Void
Logger.info(message: String, fields: Map[String, String] = {}) -> Void
Logger.warning(message: String, fields: Map[String, String] = {}) -> Void
Logger.err(message: String, fields: Map[String, String] = {}) -> Void
Logger.log(level: Logger.Level, message: String, fields: Map[String, String] = {}) -> Void
Logger.level() -> Logger.Level
Logger.set_level(level: Logger.Level) -> Void
Logger.enabled?(level: Logger.Level) -> Bool
```

- Los niveles son el enum `Logger.Level`: `Logger.Level.Debug < Logger.Level.Info < Logger.Level.Warning < Logger.Level.Error`.
- La función del último nivel es `err`, porque `error` está reservado. La salida sigue diciendo `error`.
- `fields` es opcional y su predeterminado es `{}`. Así, `Logger.info("started")` y `Logger.info("request done", {"path": "/items"})` son ambas llamadas válidas.
- El nivel global empieza en `info`, y `set_level` lo cambia. Cada llamada lo comprueba antes, y una llamada por debajo de él no crea ningún evento.
- Cada manejador tiene su propio nivel y solo recibe los eventos en ese nivel o por encima.
- `enabled?` es verdadero solo cuando el nivel es igual o superior al nivel global y algún manejador lo acepta. Pon un mensaje costoso dentro de un `if` sobre `enabled?`.

En el ejemplo, el manejador console está en `info`. Así, `enabled?` es falso para `debug` hasta que se añada un manejador en `debug`.

```agentica
import Logger from "std/logger"

def count_lines() -> Int = 3

def main() -> Void
  Logger.set_level(Logger.Level.Debug)
  puts(Logger.enabled?(Logger.Level.Debug))
  _ = Logger.attach("trace", Logger.Level.Debug, &Logger.stderr_text)
  puts(Logger.enabled?(Logger.Level.Debug))
  if Logger.enabled?(Logger.Level.Debug)
    Logger.debug("lines", {"count": count_lines().to_s})
  end

  Logger.set_level(Logger.Level.Info)
  puts(Logger.enabled?(Logger.Level.Debug))
end
```

```output
false
true
false
```

## Handlers {#handlers}

```signature
Logger.attach(name: String, level: Logger.Level, handler: Fn[Logger.Event, Void]) -> Result[Void]
Logger.detach(name: String) -> Result[Void]
Logger.handlers() -> List[String]
```

Un manejador es una función (como `&Logger.stderr_json`) o un bloque. Recibe un `Logger.Event`, con estos campos:

- `level: Logger.Level`
- `message: String`
- `fields: Map[String, String]`
- `time_ms: Int`: cuándo se creó el evento
- `task: Int`: la tarea que registró el evento. `main` es 1

`attach` con un nombre ya en uso, y `detach` con un nombre que no está en uso, devuelven un error.

- Los manejadores se ejecutan en el orden en que se añadieron, de forma síncrona, en la tarea que registra. Así, una línea se escribe cuando la llamada de log devuelve el control.
- Un evento conserva los manejadores con los que empezó. Un manejador que quita a otro no cambia el evento en curso.
- Un manejador sigue añadido cuando termina la tarea que lo añadió.
- El error de un manejador es el error de la tarea que registró el evento.

```agentica
import Logger from "std/logger"

def main() -> Void
  _ = Logger.detach("console")
  _ = Logger.attach("audit", Logger.Level.Warning) do |event| puts("audit: #{event.message}") end

  Logger.info("not for the audit handler")
  Logger.err("cannot open the cache")
  puts(Logger.attach("audit", Logger.Level.Info, &Logger.stderr_text).message)
  puts(Logger.handlers())
end
```

```output
audit: cannot open the cache
a handler named "audit" is already attached
["audit"]
```

## Formats {#formats}

```signature
Logger.stderr_text(event: Logger.Event) -> Void
Logger.stderr_json(event: Logger.Event) -> Void
Logger.format_text(event: Logger.Event) -> String
Logger.format_json(event: Logger.Event) -> String
Logger.time_text(time_ms: Int) -> String
```

`stderr_text` y `stderr_json` son los manejadores integrados. Cada uno escribe una línea con una sola llamada a `IO.warn`. `format_text` y `format_json` crean la línea sin escribirla, para tu propio manejador.

- Texto: `TIME LEVEL MESSAGE key=value ...`, con la hora en UTC y el nivel en mayúsculas.
- Un mensaje, una clave o un valor se escribe como cadena JSON cuando está vacío, o cuando tiene `=`, una comilla, una barra invertida o un carácter de control. Una clave o un valor con un espacio también se escribe como cadena JSON. Así, una línea siempre ocupa una sola línea, y un valor nunca parece un campo.
- JSON: un objeto por línea, con las claves `time`, `level` (`debug`, `info`, `warning` o `error`), `msg`, `fields` y `task`. Los campos van anidados, así que un campo llamado `level` nunca choca con una clave fija.
- `time_text` convierte los milisegundos desde la época Unix en un texto como `2026-10-12T10:15:02.345000Z`, el [`iso8601`](/library/io-and-system/time/#iso8601) del `Time.DateTime` con desfase 0, con seis dígitos de fracción. Un instante fuera de los años 1 a 9999 detiene el programa con `RUNTIME-UNWRAP-ERROR` (`time_ms X is outside the years 1 to 9999`); la hora de un evento viene de `Time.now_ms()`, que está dentro del rango.

```agentica
import Logger from "std/logger"

def main() -> Void
  event = Logger.Event(
    level: Logger.Level.Info,
    message: "request done",
    fields: {"path": "/items", "status": "200"},
    time_ms: 1760523302345,
    task: 1,
  )

  puts(Logger.format_text(event))
  puts(Logger.format_json(event))
  odd = Logger.Event(level: Logger.Level.Error, message: "a=b", fields: {"note": "two words"}, time_ms: 0, task: 2)
  puts(Logger.format_text(odd))
end
```

```output
2025-10-15T10:15:02.345000Z INFO request done path=/items status=200
{"time":"2025-10-15T10:15:02.345000Z","level":"info","msg":"request done","fields":{"path":"/items","status":"200"},"task":1}
1970-01-01T00:00:00.000000Z ERROR "a=b" note="two words"
```

## Salida a archivo y manejadores lentos {#file-output-and-slow-handlers}

No hay un manejador de archivo integrado. Un bloque que añade una línea por evento hace el trabajo. El `_ =` descarta un error de escritura:

```agentica {mode="check"}
import Logger from "std/logger"

def main() -> Void
  _ = Logger.attach("file", Logger.Level.Info) do |event|
    _ = File.append_text("app.log", Logger.format_json(event) + "\n", 1000)
  end

  Logger.info("server started")
end
```

Un manejador lento puede pasar cada evento a una tarea por un `Channel`. El escritor se lanza con `Task.spawn_owning`, así que es propietario del canal. La ejecución termina en este orden: quitar el manejador, cerrar el canal y esperar al escritor. Sin la espera, al volver de `main` la ejecución termina y las líneas en cola se pierden.

```agentica {mode="check"}
import Logger from "std/logger"

def write_events(events: Channel[Logger.Event]) -> Result[Void]
  while true
    case events.recv(1000)
      ok(event) -> try File.append_text("app.log", Logger.format_json(event) + "\n", 1000)
      error(_) -> break if events.closed? and events.empty?
    end
  end

  ok()
end

def main() -> Void
  events: Channel[Logger.Event] = Channel.new(64)
  writer = Task.spawn_owning(&write_events, events)
  _ = Logger.attach("file", Logger.Level.Info) do |event| _ = events.send(event, 1000) end

  Logger.info("server started")
  _ = Logger.detach("file")
  events.close
  done = Task.await(writer)
  if !done.ok?
    IO.warn(done.message)
  end
end
```

## Rules {#rules}

- `Logger.Level` y `Logger.Event` son los tipos integrados `LogRegistry.Level` y `LogRegistry.Event`, que `std/logger` reexporta, así que `import {Event, Level} from "std/logger"` los vincula por su nombre. Un diagnóstico, `help` y un valor impreso muestran `Logger.Level` y `Logger.Event`: `"#{level}"` es `Logger.Level.Info`, y un evento se imprime como `Logger.Event(level: ..., message: ...)`. No reservan ningún nombre: un programa puede declarar su propio `Event` o `LogEvent`.
- Los manejadores y el nivel global viven en la VM y pertenecen a una sola ejecución. Un proceso hijo iniciado con `Process.spawn` tiene los suyos. Este registro es el único estado global del lenguaje; `std/logger` llega a él a través del módulo interno `LogRegistry`, que ningún otro módulo puede nombrar (`CHECK-UNKNOWN-NAME`).
- No previsto para `std/logger`: archivos de log y rotación, syslog, muestreo, niveles por módulo, valores de campo `JSON.Value`, configuración por variables de entorno, ni argumentos de log perezosos (un bloque que se pasa a `attach` es un manejador, no un mensaje perezoso). No previsto para el rastreo: una traza a nivel de lenguaje, líneas de traza en la salida estándar, contadores dentro del rastreador, un flag para desactivar las trazas de pila, ni una pila de la tarea padre en el momento de lanzarla; el trazado de la VM es una herramienta de desarrollo de la VM, no una característica del lenguaje.
- No hay flags ni metadatos por tarea. Pasa `fields` en cada llamada, como segundo argumento opcional.
- Las llamadas de log son código normal, y cuentan contra `--max-steps`.
- Una llamada por debajo del nivel global, o una que ningún manejador acepta, cuesta una llamada a función, una llamada a un integrado y una comparación. Una llamada sin `fields` también pasa un mapa vacío.
