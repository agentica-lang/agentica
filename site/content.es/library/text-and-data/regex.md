---
title: Expresiones regulares (std)
weight: 13
description: El módulo std/regex, que busca, extrae, reemplaza y divide texto con expresiones regulares en tiempo lineal.
source_hash: "5016d1429186"
---

`std/regex` está escrito en Agentica: `import Regex from "std/regex"`. Toma la sintaxis de RE2 y de Go, da la coincidencia más a la izquierda y cuenta las posiciones en caracteres, como lo hacen `index_of` y `slice`. Su motor de coincidencias no hace retrocesos, así que una búsqueda tarda un tiempo proporcional a la longitud del texto por el tamaño del patrón, sea cual sea la entrada. Nada en él detiene el programa: un patrón o una plantilla malos dan un error.

```ruby
Regex.compile(pattern: String) -> Result[Regex.Regex]
Regex.match?(text: String, regex: Regex.Regex) -> Bool
Regex.match(text: String, regex: Regex.Regex) -> Result[Regex.Match]
Regex.find_all(text: String, regex: Regex.Regex) -> List[Regex.Match]
Regex.replace(text: String, regex: Regex.Regex, template: String) -> Result[String]
Regex.split(text: String, regex: Regex.Regex) -> List[String]
Regex.escape(text: String) -> String
Regex.named(match: Regex.Match, name: String) -> Result[Regex.Group]
```

El texto va primero, así que un pipe se lee como la llamada: `text |> Regex.split(re)`. Un patrón fijo se escribe como literal de expresión regular, `/pattern/flags`; `Regex.compile` sirve para un patrón que se crea en runtime.

```agentica
import Regex from "std/regex"

def read_year(text: String) -> Result[String]
  found = try Regex.match(text, /(?P<year>\d{4})-\d{2}-\d{2}/)
  year = try Regex.named(found, "year")
  ok(year.text)
end

def main() -> Void
  puts(read_year("released on 2026-11-01"))
  puts(Regex.replace("Ada Lovelace", /(\w+) (\w+)/, "$2, $1"))
  puts("a, b;c" |> Regex.split(/[,;]\s*/))
  puts(Regex.find_all("7 apples, 12 pears", /\d+/).map do |m| m.text end)
  puts(Regex.match?("No Digits", /digits/i))
  fruit = Regex.compile("\\b" + Regex.escape("pears") + "\\b").unwrap!
  puts(Regex.match?("7 pears", fruit))
  puts(Regex.compile("(ab"))
end
```

```output
ok("2026")
ok("Lovelace, Ada")
["a", "b", "c"]
["7", "12"]
true
true
error("character 4: missing ')' for the group at character 1", kind: "regex.syntax")
```

`Regex.escape(text)` da un patrón que coincide con `text` de forma literal. Un patrón que se pasa a `Regex.compile` es un `String`, así que cada barra invertida del patrón se escribe dos veces: `"\\d+"` es el patrón `\d+`.

## Literales de expresión regular {#regex-literals}

Un literal de expresión regular es `Regex.compile` de su cuerpo, comprobado cuando se compila el programa. El cuerpo es el patrón tal como se escribe, sin escapes de cadena: `/\d+\.\d+/` es el patrón `\d+\.\d+`, y `\/` es una barra. El archivo debe importar `std/regex`, en cualquier forma; sin importación, el literal es `CHECK-REGEX-IMPORT`. Un patrón que `compile` rechaza es `CHECK-INVALID-REGEX`, en el carácter que indica el error, así que un literal nunca falla en runtime y no necesita `unwrap!`. Un literal dentro de una función se crea una sola vez, antes de `main`, incluso dentro de un bucle.

