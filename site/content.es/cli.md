---
title: Línea de comandos
weight: 3
description: Cada comando, opción y caché del programa agentica.
source_hash: "b4d6cf55811d"
---

El programa `agentica` ejecuta, comprueba y consulta programas de Agentica. Cada sección de abajo es un comando o un grupo de opciones. Para tu primer programa, mira [Primeros pasos](/getting-started/).

## Ejecutar {#run}

`agentica FILE.agc` comprueba un programa y lo ejecuta. Las palabras que van después del nombre del archivo llegan al programa a través de `System.args()`:

```agentica {mode="check"}
def main() -> Void
  for name in System.args()
    puts("Hello, #{name}!")
  end
end
```

```sh
agentica greet.agc Ana Bob    # prints one greeting per name
```

## REPL {#repl}

`agentica repl` lee entradas de la entrada estándar y ejecuta cada una en una sesión: los nombres que vincula una entrada, las funciones, structs y constantes que declara y las tareas que inicia siguen vivos para las siguientes entradas. Una entrada que termina en una expresión imprime su valor y su tipo:

```sh
$ agentica repl
agc> xs = [1, 2, 3]
agc> def total(items: List[Int]) -> Int = items.sum()
agc> total(xs) * 10
=> 60 : Int
```

- Una entrada es una línea, o más mientras las líneas que van hasta ahora la dejen abierta (un `def` sin su `end`, un corchete abierto, un comentario de documentación `##`); una línea vacía descarta una entrada a medias. Cuentan todas las líneas, también los comandos, así que un mensaje dice `(repl):12:5`.
- Una declaración hecha de nuevo sustituye a la anterior: una función que llamaba a la `f` antigua llama a la nueva. Un struct o enum declarado con otra forma descarta los nombres cuyos valores tienen la forma antigua, o que guardan un tipo así (un struct con un campo de ese tipo), y la respuesta los lista. Un enum no puede tomar el nombre de un struct de la sesión (`REPL-KIND-CHANGE`; primero `:reset`).
- Los nombres que empiezan como el código que la sesión escribe alrededor de una entrada (`repl_entry_`, `ReplEntry`, `repl_shown_`) dan `REPL-RESERVED-NAME`. Un nombre cuyo tipo es privado de un archivo importado no se guarda, y la respuesta lo dice (`skipped`).
- Un nombre conserva su tipo: `x = "s"` después de `x = 1` es `CHECK-TYPE-MISMATCH`. `x: String = "s"` le da un tipo nuevo.
- Un problema deja la sesión como estaba. Un fallo muestra su diagnóstico, y las tareas que la entrada inició antes siguen ejecutándose. `System.exit(n)` termina la sesión con el código de salida `n`.
- Comandos, al principio de una entrada: `:type EXPR` imprime el tipo y no ejecuta nada, `:load FILE` carga las declaraciones de un archivo como una sola entrada, `:reset` empieza una sesión nueva, `:quit` la termina (igual que el fin de la entrada estándar), `:help` los lista. Uno incorrecto da `REPL-UNKNOWN-COMMAND` o `REPL-USAGE`. Un archivo que `:load` carga conserva su parte `private`, sus importaciones parten de su carpeta, y un mensaje señala sus líneas; uno que no se puede leer da `QUERY-USAGE`.
- `--json` imprime un objeto por entrada y por comando en la salida estándar, cada uno con `entry` (su número en la sesión), `line` (su primera línea) y `ok`. Una entrada que se ejecutó añade `value` y `type` cuando muestra uno, `bound` (los nombres que vinculó, con sus tipos), `declared`, `dropped` y `skipped`, todos vacíos cuando falló; un problema añade `diagnostic`. `:type` añade `type`, `:help` `commands`, `:reset` `"reset":true`, y una entrada a medias que una línea vacía descarta `"discarded":true`. Lo que imprimen las entradas va a la salida de error estándar.
- Las entradas se ejecutan en un proceso hijo, `agentica run --session -`, siempre en un solo planificador y sin el JIT, el perfil ni la cobertura; las opciones de ejecución (`--max-steps`, `--seed`, `--deny-*`) llegan a él. Código de salida: 0 al final de la entrada estándar o después de `:quit`, 1 cuando la entrada estándar termina dentro de una entrada (`REPL-INCOMPLETE`). `System.exit(n)` en una entrada termina la sesión en silencio con el código de salida `n` (en `--json`, la respuesta tiene `exited`). Cuando el hijo termina durante una entrada por un error fatal, como el límite de pasos, la respuesta de la entrada es `REPL-SESSION-LOST`, después de ese error (`cause` en `--json`), y la sesión termina con el código de salida del hijo.

## Comprobar y errores {#check-and-errors}

