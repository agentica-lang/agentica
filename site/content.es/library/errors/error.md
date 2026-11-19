---
title: Error
weight: 2
description: El registro que guarda un Result fallido.
source_hash: "552f91e87084"
---

Un `Result` fallido guarda un `Error`, un registro integrado. `error("text")` construye uno, `error("text", kind: "db.constraint", code: 19)` fija más de sus campos, y el patrón `error(e)` lo vincula.

```text
struct Error
  kind: String = "error"
  message: String
  code: Optional[Int] = none
  details: Map[String, String] = {}
  cause: Optional[Error] = none
  location: String = ""
end
```

- `kind` es un nombre con puntos para la clase de fallo; `error("text")` da `"error"`, y los integrados dan las clases de [Clases integradas](#builtin-kinds).
- `message` es el texto para las personas.
- `code` es un número, como un errno, un estado HTTP o un código de respuesta, o `none`.
- `details` guarda datos extra como texto, `{}` cuando no hay ninguno.
- `cause` es el error que llevó a este, o `none`.
- `location` es el lugar donde se creó el error, como `path:line:col`.

Lee los campos como en cualquier registro, y cambia uno con `with`. Solo `error(...)` construye un `Error`: `Error(...)` es `CHECK-ERROR-CONSTRUCTOR`. Un programa no puede declarar un tipo propio llamado `Error` (`CHECK-REDEFINED-NAME`).

```agentica
def parse(text: String) -> Result[Int]
  return error("empty input") if text == ""

  ok(text.length)
end

def main() -> Void
  case parse("")
    ok(n) -> puts(n)
    error(e) ->
      puts(e.message)
      puts(e.kind)
      puts(e.location)
  end
end
```

```output
empty input
error
main.agc:2:10
```

## Clases {#kinds}

`error(message, kind:, code:, details:, cause:)` toma los demás campos como argumentos con nombre después del mensaje, cada uno opcional y en cualquier orden. `code:` toma un `Int` y `cause:` un `Error`, que la llamada guarda como `some(...)`; `location` nunca se da. `Result.Err(...)` toma los mismos argumentos.

Una clase es un nombre con puntos: partes de `a-z`, `0-9` y `_`, cada una empieza con una letra (`db`, `db.constraint`, `io.not_found`). Un literal de texto dado como `kind:` (de `error(...)` o `Result.Err(...)`) o a `is_a?` / `kind_of?` que no cumple eso es `CHECK-ERROR-KIND`. Nada más se comprueba: una clase calculada en tiempo de ejecución y una clase fijada con `e.with(kind: ...)` se mantienen tal cual. [`agentica lint`](/cli/#suggest-style-changes) marca un literal de `is_a?` de una familia integrada que no es ninguna de las clases de abajo, como `e.is_a?("io.notfound")` (`LINT-ERROR-KIND`): se marca una clase de una familia integrada que el archivo no crea con `kind:`. Quien llama decide según la clase o el código, nunca según el texto del mensaje.

## Clases integradas {#builtin-kinds}

Los errores de los integrados tienen estas clases. Una clase nunca se renombra, así que un programa puede decidir según ella. Solo los casos de la fila `error` tienen la clase `error`, así que `e.kind == "error"` y `e.is_a?("error")` no coinciden con ninguno de los demás: decide según `e.kind` o `e.is_a?`, nunca según el mensaje. `argument` es un valor de argumento malo: fuera de rango, vacío, demasiado grande o con NUL.

| Familia | Clases |
|---|---|
| `error` | la clase predeterminada: `error("text")`, `o.to_result(...)`, `List.find` y `Lazy.find` sin coincidencia, una clave que falta en una tabla `Ats`, un nombre de handler de logger que ya está en uso o que falta, `Task.unobserved_crash` con none y el `an_error` de un módulo nativo |
| `argument` | `argument` |
| `io` | `io.not_found`, `io.permission`, `io.exists`, `io.is_directory`, `io.not_directory`, `io.too_large`, `io.eof`, `io.closed`, `io.timeout`, `io.failed` |
| `net` | `net.timeout`, `net.refused`, `net.host_not_found`, `net.closed`, `net.eof`, `net.tls`, `net.too_large`, `net.failed` |
| `http` | `http.protocol`, `http.too_large`, `http.closed` |
| `process` | `process.not_found`, `process.timeout`, `process.closed`, `process.eof`, `process.too_large`, `process.failed` |
| `task`, `channel` | `task.crashed`, `task.cancelled`, `task.timeout`, `channel.closed`, `channel.timeout`, `channel.gone` |
| `json`, `number`, `text` | `json.parse`, `json.decode`, `number.parse`, `number.range`, `text.encoding` |
| `zlib`, `crypto` | `zlib.data`, `zlib.too_large`, `crypto.auth`, `crypto.key`, `crypto.failed` |
| `system`, `native`, `test` | `system.env`, `system.signal`, `native.failed`, `native.timeout`, `test.failed` |
| `denied` | `denied.env`, `denied.fs`, `denied.net`, `denied.run`: una llamada que un flag rechaza, una clase por flag (ver abajo) |

Las llamadas que apaga un flag `--deny-*` devuelven un error de la familia `denied`: `denied.env` para `--deny-env` (`System.env`), `denied.fs` para `--deny-fs` (llamadas de `File`, `Dir` y `Path` que tocan el disco, un contexto `TLS` creado desde archivos, `Process.spawn` con archivos `out:` o `err:`), `denied.net` para `--deny-net` (`TCP`, `TLS`, `HttpWire`, `DNS` y `std/http`) y `denied.run` para `--deny-run` (`Process`, `System.signal`). `--sandbox` equivale a todos estos flags, así que cada llamada recibe la clase de su propio flag, y `e.is_a?("denied")` coincide con todos ellos. El mensaje conserva su texto (`denied: --deny-fs turns off file access`). Un programa que usa código nativo con `--deny-native` (que activa cada flag `--deny-*`) no se ejecuta: se detiene al empezar con `RUNTIME-NATIVE-DENIED`, así que no hay error según el cual decidir.

Un error del sistema operativo (`File`, `Dir`, `TCP`, `TLS`, `Process`) tiene el errno como `code` y una clase elegida a partir de él: `ENOENT` es `io.not_found` (`process.not_found` para un programa), `EACCES` y `EPERM` son `io.permission`, `ECONNREFUSED` es `net.refused`, `ECONNRESET` y `EPIPE` son `net.closed`. Un errno sin clase propia recibe la clase `failed` de su familia, y el errno sigue como código. El número es el del sistema, así que `ECONNREFUSED` es 111 en Linux, 61 en macOS y 107 en Windows; la clase es la misma en todas partes. Un host que no se encuentra no tiene código. Una cabecera HTTP rechazada tiene su estado como código (`400`, `413`, ...). Cada límite de tamaño de HTTP (una cabecera, una línea de cabecera, la cantidad de cabeceras, un cuerpo o una línea de trozo, leídos o escritos) es `http.too_large`, con el código `431` para una cabecera y `413` para un cuerpo; una cabecera de respuesta que el servidor de `std/http` no puede escribir no tiene código.

Los `details` de un error de una llamada a archivo, rechazada por `--deny-fs` o fallida, guardan la ruta tal como se dio a la llamada bajo `"path"`: `File.read_text("conf/app.toml", 5000)` sin ese archivo da `{"path": "conf/app.toml"}`. `Path.rename` y `Path.replace` también guardan su destino bajo `"to"`. Un error de una llamada de red que nombra un host (`TCP.connect`, `TCP.listen`, `TLS.connect`, `DNS.lookup`) guarda el host bajo `"host"`: una conexión rechazada, un host que no se encuentra, un handshake TLS fallido y un rechazo de `--deny-net`. Las llamadas sobre un handle abierto (`File.write`, `TCP.send`, ...) no tienen detalles.

```agentica
def main() -> Void
  case File.read_text("missing.txt", 1000)
    ok(text) -> puts(text)
    error(e) if e.is_a?("io.not_found") -> puts("no file, code #{e.code}")
    error(e) -> puts(e.message)
  end
end
```

```output
no file, code some(2)
```

## Clases de std/ {#kinds-of-std}

Los módulos `std/` dan estas clases. Una función de `std/` que pasa el error de un integrado conserva su clase y su código, y pone su propio texto delante del mensaje, así que `Archive.extract_tar` de un archivo que falta es `io.not_found` con el código 2. `Regex.match` sin coincidencia conserva `error`, como hace `List.find`.

| Módulo | Clases |
|---|---|
| `std/http` | `http.protocol` (una cabecera rechazada tiene su estado como código; también el 407 de un proxy), `http.too_large`, `http.closed`, `http.digest` (`download` con un `sha256` que el cuerpo no tiene), `net.timeout` (el de connect tiene `details["phase"]` `"connect"`), `channel.timeout` (`open` y `upload`, un trozo que no se toma o no se entrega a tiempo), `net.eof`, `net.failed`, `text.encoding` (`HTTP.text`), `argument` |
| `std/archive` | `archive.format` (datos truncados o no válidos), `archive.unsafe` (una ruta de entrada que no es una ruta relativa segura, o que sale del destino), `archive.too_large`, `archive.timeout`, `archive.not_found` (un miembro que el archivo no tiene), `argument` (una opción o un nombre de miembro fuera de rango o no seguro) |
| `std/toml` | `toml.parse` (`parse`), `toml.decode` (`get` y `to_json`), `argument` (`encode`) |
| `std/regex` | `regex.syntax` (un patrón o una plantilla de `replace`), `argument` (`named` sin ese grupo) |
| `std/option_parser` | `option_parser.parse` (un error en las palabras), `option_parser.help` (`--help`), `argument` (una especificación mala) |
| `std/actor`, `std/supervisor` | `channel.timeout`, `channel.gone` (el actor ha terminado), `task.timeout` (`stop`) |
| `std/heap` | `heap.empty` (`pop` y `peek` de un heap vacío) |
| `std/binary` | `binary.too_large` (una longitud de frame mayor que `max`), `number.range`, `argument` |
| `std/uri`, `std/cookie` | `text.encoding`, `argument` |
| `std/bdd` | `process.eof`, `process.timeout` (`read_line`), `process.failed`, `io.exists`, `json.decode`, `argument` |

## is_a? {#is_a}

```signature
error.is_a?(family: String) -> Bool
```

Verdadero cuando la clase es `family` o empieza con `family` y un punto, así que `e.is_a?("db")` acepta `db` y `db.constraint`, pero no `dbx`: la familia hace el papel de una clase de excepción y de sus subclases. `kind_of?` es el mismo método.

```agentica
def insert(name: String) -> Result[Int]
  return error("unique failed", kind: "db.constraint", code: 19) if name == "taken"

  ok(name.length)
end

def main() -> Void
  case insert("taken")
    ok(id) -> puts(id)
    error(e) if e.is_a?("db.constraint") -> puts("duplicate, code #{e.code}")
    error(e) if e.is_a?("db") -> puts("database: #{e.message}")
    error(e) -> puts(e.message)
  end
end
```

```output
duplicate, code some(19)
```

## Ubicación {#location}

`error("text")` fija `location` al lugar de esa llamada. Un error que hace un integrado recibe el lugar de la llamada al integrado: en el programa, o en el módulo de `std/` cuya función hizo la llamada. Una función de prelude (`o.to_result(...)`) y una función de un bloque `extern module` se saltan, así que sus errores apuntan a la llamada del programa. La ruta es relativa: el nombre que el archivo compilado guarda para el código fuente, relativo a la carpeta del archivo de entrada, o `std/...` para un módulo estándar.

`location` es `""` cuando no se conoce ningún lugar: cuando la llamada está a más de 16 frames de prelude o nativos de profundidad, o cuando ninguna tarea ejecuta el código que construye el error.

`error(e)` y `e.with(...)` conservan la ubicación de `e`.

## Pasar un error {#passing-an-error-on}

`error(e)` con un `Error` da un Result fallido que guarda ese mismo `Error`, así que una rama de `case` puede pasarlo a un `Result` de otro tipo. `try` también lo pasa sin cambios.

```agentica
def count(text: String) -> Result[Int]
  return error("no digits") if text == ""

  ok(text.length)
end

def label(text: String) -> Result[String]
  case count(text)
    ok(n) -> ok("#{n} digits")
    error(e) -> error(e)
  end
end

def main() -> Void
  puts(label(""))
end
```

```output
error("no digits")
```

## Causa {#cause}

`cause` enlaza un error con el que lo causó: `error("text", cause: e)`. Un encadenamiento termina en `none`, y como los valores no pueden cambiar, no puede formar un bucle.

```agentica
def load() -> Result[Int] = error("disk gone")

def start() -> Result[Int]
  case load()
    ok(n) -> ok(n)
    error(e) -> error("cannot start", cause: e)
  end
end

def main() -> Void
  case start()
    ok(_) -> puts("started")
    error(e) ->
      current = some(e)
      while current.some?
        link = current.unwrap!
        puts(link.message)
        current = link.cause
      end
  end
end
```

```output
cannot start
disk gone
```

## Imprimir {#printing}

- `to_s`, `puts(e)` y `"#{e}"` dan el mensaje.
- `inspect` da la llamada `error(...)` que construye el valor: el mensaje, y luego `kind:`, `code:`, `details:` y `cause:` cuando no son los predeterminados. `location` nunca se imprime.
- Un `Error` suelto se imprime como un Result fallido, así que `[e]` imprime `[error("x")]`.

```agentica
def main() -> Void
  r: Result[Int] = error("timeout")
  case r
    ok(_) -> puts("ok")
    error(e) ->
      puts(e)
      puts(e.inspect)
      puts([e])
      puts("failed: #{e}")
  end
end
```

```output
timeout
error("timeout")
[error("timeout")]
failed: timeout
```

## Igualdad {#equality}

`==` compara `kind`, `message`, `code`, `details` y `cause`, y deja fuera `location`, así que `Test.eq(parse(""), error("empty input"))` se cumple aunque los dos errores se crearon en lugares distintos. Un `Result` que guarda un error compara su `Error` de la misma forma.

## JSON {#json}

Un `Error` se puede codificar en JSON, con sus seis campos; `null` para `none`. `JSON.decode(text, Error)` lee la misma forma. Un `Result` no se puede codificar (`CHECK-NOT-ENCODABLE`).

```agentica
def main() -> Void
  r: Result[Int] = error("timeout")
  case r
    ok(_) -> puts("ok")
    error(e) -> puts(JSON.encode(e.with(location: "")))
  end
end
```

```output
{"kind":"error","message":"timeout","code":null,"details":{},"cause":null,"location":""}
```