- Los flags van después de la barra de cierre: `i` ignora las mayúsculas y es `(?i)`; `m` hace que `.` coincida con un salto de línea y es `(?s)`. `/a.b/im` es el patrón `(?is)a.b`, que también es su `source`. Otra letra, o un flag escrito dos veces, es `LEX-REGEX-FLAG`.
- `#{` no puede aparecer en el cuerpo (`LEX-REGEX-INTERPOLATION`); `\#{` coincide con el texto `#{`. Crea un patrón a partir de valores con `Regex.compile`.
- El cuerpo termina al final de la línea: una barra de cierre que falta es `LEX-UNTERMINATED-REGEX`.
- Después de un valor, `/` es división: `a / b / c` divide, y `x /= 2` es el operador compuesto. Después de un operador, una coma, un corchete de apertura o una palabra clave, empieza un literal: `[/a/, /b/]`, `return /a/`. Una llamada necesita sus paréntesis: `puts(/x/)`; `puts /x/` es una división y un error. Una línea que empieza con `/ 2` es un literal que no termina; pon el `/` al final de la línea anterior.
- Un literal no es un patrón de `case`: compruébalo en un `if` con `Regex.match?`.

Ojo si vienes de Ruby: `^` y `$` son anclas del texto, así que `/^ERROR/` solo coincide al inicio del texto; escribe `/(?m)^ERROR/` para los inicios de línea. El flag `m` significa «el punto coincide con un salto de línea», como en Ruby, mientras que `(?m)` dentro del patrón significa anclas de línea. No hay `=~` ni `$1`: usa `Regex.match` y los grupos de la coincidencia.

## Coincidencias {#matches}

```ruby
struct Regex.Match
  text: String               # the whole match, the same as groups[0].text
  start: Int                 # character index of its first character
  stop: Int                  # character index after its last character
  groups: List[Regex.Group]  # groups[0] is the whole match
  names: Map[String, Int]    # group name to its index in groups
end

struct Regex.Group
  text: String               # "" when the group did not take part
  start: Int                 # -1 when the group did not take part
  stop: Int                  # -1 when the group did not take part
  matched: Bool
end
```

Los grupos se numeran desde 1 según su paréntesis de apertura. `Regex.named(m, name)` lee un grupo con nombre, y un nombre que no existe es un error. Un `Regex.Regex` guarda el patrón como `source`; solo `compile` y un literal de expresión regular crean uno. Imprimir un `Regex.Regex` muestra primero `source` y luego su programa compilado.

- `match?` dice si el patrón coincide en algún lugar. No guarda grupos, así que es la búsqueda más barata.
- `match` da la coincidencia más a la izquierda, o `error("no match")`. Entre las alternativas gana la primera que coincide: `a|ab` sobre `ab` da `a`.
- `find_all` da cada coincidencia de izquierda a derecha, sin solapamientos. Tras una coincidencia vacía, la búsqueda avanza un carácter, y una coincidencia vacía justo donde terminó la anterior se descarta, como en Go: reemplazar `x*` por `-` en `abxd` da `-a-b-d-` (Python da `-a-b--d-`).
- `replace` reemplaza cada coincidencia que encuentra `find_all`.
- `split` corta el texto en cada coincidencia que ocupe al menos un carácter, y conserva las partes vacías: `,a,,b,` dividido en `,` es `["", "a", "", "b", ""]`. Una coincidencia vacía no separa nada; para obtener los caracteres usa `s.split("")`.

## Plantillas {#templates}

En la plantilla de `replace`, `$0` es la coincidencia completa, `$1` a `$N` es un grupo, `${name}` es un grupo con nombre, `${N}` es un grupo por número, y `$$` es un signo de dólar. `$N` toma cada dígito que sigue, así que `$10` es el grupo 10; escribe `${1}0` para el grupo 1 y un `0`. Un grupo que no participó da `""`. La plantilla se comprueba antes de reemplazar cualquier texto: otra forma de `$` o un grupo que el patrón no tiene es un error, como `no group 10`.

Fíjate en las dos formas que se parecen: en una cadena de Agentica, `"#{name}"` pone en la cadena el valor de la variable `name`, mientras que `"${name}"` es texto de plantilla que `replace` lee como el grupo llamado `name`. Escribe `"#{...}"` solo para crear la plantilla con tus propios valores.

## Sintaxis {#syntax}

