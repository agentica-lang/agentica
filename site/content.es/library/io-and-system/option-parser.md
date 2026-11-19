---
title: Option parser (std)
weight: 7
description: El módulo std/option_parser, que lee la línea de comandos de un programa en valores con tipo, con predeterminados, valores permitidos, errores y un texto de ayuda.
source_hash: "82275b2b0e19"
---

`std/option_parser` está escrito en Agentica: `import OP from "std/option_parser"` e `import {Arg, Opt, Kind} from "std/option_parser"`. Tiene la forma de `argparse` de Python y los nombres de `OptionParser` de Ruby. Solo usa estructuras, enums y `Optional`: nada de JSON.Value. Describes el programa con `Arg` (un argumento posicional) y `Opt` (una opción), `parse` comprueba las palabras, y las funciones de lectura con tipo leen cada valor en tu propia estructura.

```ruby
OP.new(program: String, description: String = "", args: List[Arg] = [], opts: List[Opt] = [], rest: String = "") -> Parser
OP.parse(parser: Parser, args: List[String]) -> Result[Parsed]
OP.string(parsed: Parsed, name: String) -> String
OP.int(parsed: Parsed, name: String) -> Int
OP.float(parsed: Parsed, name: String) -> Float
OP.flag(parsed: Parsed, name: String) -> Bool
OP.optional_string(parsed: Parsed, name: String) -> Optional[String]
OP.optional_int(parsed: Parsed, name: String) -> Optional[Int]
OP.optional_float(parsed: Parsed, name: String) -> Optional[Float]
OP.rest(parsed: Parsed) -> List[String]
OP.after_dashes(parsed: Parsed) -> List[String]
OP.run!(result: Result[T]) -> T
OP.usage(parser: Parser) -> String
OP.help?(message: String) -> Bool
OP.message(error_text: String) -> String
```

```agentica {mode="check"}
import OP from "std/option_parser"
import {Arg, Opt, Kind as K} from "std/option_parser"

struct Options
  file: String
  port: Int
  verbose: Bool
  user: Optional[String]
end

def load() -> Result[Options]
  parser = OP.new(
    "tool",
    "Serves a file over HTTP",
    [Arg(name: "file", help: "file to serve")],
    [
      Opt(name: "port", short: "p", kind: K.Int, default: "8080", help: "port"),
      Opt(name: "verbose", short: "v", kind: K.Flag, help: "more output"),
      Opt(name: "user", kind: K.String, help: "user name"),
    ],
  )

  p = try OP.parse(parser, System.args())
  ok(
    Options(
      file: OP.string(p, "file"),
      port: OP.int(p, "port"),
      verbose: OP.flag(p, "verbose"),
      user: OP.optional_string(p, "user"),
    ),
  )
end

def main() -> Void
  options = OP.run!(load())
  puts("serving #{options.file} on :#{options.port}")
end
```

Este es el programa completo de una herramienta. A `parse` se le pasa `System.args()`, y `OP.run!` es el punto donde el programa termina cuando la línea de comandos está mal o pide ayuda.

## Arg y Opt {#arg-and-opt}

Ambas son estructuras con predeterminados, así que una llamada nombra solo los campos que necesita. Las dos listas de `new` guardan los argumentos, en el orden de la línea de comandos, y las opciones.

```ruby
Arg(name: String, help: String = "", kind: Kind = Kind.String, choices: List[String] = [], metavar: String = "",
    min: Optional[Int] = none, max: Optional[Int] = none, min_float: Optional[Float] = none,
    max_float: Optional[Float] = none)
Opt(name: String, short: String = "", kind: Kind = Kind.String, default: String = "", choices: List[String] = [],
    help: String = "", metavar: String = "", min: Optional[Int] = none, max: Optional[Int] = none,
    min_float: Optional[Float] = none, max_float: Optional[Float] = none)
```

`Kind` es `Int`, `Float`, `String` o `Flag`. Un `Flag` no recibe valor: es falso si no se da, y no tiene predeterminado ni valores permitidos. Un argumento no puede ser un `Flag` (un error de `parse`), y todos los argumentos son obligatorios. `short` es un carácter: no un dígito, `-`, `=` ni un espacio. Un nombre no tiene espacios ni caracteres de control, y `program` no está vacío. `default` es una cadena que `kind` convierte, igual que a la línea de comandos (`default: "8080"` para un `Int`); un `default` vacío significa que la opción no tiene ninguno. `choices` lista los textos permitidos, que se comparan como texto antes de la conversión. `metavar` es el nombre del valor en la ayuda (`<file>` para un argumento); una opción sin él muestra sus valores permitidos como `on|off`, si no su nombre en mayúsculas (`--user USER`; pon `metavar: "DIR"` para una ruta). `min` y `max` limitan una opción o un argumento `Int` (`some(0)`, `some(65535)`; `none` es sin límite), y `min_float` y `max_float` uno `Float` (`some(0.0)`, `some(1.0)`); también se aplican al `default`. Un límite de otra clase, un min mayor que su max, o un límite Float que no es un número finito es un error de la especificación.