`agentica check hello.agc` comprueba los tipos sin ejecutar y escribe `check ok`. `agentica check src tests/util.agc` comprueba varios archivos y carpetas a la vez (ver abajo). Cada ejecución comprueba primero, así que un error de tipos la detiene antes de cualquier salida. `check` acepta un archivo sin `main`; una ejecución o `compile` necesita `def main() -> Void`. El comprobador se detiene en el primer error:

```agentica {expect="CHECK-TYPE-MISMATCH"}
def main() -> Void
  count = 1 # count is an Int
  count = "two" # error: a String does not fit
  puts(count)
end
```

```text
bad.agc:3:11 error[CHECK-TYPE-MISMATCH]
expected Int, found String

3 |   count = "two"
  |           ^^^^^
  = help: convert it with s.to_i!
```

- Código de salida `1`: el programa tiene un error. Código de salida `2`: un comando incorrecto o un archivo que no se puede leer.
- Los códigos empiezan con `LEX-`, `PARSE-`, `CHECK-`, `RUNTIME-` o `LINT-` (las sugerencias de [`lint`](#suggest-style-changes)). Un error de ejecución también imprime la pila de llamadas. Ver [Diagnósticos](/reference/diagnostics/).
- `--ai` y `--json` imprimen el mismo error para las herramientas: `{"code":"CHECK-TYPE-MISMATCH","file":"bad.agc","range":{...},...}`. Una advertencia, que no es un error (`PKG-NATIVE-UNBUILT`), es un objeto JSON con `"warning": true`, o un bloque de `--ai` que empieza con `warning`.
- Una ruta de archivo imprime `check ok`, o su primer diagnóstico; con `--json`, `{"ok":true}` o el diagnóstico. Una carpeta, ninguna ruta o varias rutas terminan con un recuento (`check ok: 3 files`, o `check failed: 1 of 3 files` y código de salida 1), y cada archivo con error imprime su primer diagnóstico (con `--ai`, bajo el nombre del archivo). Con `--json` la salida es un objeto en la salida estándar, `{ok, checked, failed, files}`, con `{file, ok, diagnostic}` para cada archivo.
- Un problema de un archivo importado se muestra una vez: en la entrada de ese archivo si es una de las rutas; si no, en el primer importador. Los demás importadores no se cuentan como fallidos, y con `--json` su entrada es `{file, ok: false, imports}`.
- Una carpeta omite las carpetas ocultas, `agc_libs/`, `_build/`, la carpeta `deps/` de un proyecto y los enlaces simbólicos a archivos, igual que lo hace `symbol`; `build/` no se omite. Una ruta que no existe, o una carpeta sin ningún archivo `.agc`, es `QUERY-USAGE` y termina con el código de salida 2, y no se comprueba ningún archivo. Un archivo que no se puede leer es `QUERY-USAGE` en su entrada y hace que el código de salida sea 2; los demás archivos se comprueban igualmente.

## Sugerir cambios de estilo {#suggest-style-changes}

```sh
agentica lint src    # PATH is a file or a folder, default .; --json prints one document; --strict exits 1 for any suggestion
```

```text
src/orders.agc:12:5 LINT-STRING-APPEND-IN-LOOP this loop grows a String with +, which copies the text on every pass
  help: push the pieces on a List and join them once after the loop: parts = parts.push(piece), parts.join("")
lint: 1 suggestion in 1 of 12 files
```

`lint` sugiere cambios según la [guía de estilo](/style/). Solo analiza cada archivo, así que los imports no tienen que existir y no lee tipos. Una sugerencia no es un error: lo que siempre es un fallo (un import sin usar, código inalcanzable) sigue siendo un error de `check`. Cada línea es `file:line:column CODE message`, con la forma de escribirlo en la línea siguiente. Códigos de salida: `0` con o sin sugerencias; `1` con `--strict` y cualquier sugerencia (para CI), o cuando un archivo no se puede analizar (se imprime su primer diagnóstico, y la última línea dice `lint failed: 1 of 2 files could not be parsed`); `2` para una llamada incorrecta o un archivo que no se puede leer. `--json` imprime un objeto: `ok`, `checked`, `suggestions` y `files`, con una entrada para cada archivo con sus `suggestions` (cada una tiene `code`, `message`, `help`, `file` y `range`, como un diagnóstico) o su `diagnostic`; los archivos que no se pudieron analizar o leer son los que tienen un `diagnostic`. Las reglas, en el orden de la guía:

| Código | Sugiere |
|---|---|
| `LINT-PRIVATE-DOC` | ningún comentario `##` en una función, struct o enum privado |
| `LINT-REPEATED-QUALIFIED-NAME` | `import {Value} from "db"` para un nombre como `Db.Value` que un archivo escribe veinte veces o más |
| `LINT-IF-CHAIN` | `case` para un encadenamiento de `if` de tres o más ramas que comparan una variable con literales |
| `LINT-NEGATED-ELSE` | el caso positivo primero, no `if not x` con un `else` |
| `LINT-BOOL-COMPARE` | `if done`, no `if done == true` |
| `LINT-SINGLE-PIPE` | una llamada simple, no `x \|> f()` con un solo paso |
| `LINT-NESTED-CALL` | un pipe para tres llamadas anidadas en primera posición, `h(g(f(x)))`, cuando las dos externas son funciones del archivo o de un módulo que importa, no integrados; un `try` se queda en su paso (`\|> try h()`) |
| `LINT-LAMBDA-CHAIN` | un pipe hacia métodos, `xs \|> map(->(x) { ... }) \|> sum()`, para un encadenamiento de métodos de tres o más pasos desde el primero que pasa una lambda; un nombre sin argumentos cuenta solo como último paso |
| `LINT-TO-S-CONCAT` | interpolación, no `"n=" + n.to_s` |
| `LINT-STRING-APPEND-IN-LOOP` | `push` y un solo `join`, no `s = s + piece` en un bucle `for` o `while`, que copia el texto en cada iteración |

También marca una posible errata que `check` no puede marcar como error: `LINT-ERROR-KIND` es un texto literal de `is_a?` o `kind_of?` cuya primera parte es una familia de los integrados y de `std/` (`io`, `net`, `http`, `archive`, ...) pero que no es esa familia ni una de sus [clases](/library/errors/error/), como `e.is_a?("io.notfound")`; la ayuda nombra la clase más cercana. Se marca una clase de una familia integrada que el archivo no crea con `kind:`, así que una clase nueva como `error("x", kind: "number.negative")` se conoce en su archivo. No se marcan una familia propia (`db.constraint`) ni una clase calculada en tiempo de ejecución.

## Consultar un integrado {#look-up-a-builtin}

```sh
agentica help String.split    # `agentica help` alone lists commands and namespaces
```

```text
string.split(separator: String) -> List[String]
Split text; an empty separator gives characters.
```

Un tipo integrado también funciona: `agentica help File.Info` imprime su declaración, su descripción y sus campos (o las variantes de un enum), igual que `help std/MODULE.NAME` imprime un struct. `agentica help --json` imprime todos los integrados y tipos integrados como un solo arreglo JSON, ordenados por nombre; un tipo tiene un `kind` (`struct`, `enum` u `opaque`) y sus `fields` o `variants`, y una función no tiene `kind`.

## Leer la API de un módulo {#read-a-modules-api}

```sh
agentica doc std/queue    # a file path works too; --json prints one JSON object
```

Imprime las declaraciones exportadas en el orden del código fuente, cada una con su firma y su documentación `##`, y los campos de un struct o las variantes de un enum. Solo lee el archivo, así que los imports del módulo no tienen que existir. Las declaraciones privadas (después de `private`) no se incluyen.

Para aprender un módulo, `agentica help std/queue` lista sus exportaciones con la primera frase de cada documentación (como máximo unos 100 caracteres), y `agentica help std/queue.pop` imprime la firma y toda la documentación de una exportación (también los campos de un struct o las variantes de un enum). `--json` imprime un objeto JSON, con el primer párrafo entero como `summary`. Un módulo o un nombre que no existe es `QUERY-NOT-FOUND` (código de salida 2); para un nombre ofrece la exportación más parecida.

## Consultar el código {#query-the-code}

`outline`, `type-at`, `symbol` y `refs` responden preguntas sobre el código, para editores y agentes. Ninguno de ellos ejecuta el programa. Cada uno imprime texto, o un objeto JSON con `--json`. Códigos de salida: `0` respondido; `1` el código tiene un error (su primer diagnóstico es la respuesta); `2` una pregunta incorrecta o un archivo que no se puede leer. Los códigos `QUERY-` son `QUERY-USAGE` (argumentos o archivo incorrectos), `QUERY-NO-EXPRESSION` (no hay expresión en la posición), `QUERY-NOT-FOUND` y `QUERY-AMBIGUOUS-NAME`; ver [Diagnósticos](/reference/diagnostics/).

## Listar las declaraciones de un archivo {#list-a-files-declarations}

```sh
agentica outline src/orders.agc    # --json prints one JSON object; std/queue works too
```

```text
src/orders.agc:3:1 struct Order
src/orders.agc:4:3 field Order.id: Int
src/orders.agc:8:1 def total(order: Order) -> Int
src/orders.agc:14:1 private def round_cents(value: Float) -> Int
```

`outline` analiza su archivo, así que los imports no tienen que existir. Un archivo que vuelve a exportar un nombre (`export Url.parse`) también se enlaza, así que se lista la declaración original con su documentación. Cada línea empieza con `file:line:column`, como `rg`; las declaraciones privadas también se listan, con `private` delante, y una reexportación se escribe `export Alias.name`. `--json` añade la documentación `##`, la firma, `exported`, los rangos y los campos o variantes; un bloque de módulo (kind `module`) lista sus declaraciones bajo `items`.

## Tipo en una posición {#type-at-a-position}

```sh
agentica type-at src/orders.agc:22:14    # --json for one object; --stdin FILE:LINE:COL reads FILE from standard input
```

```text
src/orders.agc:22:9-22:19 user.email: String
src/models.agc:4:3 field email
```

La línea y la columna cuentan desde 1, en puntos de código (un emoji ocupa una columna). La primera línea es el tipo de la expresión y su rango; la siguiente es su definición (para un integrado, su firma). `type-at` comprueba el archivo y lo que importa, pero no necesita `main`. Un tipo de otro archivo se escribe por el alias de importación (`Models.User`), y uno de un bloque de módulo por el nombre del bloque (`Counter.State`, o `Agents.Counter.State` mediante un alias), salvo dentro de su propio bloque. Una variable local, un parámetro o una variable de bucle tiene un tipo y una definición en el punto donde se vincula. Un nombre de tipo en una anotación o en un argumento de tipo (`Models.User`) tiene `kind` `type` y como definición el struct, enum o alias que nombra; un tipo integrado (`Int`, `List`) no tiene ninguna. Un integrado (`split` en `xs.split(",")`) no tiene definición; con `--json` tiene `kind` `builtin` y, bajo `help`, el objeto de `agentica help NAME --json`.

## Buscar un nombre {#find-a-name}

```sh
agentica symbol Models.User.email src/    # PATH is a file or a folder, default .
```

```text
src/models.agc:4:3 field User.email: String
```

NAME se escribe como lo escribe el código: `total`, `User.email`, `Level.Info`, `Models.User` mediante el alias de importación de un archivo bajo PATH, `Counter.start` o `Agents.Counter.start` para una exportación de un bloque de módulo, `std/queue.pop` o un integrado (`Map.get`). Un nombre suelto lista todos los módulos que lo declaran, también las declaraciones privadas (un nombre privado de un bloque de módulo solo se encuentra como nombre suelto). Los archivos bajo PATH se enlazan entre sí; uno que no se enlaza aparece en `skipped` y los demás siguen respondiendo. `--json` añade `kind`, `module`, `exported`, `signature`, `doc` y los rangos a cada coincidencia.

## Buscar referencias {#find-references}

```sh
agentica refs Models.User.email src/    # or: agentica refs src/models.agc:4:3 src/
```

```text
src/models.agc:4:3 definition field User.email: String
src/orders.agc:22:14 read in total
src/report.agc:31:5 construct in sample
```

La primera línea es la declaración. Cada una de las demás líneas es un uso, con su clase (`call`, `value`, `type`, `construct`, `read`, `pattern`, `binding`, `argument` para el nombre de un argumento con nombre en una llamada, `verbose` de `check(gen, verbose: true)`, o `qualifier` para el nombre de un bloque de módulo escrito antes de uno de sus nombres, `Counter` de `Counter.start(1)`) y la función en la que está. La posición puede estar en un uso o en la declaración. Dos campos con un mismo nombre en dos structs nunca se mezclan. Un nombre al que responden varias declaraciones es `QUERY-AMBIGUOUS-NAME`; su ayuda lista cada una como `FILE:LINE:COL` para la forma con posición. Con `--json` la respuesta es un objeto, `{version, command, query, definition, builtin, references, skipped}`.

## Opciones {#options}

| Opción | Hace |
|---|---|
| `--max-steps N` | se detiene tras `N` pasos (`RUNTIME-STEP-LIMIT`). Cada planificador toma los pasos por lotes, así que el límite puede saltar un poco tarde; `--schedulers 1` mantiene el conteo exacto |
| `--max-heap SIZE` | termina la ejecución cuando la memoria del programa crecería más allá de `SIZE`: bytes, o un número con `K`, `M` o `G` (`256M`), hasta `1024G`. La ejecución termina con una línea que contiene `RUNTIME-HEAP-LIMIT` (un objeto JSON con `code` y `message` bajo `--json`) y con el código de salida 70; la salida que aún está en un búfer se pierde, como cuando se acaba la memoria. El límite se aplica al heap recolectado de todo el proceso, que empieza en 32M y contiene lo que usó compilar el programa, así que un tamaño menor solo evita que crezca. Cuenta la memoria de `JSON.parse`; otros búferes fuera del heap (archivos, sockets, zlib) no cuentan |
| `--seed N` | hace que `Random` repita los mismos números |
| `--flush-timeout MS` | espera como máximo `MS` ms a los datos de archivos, la salida, las liberaciones de memoria nativa y los búferes de escritura de los sockets cerrados al final, y después avisa. Por defecto 30000, como máximo 86400000. Variable de entorno `AGENTICA_FLUSH_TIMEOUT_MS` |
| `--schedulers N` | hilos planificadores, de 1 a 1024; por defecto, uno por núcleo lógico. Variable de entorno `AGENTICA_SCHEDULERS` (un valor vacío cuenta como no definido). `--schedulers 1` ejecuta una tarea cada vez, en un orden fijo. Un valor incorrecto termina con el código de salida 2; `agentica test` solo toma la variable de entorno |
| `--jit MODE` | `off`, `on` (por defecto) o `always`: compila las operaciones compatibles a código máquina en x86-64 (Linux, macOS y Windows) y arm64 (Linux y macOS); una llamada entre funciones compiladas es una llamada nativa. En otros sistemas, cualquier modo ejecuta el intérprete; la salida y el conteo de pasos no cambian. Variable de entorno `AGENTICA_JIT`; `agentica test` solo toma la variable de entorno |
| `--coverage FILE` | escribe la cobertura de líneas de la ejecución en `FILE` como LCOV (`SF`, `FN`, `FNDA`, `DA` y sus totales). Cuenta los archivos del programa y los paquetes que se leen en su sitio (miembros del workspace y dependencias `path`), no `std/` ni los paquetes descargados; el archivo de un paquete se nombra como en los diagnósticos, como `pkg/tools@path/tools.agc`. Una línea es una que empieza una sentencia o una expresión en la que el programa puede dar un paso; su conteo es la mayor cantidad de veces que se ejecutó una de ellas (con `--max-steps`, el paso que detiene la ejecución cuenta como ejecutado). El informe se escribe al terminar la ejecución, también una fallida. Un archivo que no se puede escribir hace fallar la ejecución (`RUNTIME-INTERNAL`) o, tras un fallo, añade una línea de advertencia. El JIT está desactivado en la ejecución. `agentica test` acepta `--coverage` sin archivo ([Cobertura](/library/testing/#coverage)) |
| `--deny-run` | hace que `Process.spawn` y los demás inicios devuelvan un error que empieza con `denied: --deny-run` |
| `--deny-net` | hace que las conexiones y las escuchas de `TCP` y `TLS` (también `std/http`) devuelvan un error que empieza con `denied: --deny-net` |
| `--deny-fs` | hace que cada llamada a `File`, `Dir` y `Path`, salvo `Path.join`, y `Lazy.write_lines` y `Lazy.write_bytes`, devuelva un error que empieza con `denied: --deny-fs` |
| `--deny-env` | hace que `System.env` devuelva un error que empieza con `denied: --deny-env`; la configuración regional de los textos de error sigue a `LANG` |
| `--deny-native` | rechaza un programa que declara un bloque `extern` o llama a un integrado `Native.*` antes de ejecutarse (`RUNTIME-NATIVE-DENIED`, código de salida 2). Cada flag `--deny-*` lo activa |
| `--sandbox` | todos los flags `--deny-*`: úsalo para ejecutar código en el que no confías. Un programa que puede iniciar procesos se escapa de un solo flag; usa `--sandbox`, o añade `--deny-run`. `agentica test` los da a los archivos de prueba, a los programas de pasos y a los programas probados, no a su ejecutor |
| `--native-build[=NAMES]` | compila los módulos nativos `NAMES` (`a,b`; todos los módulos sin `=`) desde el código fuente y nunca usa sus archivos precompilados. Variable de entorno `AGENTICA_NATIVE_BUILD` (`all` o `a,b`); ambas tienen prioridad sobre el `[native_policy]` del manifiesto (ver [módulos nativos](/library/io-and-system/native/modules/)) |
| `--native-prebuilt-only[=NAMES]` | usa solo los archivos precompilados de los módulos nativos `NAMES` y nunca los compila; uno que no tiene archivo en la caché es `PKG-NATIVE-BUILD`. Variable de entorno `AGENTICA_NATIVE_PREBUILT_ONLY`. Un módulo en los dos flags, o en las dos variables, es un error de uso (código de salida 2) |
| `--dump`, `--dump-ir` | imprimen el árbol comprobado o el IR del lowering en lugar de ejecutar |
| `--no-cache` | compila el programa de nuevo y no guarda su bytecode (ver [Caché de bytecode](#bytecode-cache)); `check` y `type-at` no leen ni escriben la caché de comprobación (ver [Caché de comprobación](#check-cache)) |

Un flag tiene prioridad sobre su variable de entorno.

Tres variables no tienen flag. `AGENTICA_GC_HEAP` (por defecto `32M`: bytes, o un número con `K`, `M` o `G`; `0` para el arranque propio del recolector; un valor incorrecto termina con el código de salida 2) fija el heap con el que arranca el recolector de basura: uno más grande se detiene menos veces y usa más memoria. El propio `GC_INITIAL_HEAP_SIZE` del recolector tiene prioridad sobre ella cuando está definido. `GC_FREE_SPACE_DIVISOR` (la VM usa 2; 3 usa menos memoria, 1 va más rápido) fija a qué velocidad crece el heap. `AGENTICA_PERF_MAP=1` pone nombre a las funciones compiladas para `perf` de Linux (ver [Perfil](/library/testing/profile/#linux-perf)).

## Comandos {#commands}

| Comando | Hace |
|---|---|
| `repl` | ejecuta las entradas de una en una en una sesión; ver [REPL](#repl) |
| `check [PATH...]` | comprueba cada archivo `.agc` de los archivos y carpetas indicados, o de la carpeta actual si no hay PATH; ver [Comprobar y errores](#check-and-errors) |
| `check --stdin FILE` | comprueba el texto de la entrada estándar como si `FILE` lo contuviera, para un búfer de editor que no está guardado. `FILE` no tiene que existir, pero su carpeta es donde se encuentran los imports, `agentica.toml` y `agc_libs/`; los demás archivos vienen del disco. Con `--json`, el diagnóstico nombra `FILE` |
| `lint [PATH...]` | sugiere cambios de estilo; ver [Sugerir cambios de estilo](#suggest-style-changes) |
| `fmt [PATH...]`, `fmt --check`, `fmt -`, `fmt --tree FILE` | da formato a los archivos en su sitio, lista los archivos que cambiaría, da formato a la entrada estándar, o imprime el árbol de análisis; ver [Formato](#format) |
| `outline --stdin FILE` | lista las declaraciones del texto de la entrada estándar como si `FILE` lo contuviera, igual que lo hace `check --stdin FILE` |
| `type-at --stdin FILE:LINE:COL`, `refs --stdin FILE:LINE:COL` | responden por el texto de la entrada estándar, como si `FILE` lo contuviera |
| `symbol NAME --stdin FILE`, `refs NAME --stdin FILE` | buscan en ese texto como un archivo más, el primero |
| `type-at --partial`, `refs FILE:LINE:COL --partial` | responden aunque algunas funciones no comprueben, a partir de las que sí lo hacen y del enlazado: el JSON tiene `"partial": true` y `diagnostics`, y el código de salida es 0. `refs` lo acepta para una posición sin PATH. `outline` acepta la opción y la ignora |
| `install`, `add NAME URL --tag TAG` (o `OWNER/REPO` para una URL de GitHub, `--ref COMMIT`, `--subdir DIR` o `--workspace`, `--group test`), `update [NAME]` | mantienen `deps/` y `agentica.lock`; ver [Paquetes](/tour/modules/#packages) |
| `native source NAME` | imprime la clave de origen del módulo nativo NAME del proyecto (su tabla `build` y los archivos de `native/`), la API nativa del binario y la URL de cada destino de su tabla `prebuilt`; con `--json`, un objeto con `source`, `api` y `urls` |
| `compile FILE -o OUT` | escribe bytecode de la VM |
| `compile [FILE...]` | rellena la [caché de bytecode](#bytecode-cache) como lo haría una ejecución con las mismas opciones, así que la siguiente ejecución arranca de inmediato, e imprime `compiled FILE` o `fresh FILE` por cada archivo; sin FILE, cada `main.agc` bajo la carpeta de trabajo fuera de las carpetas `tests/` y `fixtures/`, buscado como lo busca `check`. Con `--json` cada archivo es una línea `{"file":...,"state":"compiled"}` (o `"fresh"`). Un programa que no compila se informa y los demás sí se compilan; el código de salida es entonces 1 |
| `run [OPTIONS] -- FILE.agcb [ARGS...]` | ejecuta bytecode; `run` debe ser la primera palabra. Opciones: las de arriba salvo `--dump*`, más `--source-root DIR`, `--ai`, `--json` y `--program-name PATH` (lo que devuelve `System.program_name`; por defecto, el archivo). `run --version` lista las bibliotecas enlazadas |
| `--version` | imprime la versión |

## Formato {#format}

```sh
agentica fmt src         # format in place; PATH is a file or a folder, default .
agentica fmt --check .   # list the files fmt would change; exit 1 if there is one
agentica fmt - < a.agc   # format standard input to standard output
```

`fmt` da formato a cada archivo `.agc` de los archivos y carpetas indicados, buscados como los busca `check` (`agc_libs/` se omite salvo que lo nombres); un archivo que ya tiene formato no se escribe. La disposición es la de la [guía de estilo](/style/):

- Una sentencia por línea, sangría de dos espacios, y una llamada, lista, mapa o cabecera `def` en una línea cuando cabe; si no, un elemento por línea con una coma final. Una sentencia que ocupa varias líneas va seguida de una línea vacía, salvo que a continuación venga un comentario que cierra su bloque.
- Un encadenamiento de dos o más `|>` que es una sentencia completa, un valor de una vinculación o un valor de retorno ocupa una etapa por línea aunque quepa, entre paréntesis cerrados por un `)` solo. Un encadenamiento de métodos en ese lugar que el código escribe con un `.` al principio de cada línea se une cuando cabe, y si no, mantiene esa forma.
- Un `if` sin `elsif` ni `else`, sin comentario y con un solo `return`, `break` o `next` de una línea se escribe como la guarda que representa (`return x if c`) cuando cabe en la línea; una guarda que no cabe o que ocupa varias líneas se escribe como `if`.
- Un `def` cuyo cuerpo es un solo valor, con un resultado distinto de `Void` y sin comentario desde su línea `def` hasta su línea `end`, se escribe como un def de una línea (`def f() -> Int = value`) cuando cabe; un def de una línea que no cabe, o cuyo valor ocupa líneas propias, se escribe como un `def` con `end`, con una línea vacía a cada lado. Las líneas vacías alrededor de un def se conservan como están.
- En un def cuyo resultado no es `Void` (ni un alias de `Void` del mismo archivo), un último `return value` (también el último de una rama de un último `if` con `else`, o de una rama de un último `case`) se escribe como el valor suelto; un valor de `try` o de `case` conserva su `return`.
- Los comentarios conservan sus palabras y su orden; una línea `#` más ancha que el ancho se corta en varias líneas. Los finales de línea CRLF pasan a LF.

El `[style]` del `agentica.toml` más cercano a cada archivo fija el ancho (`max_line_width`, 119 si no existe), y `blank_line_after_end = true` añade la línea vacía después de cada `end` suelto que pide `check`; un valor incorrecto es `PKG-MANIFEST-INVALID`. `fmt` nunca parte un nombre ni una cadena, y deja un comentario final en la última línea de una sentencia, así que una línea puede quedar demasiado larga (`CHECK-LINE-TOO-LONG`).

- Un archivo que no se puede analizar imprime su diagnóstico, se deja como está y hace que el código de salida sea 1; con `fmt -` no se imprime nada en la salida estándar. Un archivo nombrado en la línea de comandos se formatea sea cual sea su extensión; un nombre que empieza con `-` se escribe `./-x.agc`. Una opción desconocida, una ruta que no existe o una carpeta sin ningún archivo `.agc` es `FMT-USAGE` y código de salida 2, y no se escribe ningún archivo.
- `fmt --check` no escribe nada; un archivo CRLF cuenta como cambiado. `fmt -` usa el `[style]` de la carpeta de trabajo.
- `fmt --tree FILE` imprime el árbol de análisis sin posiciones, sin la marca de guarda de un `if`, sin la marca de un `def` de una línea y sin la marca de una última expresión que da el valor de su def, y con las palabras de los comentarios, que el formato nunca cambia.

## Caché de bytecode {#bytecode-cache}

`agentica FILE.agc`, `agentica compile` y `agentica test` guardan el programa compilado de cada archivo raíz en `_build/bytecode/` y lo leen de nuevo mientras las fuentes sean las mismas.

- Cada entrada de la caché guarda el SHA-256 de cada archivo fuente (también `agentica.toml` y `agentica.lock`), cómo se encontró cada import, y la versión y la compilación del binario. La entrada de un programa con un módulo nativo guarda además el compilador de C con el que se compila el módulo (tal como lo encuentran `CC` y `PATH`) y las variables `CC`, `CPATH`, `C_INCLUDE_PATH`, `CPLUS_INCLUDE_PATH` y `LIBRARY_PATH`. Cualquier cambio vuelve a compilar el programa y reemplaza la entrada.
- `_build/` está en la carpeta del proyecto (el `agentica.toml` más cercano) o, para un archivo fuera de un proyecto, junto al archivo. Nada borra las entradas antiguas: borra la carpeta cuando quieras, y pon `_build/` en tu `.gitignore`.
- La entrada es bytecode que se ejecuta con tus permisos, así que solo se usa cuando `_build/`, `_build/bytecode/` y el archivo son carpetas y archivos reales (sin enlaces) de tu propiedad, sin el bit de escritura para el grupo ni para los demás. La caché crea la carpeta con modo 0700. Una carpeta que no pasa las comprobaciones se omite sin ningún mensaje, así que `/tmp` es un mal lugar para ella. Una carpeta que creas tú misma debe pasar `chmod go-w DIR`. En Windows solo se aplican las comprobaciones de enlace y de tipo de archivo.
- `AGENTICA_BUILD_DIR` da el nombre de otra carpeta en lugar de `_build/`. `--no-cache` no lee ni escribe la caché en una sola ejecución. `--dump`, `--dump-ir`, `compile FILE -o OUT` con un flag `--deny-*` o `--sandbox`, y `run -- FILE.agcb` no la usan, y un programa que no compila nunca se guarda en caché. El front end de una ejecución usa la caché incluso con `--deny-*`.
- Si una ejecución se detiene con `invalid bytecode` desde una entrada de la caché, borra `_build/bytecode/`.
- Cuando una ejecución compila su programa y el error estándar es una terminal, imprime antes `Compiling FILE…` allí, y el número de módulos y el tiempo cuando termina de compilar; no en un acierto de caché, no con `--ai` o `--json`, y no cuando el error estándar es un archivo o una tubería.

## Caché de comprobación {#check-cache}

`agentica check` y `agentica type-at` guardan lo que aprenden de cada archivo importado en `_build/check/`, así que un editor que los ejecuta en cada pulsación de tecla no vuelve a comprobar los mismos imports. Un archivo cuya entrada coincide (su texto y todo lo que importa no han cambiado) no se vuelve a comprobar; cualquier otro cambio es un fallo de la caché y el archivo se comprueba entero. La respuesta, con sus diagnósticos y rangos incluidos, es la misma que da una ejecución sin caché.

- El archivo raíz y el texto de `--stdin` siempre se comprueban por completo. Las entradas se escriben solo después de que un programa pase la comprobación.
- Sigue las reglas de la caché de bytecode: la misma elección de carpeta, las mismas comprobaciones de propiedad, y `--no-cache` la desactiva. Una entrada dañada se ignora. `outline`, `refs` y `symbol` no la usan.
- La primera ejecución tras un cambio escribe las entradas; las siguientes las leen.

## Pruebas {#test}

```sh
agentica test                                    # test/ and specs/
agentica test test/ports_test.agc --only port    # only tests whose name has "port"
agentica test --jobs 4                           # up to 4 scenarios or test files at once
agentica test --timing                           # and the time of each file and the slowest scenarios
agentica test --coverage                         # and the line coverage in coverage/lcov.info
agentica test --isolate                          # each scenario in a process of its own
```

Ejecuta los archivos `*_test.agc` ([Pruebas](/library/testing/test/)) y las especificaciones `.feature` ([BDD](/library/testing/bdd/)). `--jobs N` (de 1 a 1024, por defecto 1) ejecuta hasta `N` trabajos a la vez: cada escenario de un archivo feature (cada fila de un Scenario Outline) y cada archivo de prueba es un trabajo. Cada una de las `N` ranuras ejecuta sus escenarios en un proceso trabajador mientras pasen; `--isolate` ejecuta cada escenario en un proceso propio, lo que además vuelve a ejecutar el `main` del programa de pasos para cada uno ([BDD](/library/testing/bdd/)). El informe mantiene el orden de los archivos y de los escenarios de cada archivo. Los escenarios o archivos que comparten un puerto, una ruta o una base de datos necesitan `--jobs 1`, y un `N` alto hace más probables los tiempos de espera por prueba con la CPU cargada. `--timing` añade, antes de los totales, el tiempo de la ejecución (tiempo de reloj, menor que la suma de los archivos con `--jobs`), una línea por cada archivo con la suma de los tiempos de sus escenarios y su número de escenarios, y los 5 escenarios más lentos, en milisegundos; no cambia nada en `--json`. El informe `--json` siempre tiene `duration_ms` (un campo adicional, con cualquier flag): en el informe, el tiempo de reloj de la ejecución; en cada archivo, la suma de los tiempos de sus escenarios; y en cada escenario, su propio tiempo. `--coverage` escribe la cobertura de líneas de los fuentes que ejecutaron las pruebas en `coverage/lcov.info` ([Cobertura](/library/testing/#coverage)).

## Soporte para editores {#editor-support}

- [agc-tmlanguage](https://github.com/agentica-lang/agc-tmlanguage) es una gramática TextMate para archivos `.agc`, probada con vscode-textmate, el resaltador de sintaxis de VS Code y Shiki.
- [tree-sitter-agentica](https://github.com/agentica-lang/tree-sitter-agentica) es una gramática de tree-sitter con consultas de resaltado. La [configuración de Neovim](https://github.com/agentica-lang/agc-tmlanguage/blob/main/docs/neovim.md) la usa.
- [agc-lsp](https://github.com/agentica-lang/agc-lsp) es un servidor de lenguaje: ejecuta `agentica check` sobre el archivo en disco cuando se abre o se guarda, y muestra el primer error.