- Literales: cualquier carácter salvo `\ . + * ? ( ) | [ ] { } ^ $`. Una barra invertida delante de un signo de puntuación lo vuelve literal. Secuencias de escape: `\n \r \t \f \v`, `\x7F` y `\x{10FFFF}`.
- `.` coincide con cualquier carácter salvo un salto de línea; con `(?s)` también coincide con un salto de línea.
- Clases de caracteres: `[abc]`, rangos `[a-z]`, negación `[^a-z]`, secuencias de escape y las clases de abajo dentro. Un `]` al principio de una clase y un `-` al principio o al final son literales.
- `\d` `[0-9]`, `\w` `[0-9A-Za-z_]`, `\s` `[\t\n\f\r ]`, y sus negaciones `\D \W \S`. Solo son ASCII.
- Anclas: `^` y `$` son el inicio y el final del texto, o de una línea con `(?m)`; `\A` y `\z` son siempre el inicio y el final del texto; `\b` y `\B` son una frontera de palabra ASCII y su negación.
- Grupos: `(...)` captura, `(?:...)` no, y `(?P<name>...)` y `(?<name>...)` capturan con un nombre.
- Alternancia `|`: gana la primera que coincide.
- Repetición: `*`, `+`, `?`, `{n}`, `{n,}`, `{n,m}`, cada una perezosa, con un `?` detrás (`*?`). Una `{` que no empieza una repetición es literal: `a{,3}` coincide con el texto `a{,3}`.
- Flags: `(?i)` ignora las mayúsculas (solo letras ASCII), `(?m)` hace que `^` y `$` funcionen por líneas, `(?s)` deja que `.` coincida con un salto de línea. `(?i-s)` activa y desactiva flags, y `(?i:...)` los fija para un grupo. Un flag puesto en medio de un grupo dura hasta el final de ese grupo.

No se admiten, cada una es un error de `compile`: referencias hacia atrás (`\1`), lookahead y lookbehind, grupos atómicos, repeticiones posesivas, `\Q...\E`, clases Unicode como `\pL`, clases POSIX como `[[:alpha:]]`, las secuencias de escape `\a` y `\0`, escapes octales y `\b` dentro de una clase.

En qué se diferencia de Ruby: `^` y `$` son anclas del texto, no de línea (escribe `(?m)^` para un inicio de línea), y `(?m)` significa líneas, no «el punto coincide con un salto de línea» (aquí, `(?s)`). En qué se diferencia del `re` de Python: `$` no coincide antes de un salto de línea final, `\d \w \s \b` son ASCII como con `re.ASCII`, `\B` coincide en el texto vacío, como en Go, y la regla de coincidencias vacías de `find_all` y `split` sigue a Go.

## Errores y límites {#errors-and-limits}

Un error de compilación empieza por el carácter donde está, contado desde 1: `character 4: missing ')' for the group at character 1`. Un patrón tiene como máximo 4096 caracteres, un número de repetición como máximo 1000, como máximo 10000 instrucciones después de expandir sus repeticiones (`(?:a{1000}){11}` es demasiado grande), grupos anidados como máximo 256 niveles de profundidad y como máximo 256 grupos.

## Costo {#cost}

El motor de coincidencias corre dentro de la VM y cede el control después de cada trozo del texto, así que una búsqueda larga la comparte con otras tareas, y `--max-steps` la detiene con `RUNTIME-STEP-LIMIT`. Una búsqueda sobre un texto de n caracteres, con un patrón de m instrucciones y g grupos, tarda O(n·m·g) tiempo, y `match?` tarda O(n·m). `(a+)+$`, que en un motor con retroceso tarda un tiempo exponencial, aquí tarda un tiempo lineal. Para detener una búsqueda después de cierto tiempo, ejecútala en una tarea y espérala con un tiempo de espera (`Task.await(task, timeout_ms)`).

`find_all` devuelve todas las coincidencias a la vez, así que un patrón que coincide con cada carácter hace un `Match` por carácter. Compila un patrón de runtime una sola vez, fuera del bucle que lo usa; un literal ya se crea una vez.