## La línea de comandos {#the-command-line}

- `--port 3000`, `--port=3000`, `-p 3000`, `-p3000` y `-p=3000` dan un valor a una opción. Como en argparse, la palabra siguiente se toma como valor solo si no parece una opción: una palabra que no empieza por `-`, un `-` suelto y un número negativo (`-1`, `-2.5`) son valores. Cualquier otra palabra que empiece por `-` no lo es, así que `--port --verbose` es un error (`option --port needs a value`). `--name=--x` y `-n--x` dan el literal `--x`.
- Un número negativo también es un argumento: `tool -5` da el argumento `-5`. Cualquier otra palabra que empiece por `-` es una opción (usa `--` delante de ella).
- `-v` y `--verbose` activan el flag, y los flags cortos pueden unirse: `-vq`. La última letra de un grupo unido puede recibir un valor (`-vp3000`).
- `--` termina las opciones: cada palabra posterior es un argumento, como también lo es un `-` suelto.
- Una opción dada dos veces conserva su último valor.
- `--help` y `-h` piden la ayuda; los nombres `help` y `h` están reservados.

## Funciones de lectura {#getters}

`string`, `int`, `float` y `flag` devuelven el valor simple de un argumento, de un flag y de una opción que tiene predeterminado. `optional_string`, `optional_int` y `optional_float` devuelven un `Optional`: `none` cuando no se dio la opción y no tiene predeterminado.

```agentica
import OP from "std/option_parser"
import {Arg, Opt, Kind as K} from "std/option_parser"

def main() -> Void
  parser = OP.new(
    "tool",
    "",
    [Arg(name: "file")],
    [
      Opt(name: "port", short: "p", kind: K.Int, default: "8080"),
      Opt(name: "ratio", kind: K.Float),
      Opt(name: "verbose", short: "v", kind: K.Flag),
    ],
  )

  p = OP.parse(parser, ["-v", "--port=3000", "--", "-notes.txt"]).unwrap!
  puts(OP.string(p, "file"))
  puts(OP.int(p, "port"))
  puts(OP.flag(p, "verbose"))
  puts(OP.optional_float(p, "ratio"))
  q = OP.parse(parser, ["a.txt"]).unwrap!
  puts(OP.int(q, "port"))
  puts(OP.flag(q, "verbose"))
end
```

```output
-notes.txt
3000
true
none
8080
false
```

Una función de lectura llamada con un nombre que no se declaró, con la función de lectura de otra clase, o sobre una opción que puede faltar (`OP.string` donde hace falta `optional_string`) es un fallo del programa, no un error de quien lo usa. Detiene el programa con `RUNTIME-UNWRAP-ERROR`, cuyo mensaje nombra la opción y cuya traza de pila nombra la línea de la llamada. No devuelve un `Optional` ni un `Result`, así que las funciones de lectura siguen siendo simples.

## El resto de las palabras {#the-rest-of-the-words}

Todos los argumentos son obligatorios, y una palabra después del último es un error (`unexpected argument 'g'`), salvo que `new` reciba un quinto argumento, `rest`: el nombre de esas palabras en la línea de uso (`"FILE"` muestra `[FILE...]`; las filas de la ayuda no muestran ninguno para él, y el nombre no tiene espacios ni caracteres de control). Entonces `parse` las guarda, y `OP.rest(p)` las devuelve en orden, incluidas las que van después de `--`, como `OptionParser#parse` de Ruby devuelve el resto de `ARGV`. `OP.after_dashes(p)` devuelve las últimas palabras de `rest` que venían después de `--`, así que un comando como `check FILE... -- FLAGS` las separa sin mirar las palabras por sí mismo:

```agentica
import OP from "std/option_parser"
import {Opt, Kind as K} from "std/option_parser"

def main() -> Void
  # The fifth argument, "FILE", names the rest in the usage line.
  parser = OP.new("check", "", [], [Opt(name: "verbose", short: "v", kind: K.Flag)], "FILE")
  p = OP.parse(parser, ["a.c", "-v", "b.c", "--", "-Iinclude", "-DX=1"]).unwrap!
  rest = OP.rest(p)
  flags = OP.after_dashes(p)
  puts(rest.take(rest.size - flags.size))
  puts(flags)
  puts(OP.usage(parser).split("\n")[0])
end
```

```output
["a.c", "b.c"]
["-Iinclude", "-DX=1"]
Usage: check [options] [FILE...]
```

## Errores {#errors}

