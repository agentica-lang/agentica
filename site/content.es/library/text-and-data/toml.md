---
title: TOML (std)
weight: 5
description: El módulo std/toml, que lee y escribe documentos TOML 1.0.
source_hash: "ac6f65c59e84"
---

`std/toml` está escrito en Agentica y lee y escribe todo TOML 1.0: `import Toml from "std/toml"`. `parse` crea un `Toml.Value` (un enum recursivo), `encode` lo vuelve a escribir y `to_json` lo convierte para que `JSON.decode` pueda rellenar una estructura. Cada función devuelve un `Result` y nunca detiene el programa, sea cual sea la entrada.

```ruby
Toml.parse(text: String) -> Result[Toml.Value]
Toml.encode(value: Toml.Value) -> Result[String]
Toml.to_json(value: Toml.Value) -> Result[JSON.Value]
Toml.get(value: Toml.Value, path: String) -> Result[Toml.Value]
```

## Valores {#values}

```ruby
enum Toml.Value
  Str(String)
  Int(Int)
  Float(Float)
  Bool(Bool)
  DateTime(String)
  Array(List[Toml.Value])
  Table(Map[String, Toml.Value])
end
```

- La raíz es siempre una `Table`, un `Map` que guarda las claves en el orden en que se escribieron por primera vez.
- `Int` es un entero con signo de 64 bits (un valor mayor es un error de análisis). `Float` guarda `inf` y `nan`. Los arrays pueden mezclar tipos.
- `DateTime` guarda su texto tal como se escribió (el lenguaje no tiene tipo de fecha). Se aceptan fecha y hora con o sin desplazamiento, fechas locales (`1979-05-27`) y horas locales (`07:32:00`). Se comprueban el mes, el día (años bisiestos), la hora y el desplazamiento, pero no se convierten. Un segundo intercalar (`:60`) se acepta, y los segundos fraccionarios conservan cada dígito.

## Lectura {#reading}

`Toml.parse` acepta TOML 1.0 y nada más. Un flotante con una magnitud mayor que el mayor flotante se lee como `inf`, y uno menor que el menor como cero, igual que en el `tomllib` de Python. CRLF cuenta como un solo LF, también dentro de una cadena multilínea.

Errores: una clave duplicada, una tabla definida dos veces, añadir a una tabla en línea o a un array estático, una clave con puntos que nombra una tabla `[header]` (o al revés), `[[a]]` sobre un array estático o una tabla, caracteres de control en cadenas y comentarios, y un retorno de carro suelto.

`Toml.get(value, path)` lee una ruta con puntos (`"package.name"`). Un segmento de solo dígitos (sin signo ni cero a la izquierda) también indexa un array: `"bin.1.path"` es el segundo `[[bin]]`. Una clave que falta da un error que la nombra. Una clave que contiene un punto no se puede alcanzar así: usa `case` sobre la `Table`.

```agentica
import Toml from "std/toml"

def main() -> Void
  text = "[package]\nname = \"demo\"\nversion = \"0.1.0\"\n\n[[bin]]\npath = \"a.agc\"\n\n[[bin]]\npath = \"b.agc\"\n"
  doc = Toml.parse(text).unwrap!
  puts(Toml.get(doc, "package.name")) # a dotted path
  puts(Toml.get(doc, "bin.1.path")) # digits index an array
  puts(Toml.get(doc, "package.license")) # a missing key is an error
  puts(Toml.parse("a = 1\nb = 2\nc d\n")) # a parse error names its place
end
```

```output
ok(Toml.Value.Str("demo"))
ok(Toml.Value.Str("b.agc"))
error("no key \"license\" in \"package.license\"", kind: "toml.decode")
error("line 3, column 3: expected '=' after key", kind: "toml.parse")
```

## Errores {#errors}

Un error de análisis empieza por el lugar, por ejemplo `line 3, column 7: expected '=' after key`. Las líneas y las columnas cuentan desde 1; las columnas cuentan caracteres, no bytes. Los mensajes van en minúsculas y sin punto final.

Los arrays y las tablas en línea anidan como máximo 256 niveles, y una clave tiene como máximo 256 partes. Una entrada más profunda da un error en el corchete o en la clave, nunca detiene el programa.

## Escritura {#writing}

`Toml.encode` recibe una `Table` (cualquier otra raíz da un error) y devuelve el documento con un salto de línea final: los mismos bytes para el mismo valor.

- En cada tabla: primero las líneas simples `key = value`, luego las subtablas `[a.b]`, después los arrays de tablas `[[a.b]]`, cada grupo en el orden de `Map`. Así un escalar nunca cae dentro de una sección `[[...]]`.
- Una tabla con solo subtablas no lleva cabecera; una tabla vacía sí. Un array que no es una entrada directa de tabla, o una tabla dentro de un array mixto, se escribe en línea.
- Una clave que no es suelta (`A-Za-z0-9_-`) se pone entre comillas. Las cadenas son cadenas básicas con escapes; el texto no ASCII se queda tal cual.
- Un flotante se lee de vuelta igual, incluidos `inf`, `-inf` y `nan`. Un `DateTime` no válido da un error.
- `parse` de la salida da los mismos valores, con las claves quizá reagrupadas en el orden de arriba.
- Se aplican los límites del lector (256 partes en una ruta de tabla, 256 niveles en línea), así que la salida siempre se puede leer de vuelta. `Toml.to_json` se detiene en 2.048 niveles. Los valores profundos dan errores, nunca detienen el programa.

```agentica
import Toml from "std/toml"

def main() -> Void
  pkg: Map[String, Toml.Value] = {
    "name": Toml.Value.Str("acme/text"),
    "deps": Toml.Value.Array([Toml.Value.Str("acme/lists")]),
  }

  root: Map[String, Toml.Value] = {}
  root = root.put("package", Toml.Value.Array([Toml.Value.Table(pkg)]))
  root = root.put("version", Toml.Value.Int(1))
  text = Toml.encode(Toml.Value.Table(root)).unwrap!
  puts(text)
  puts(Toml.parse(text).ok?)
end
```

```output
version = 1

[[package]]
name = "acme/text"
deps = ["acme/lists"]

true
```

## Decodificación tipada {#typed-decoding}

`Toml.to_json` convierte un `DateTime` en su cadena y mantiene separados los enteros y los flotantes (`port = 8080.0` no se decodifica en un `Int`). `inf` y `nan` no tienen forma JSON: dan error. Después, `JSON.decode(json, Config)` rellena una estructura, y sus errores nombran la ruta del campo.

```agentica
import Toml from "std/toml"

struct Limits
  cpu: Int
end

struct Config
  name: String
  port: Int
  limits: Limits
end

def load(text: String) -> Result[Config]
  doc = try Toml.parse(text)
  json = try Toml.to_json(doc)
  JSON.decode(json, Config)
end

def main() -> Void
  config = load("name = \"web\"\nport = 8080\n\n[limits]\ncpu = 4\n").unwrap!
  puts(config.name)
  puts(config.limits.cpu)
  puts(load("name = \"web\"\nport = 8080.0\n[limits]\ncpu = 4\n").message)
end
```

```output
web
4
port: expected signed 64-bit Int
```