`parse` devuelve un `error` para un error de la línea de comandos. El texto es `tool: ` y un mensaje que nombra la opción o el argumento, y después una línea `Try 'tool --help' for more information`. Un programa que imprime el error por sí mismo imprime `OP.message(error_text)`: es el texto tal cual, salvo en una petición de ayuda (abajo), donde quita una línea marcadora con la que empieza el texto sin procesar. Los mensajes son:

- `unknown option --bogus` (o `-x`)
- `option --port needs a value`
- `option --verbose does not take a value`
- `invalid value for --port: 'abc' is not an Int` (o `a Float`; `'99999999999999999999' does not fit an Int` para un número demasiado grande)
- `invalid value for --ratio: '1e400' does not fit a Float`: una opción o un argumento Float rechaza un valor que no es finito (`+inf.0`, `-inf.0`, `+nan.0`, o un número demasiado grande), con límites o sin ellos
- `invalid value for --user: 'cy' is not one of ana, bob`
- `invalid value for --port: '70000' is above the maximum 65535` (o `below the minimum`; `the maximum 1.0` para un Float)
- `missing argument <file>`
- `unexpected argument 'g'`

Un error en la propia especificación, como un nombre duplicado, un nombre corto que no es un carácter, o un predeterminado que no se convierte, también es un `error` de `parse` (`tool: invalid specification: invalid default for --port: 'x' is not an Int`), sin la sugerencia.

```agentica
import OP from "std/option_parser"
import {Opt, Kind as K} from "std/option_parser"

def main() -> Void
  parser = OP.new("tool", "", [], [Opt(name: "port", short: "p", kind: K.Int)])
  puts(OP.parse(parser, ["--port", "abc"]).message)
  puts(OP.parse(parser, ["--bogus"]).message)
end
```

```output
tool: invalid value for --port: 'abc' is not an Int
Try 'tool --help' for more information
tool: unknown option --bogus
Try 'tool --help' for more information
```

## Ayuda y run! {#help-and-run}

`--help` o `-h` hacen que `parse` devuelva un `error` para el que `OP.help?(message)` es verdadero y cuya clase es `option_parser.help`; el texto de la ayuda es `OP.usage(parser)`. Un error en las palabras (una opción desconocida, un valor malo) es un `error` de la clase `option_parser.parse`, y una especificación incorrecta, de la clase `argument`. Lista la línea de uso, la descripción y una fila para cada argumento y cada opción, con sus nombres corto y largo, el nombre del valor, la ayuda y las notas entre corchetes (así que un texto de ayuda puede tener sus propios paréntesis): `[default: X]`, `[choices: a, b]` cuando el nombre del valor no las muestra ya (un argumento, o una opción con `metavar`), y `[min: 0, max: 65535]`.

```agentica
import OP from "std/option_parser"
import {Arg, Opt, Kind as K} from "std/option_parser"

def main() -> Void
  parser = OP.new(
    "tool",
    "Serves a file over HTTP",
    [Arg(name: "file", help: "file to serve")],
    [
      Opt(name: "port", short: "p", kind: K.Int, default: "8080", min: some(0), max: some(65535), help: "port"),
      Opt(name: "verbose", short: "v", kind: K.Flag, help: "more output"),
      Opt(name: "user", kind: K.String, choices: ["ana", "bob"], help: "user name"),
      Opt(name: "dir", metavar: "DIR", help: "model folder (a path)"),
    ],
  )

  result = OP.parse(parser, ["--help"])
  puts(OP.help?(result.message))
  puts(OP.usage(parser))
end
```

```output
true
Usage: tool [options] <file>

Serves a file over HTTP

Arguments:
  <file>              file to serve

Options:
  -p, --port PORT     port [default: 8080] [min: 0, max: 65535]
  -v, --verbose       more output
      --user ana|bob  user name
      --dir DIR       model folder (a path)
  -h, --help          show this help
```

### Encendido y apagado {#on-and-off}

No hay una clase Bool. Un `Flag` no recibe valor, así que un ajuste que se da como `--stats on` o `--stats off` es una opción `String` con `choices: ["on", "off"]` (y normalmente un `default`). La ayuda lo muestra como `--stats on|off`, cualquier otra palabra se rechaza, y el programa lo lee con `OP.string(p, "stats") == "on"`. Usa un `Flag` cuando basta con dar solo el nombre.

Un programa que maneja el `error` por sí mismo comprueba antes `OP.help?(message)`, o solo imprime `OP.message(message)`, que da el texto de la ayuda para una petición de ayuda y el mensaje en otro caso.

`OP.run!(result)` es la única función del módulo que termina el programa, y es el último paso habitual. Devuelve el valor de un `ok`. Para la ayuda imprime `OP.usage` en la salida estándar y termina con código 0; para cualquier otro `error` imprime el mensaje en el error estándar y termina con código 2. El nombre termina en `!` como las funciones que detienen el programa, porque no vuelve cuando el resultado es un error. Un programa que quiera otro comportamiento lee `parse` por sí mismo y llama a `System.exit`.
