---
title: BDD
weight: 2
description: Programas de prueba con archivos de características Gherkin y el comando agentica test.
source_hash: "3d4ae00333f7"
---

`agentica test` ejecuta archivos Gherkin `.feature`. Cada escenario inicia tu programa como un proceso aparte, le envía una entrada y comprueba su salida.

## Una primera característica {#a-first-feature}

`greet.agc` saluda al nombre que lee:

```agentica
def main() -> Void
  name = gets!.strip
  puts("Hello, #{name}!")
end
```

```input
Ana
```

```output
Hello, Ana!
```

`specs/greet.feature`:

```gherkin
Feature: Greeting

  Scenario: Greet by name
    Given the Agentica program "../greet.agc"
    When I send the line "Ana"
    Then I receive the line "Hello, Ana!" within 5000 milliseconds
    And the program exits with code 0 within 5000 milliseconds
```

Ejecútalo:

```sh
agentica test specs/
```

Código de salida `0`: todos los escenarios pasan o se omiten (también cuando se omiten todos, así que un trabajo de CI debe comprobar que la cantidad de `skipped` es la que espera). `1`: uno falla. `2`: las pruebas no pudieron ejecutarse (también un directorio temporal compartido sin el bit sticky: define `TMPDIR` como una carpeta privada).

- `--ai` y `--json` cambian el formato del informe. `--only TEXT` conserva los escenarios y las pruebas cuyo nombre contiene `TEXT`.
- `--tags EXPR` conserva los escenarios cuyas etiquetas coinciden: `@a`, `not @a`, unidos con `and` y `or` (`not` tiene prioridad sobre `and`, y `and` sobre `or`; sin paréntesis), como en `--tags "@db and not @slow"`. Un escenario tiene las etiquetas de su Feature y las suyas, y una fila de `Scenario Outline` también las de su bloque `Examples`. Los archivos de prueba unitaria no tienen etiquetas, así que se dejan fuera. Una expresión incorrecta termina con `2`.
- `--jobs N` y `--isolate` (cada escenario en un proceso propio, véase más abajo): [Pruebas](/cli/#test).
- Un paso fallido se informa en su línea y columna del archivo de características.
- Cada fila de un `Scenario Outline` recibe el nombre del outline y los valores de la fila en las columnas que el nombre no muestra, como `Name (sqlite, 42)`, así que `--only "(sqlite, 42)"` selecciona una fila. Las filas idénticas conservan un solo nombre; `--json` tiene la línea de cada fila en `example`.
- Un escenario tiene 1.000.000 de pasos por cada uno de sus pasos, más uno (un paso que los gasta falla con `RUNTIME-STEP-LIMIT`); `--max-steps N` o `--max-steps unlimited` después de `test` cambia el 1.000.000, con o sin `--isolate`. Los programas bajo prueba no tienen límite de pasos.
- `--seed N` hace que `Random` se repita en los pasos y los programas. Sin él, el ejecutor de pruebas obtiene una semilla para cada programa de pasos y cada programa bajo prueba, y la muestra cuando la ejecución falla.
- También ejecuta los archivos de prueba unitaria `*_test.agc` ([Test](/library/testing/test/)) en el mismo informe. Sin rutas, busca en `specs/` y `test/`.

## Pasos integrados {#built-in-steps}

No hace falta código. `{string}` es un texto entre comillas dobles, `{int}` un número entero.

| Paso | Hace |
|---|---|
| `the environment variable {string} is {string}` | define una variable para el programa, antes de que inicie |
| `the program argument {string}` | añade un argumento de línea de comandos al programa, antes de que inicie |
| `the Agentica program {string}` | inicia el programa; una ruta relativa al archivo de características |
| `I send the line {string}` | envía el texto y una línea nueva |
| `I send a line:` | envía el Doc String de abajo y una línea nueva |
| `I send input:` | envía el Doc String de abajo tal cual |
| `I close stdin` | cierra la entrada del programa |
| `I receive the line {string} within {int} milliseconds` | comprueba la siguiente línea de salida |
| `I receive a line within {int} milliseconds:` | comprueba la siguiente línea con el Doc String |
| `I receive a JSON line within {int} milliseconds:` | compara la siguiente línea como JSON, en cualquier orden de claves y los números por valor |
| `stdin remains open` | comprueba que el programa sigue ejecutándose |
| `the program exits with code {int} within {int} milliseconds` | espera el código de salida |
| `stdout is:` / `stderr is:` | al terminar el programa, compara la stdout que ningún paso de línea ha leído aún, o toda la stderr |
| `stdout includes:` / `stderr includes:` | al terminar el programa, comprueba que el mismo texto contiene el Doc String como subcadena |

`Given`, `When`, `Then`, `And` y `But` coinciden con los mismos pasos. `Background`, `Scenario Outline` con `Examples`, los Doc Strings (`"""`) y las tablas de datos funcionan. Un `<...>` en un outline se reemplaza cuando nombra una columna de `Examples`; cualquier otro `<...>`, en un paso o en un Doc String, se queda como está escrito, como en Cucumber (`#include <stdio.h>` o HTML están bien). Una columna mal escrita no es un error: el texto del paso conserva su `<name>`, y el paso falla como no definido si ningún patrón lo coincide.

## Entorno y argumentos {#environment-and-arguments}

Los dos pasos antes de `the Agentica program` dan al programa su entorno y sus `System.args`:

```gherkin
Scenario Outline: Greet in a language
  Given the environment variable "GREETING" is "<greeting>"
  And the program argument "--name"
  And the program argument "<name>"
  And the Agentica program "../greet.agc"
  Then I receive the line "<line>" within 5000 milliseconds

  Examples:
    | greeting | name | line      |
    | Hola     | Ana  | Hola, Ana |
```

- Una variable se añade al entorno en el que se ejecuta `agentica test`; el programa ve las demás tal como están. Definir un nombre otra vez reemplaza su valor. La variable llega solo al programa de ese escenario: no al ejecutor de pruebas, ni a ningún otro escenario.
- Cada `the program argument` añade un argumento, en orden, sin dividir por espacios: `"a b"` es un solo argumento. El programa los lee con `System.args`.
- Ambos van antes de `the Agentica program`; después de él fallan con `RUNTIME-BDD-CONTEXT`, porque el programa ya ha iniciado. Un nombre de variable no puede estar vacío ni contener `=`, un nombre o un valor no puede contener un byte NUL, y `AGENTICA_CHANNEL`, `AGENTICA_VM_METRICS`, `AGENTICA_VM_METRICS_FILE` y `UV_USE_IO_URING`, que son de la VM, no se pueden definir: cada uno da `RUNTIME-BDD-CONTEXT`. En Windows los nombres no distinguen mayúsculas, así que `Path` y luego `PATH` definen una sola variable, con el segundo valor; dos nombres que se diferencian solo en la mayúscula de una letra fuera de ASCII, como `Ä` y `ä`, hacen que `the Agentica program` falle con `RUNTIME-BDD-IO`.
- Un escenario inicia un programa. Para ejecutarlo otra vez con otros valores, escribe otro escenario (una fila de outline lo es). Para un peer que se ejecuta junto al programa, véase [Un programa peer](#a-peer-program).

## Tus propios pasos {#your-own-steps}

Un programa de pasos construye una lista con `BDD.step` en `main` y la pasa a `BDD.run`. La mayoría de las funciones `BDD.*` reciben primero el contexto y lo devuelven. `BDD.Context` se puede nombrar pero no crear: un contexto existe solo dentro de un paso, así que usa el contexto que devuelve una llamada. Los módulos bajo `std/bdd/` y `std/test/` son internos de `agentica test` y no tienen soporte. Carga los pasos con `--steps`:

```sh
agentica test specs/ --steps steps.agc
```

Sin `--steps`, `agentica test` usa el `steps.agc` más cercano que se encuentre en la carpeta de cada ruta que contenga un archivo `.feature` (la propia ruta si es una carpeta) o por encima de ella, hasta el directorio de trabajo, así que `specs/steps.agc` no necesita flag, tampoco para `specs/auth/` o `specs/a.feature`. Solo se aplica a una ejecución con archivos `.feature`. Si las rutas llevan a dos archivos `steps.agc` distintos, la ejecución falla con `RUNTIME-BDD-USAGE`; pasa `--steps`. `--steps` lo anula.

```agentica {mode="check"}
import BDD from "std/bdd"

def remember(ctx: BDD.Context, args: List[String]) -> BDD.Context = BDD.set(ctx, "count", JSON.from(args[0].to_i!))

def check_count(ctx: BDD.Context, args: List[String]) -> BDD.Context
  count = JSON.int(BDD.get(ctx, "count").unwrap!).unwrap!
  BDD.assert(ctx, count == args[0].to_i!, "wrong count")
end

def main() -> Void
  BDD.run([BDD.step("I remember {int}", &remember), BDD.step("the count is {int}", &check_count)])
end
```

```gherkin
Feature: Memory

  Scenario: Remember a number
    When I remember 3
    Then the count is 3
```

- Un paso recibe el contexto `ctx` del escenario y lo devuelve; el siguiente paso recibe lo que devolvió el anterior. La mayoría de las llamadas a `BDD` reciben y devuelven el contexto: conserva el que se devuelve. `BDD.doc_string`, `BDD.table`, `BDD.get`, `BDD.call` y `BDD.read_line` devuelven su valor en su lugar. Cada paso `Then` debe hacer al menos una comprobación de `BDD`.
- Cada hueco de `--jobs` ejecuta sus escenarios uno tras otro en un proceso trabajador, cada escenario en una tarea propia: sus valores (`BDD.set`, `BDD.keep`), su programa bajo prueba, los handles y las tareas que abrió, su semilla y su `Task.pending_count` son suyos. Un fallo, `System.exit` o un bucle sin fin hace fallar solo su escenario, y el siguiente escenario recibe un trabajador nuevo; lo mismo ocurre con cualquier escenario que falla o se omite. Un paso debe terminar las tareas que inicia (`RUNTIME-BDD-PENDING-TASKS`); un fallo sin esperar lo hace fallar con `RUNTIME-TASK-CRASHED`.
- Un trabajador ejecuta `main` una sola vez, así que el estado que `main` crea antes de `BDD.run` y que capturan los pasos (una tabla `ATS`, un `Channel`) lo comparten los escenarios que ejecuta ese trabajador, y lo mismo pasa con el estado de proceso que un paso define, como `Logger.set_level`. Crea ese estado en un paso (un `Background`) para que sea nuevo en cada escenario, o ejecuta con `--isolate`, que da a cada escenario un proceso propio y vuelve a ejecutar `main` para cada uno, como antes de la 0.32. `main` solo debe crear la lista y llamar a `BDD.run`. Ejecutado solo, un programa de pasos imprime cómo ejecutarlo y termina con código 2.
- Un paso puede importar archivos y usar `Process.spawn`. Su entrada estándar está vacía (`IO.gets` da el error de fin de entrada). No debe llamar a `Process.parent_read_line` ni a `Process.parent_send`: pertenecen al ejecutor de pruebas.

## BDD.step y BDD.run {#bddstep-and-bddrun}

```signature
BDD.step(pattern: String, handler: Fn[BDD.Context, List[String], BDD.Context]) -> BDD.Step
BDD.run(steps: List[BDD.Step], hooks: Optional[BDD.Hooks] = none) -> Void
```

El handler recibe el contexto y las capturas `{string}` y `{int}` como cadenas, en orden. Un bloque también sirve y ve las variables que lo rodean:

```agentica {mode="check"}
import BDD from "std/bdd"

def main() -> Void
  answer = "42"
  BDD.run([BDD.step("the answer is {int}") do |ctx, args| BDD.assert(ctx, args[0] == answer, "wrong answer") end])
end
```

`BDD.run` pone los pasos integrados delante de la lista, ejecuta lo que pide `agentica test`, y nunca devuelve. `hooks` prepara una característica una vez para sus escenarios ([Hooks de característica](#feature-hooks)).

## Hooks de característica {#feature-hooks}

```signature
BDD.Feature(name: String, tags: List[String])
BDD.Hooks(before_all: Fn[BDD.Feature, Result[JSON.Value]], after_all: Fn[BDD.Feature, JSON.Value, Result[Void]])
BDD.feature_state(ctx: BDD.Context) -> JSON.Value
```

`before_all` inicia lo que necesita una característica entera, como un servidor para todos sus escenarios, y `after_all` lo detiene. Son `before(:all)` y `after(:all)` de RSpec, y `BDD.after` es el hook de cada escenario.

- Se ejecutan en el trabajador que corre los escenarios, una vez por característica y por trabajador: con `--jobs 4` una característica puede arrancar hasta cuatro veces, así que usa el puerto 0 y una carpeta propia. Con `--isolate` cada escenario tiene un proceso propio, así que se ejecutan en cada escenario.
- `before_all` se ejecuta antes del primer escenario de la característica que toma el trabajador, en una tarea que queda viva hasta `after_all`. Un handle que abre (un programa iniciado con `Process.spawn`) pertenece a esa tarea, así que sobrevive a los escenarios y se cierra cuando la tarea termina. Devuelve el estado de la característica como JSON (un puerto, una carpeta) y cada escenario lo lee con `BDD.feature_state`. Sin hooks es `null`.
- `after_all` se ejecuta, con ese estado, cuando el trabajador deja la característica (el siguiente escenario es de otra característica, o el hueco no tiene más). Un trabajador que terminó por un escenario fallido no ejecuta ninguno: sus handles se cierran con él, y el siguiente escenario recibe un trabajador nuevo y un `before_all` nuevo.
- El ejecutor de pruebas no restablece nada. Cada escenario debe dejar lo que creó `before_all` como lo encontró: restablécelo en un paso `Background` o en un hook `BDD.after`.
- Un `before_all` que devuelve un `error`, falla o tarda más de 25 segundos hace fallar al escenario que lo necesitaba con `RUNTIME-BDD-BEFORE-ALL`, en su primer paso. Los demás escenarios de esa característica en el hueco de ese trabajador quedan `not_executed`. Un `after_all` que devuelve un `error` o falla es `RUNTIME-BDD-AFTER-ALL` en el archivo de la característica, en su línea `Feature`, y la ejecución termina con `1`.

```agentica {mode="check"}
import BDD from "std/bdd"

def start(feature: BDD.Feature) -> Result[JSON.Value]
  server = try Process.spawn("agentica", ["server.agc"], Process.Options(timeout_ms: 20000))
  port = try Process.read_line(server, 5000)
  ok(JSON.object({"port": JSON.from(port.to_i!)}))
end

def stop(feature: BDD.Feature, state: JSON.Value) -> Result[Void] = ok()

def main() -> Void
  BDD.run([], hooks: some(BDD.Hooks(before_all: &start, after_all: &stop)))
end
```

## BDD.assert {#bddassert}

```signature
BDD.assert(ctx: BDD.Context, condition: Bool, message: String) -> BDD.Context
```

Hace fallar el escenario con el mensaje cuando la condición es `false`.

## BDD.skip {#bddskip}

```signature
BDD.skip(ctx: BDD.Context, reason: String) -> BDD.Context
```

Termina el paso y su escenario como omitidos, con el motivo en el informe: los pasos posteriores no se ejecutan, y la ejecución sigue pasando. Úsala cuando un escenario necesita algo que le falta a la máquina.

```agentica {mode="check"}
import BDD from "std/bdd"

def need_postgres(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return ctx if System.env("POSTGRES_URL").ok?

  BDD.skip(ctx, "POSTGRES_URL is not set")
end

def main() -> Void
  BDD.run([BDD.step("a PostgreSQL server", &need_postgres)])
end
```

El informe muestra `SKIP`, el resumen cuenta `skipped`, y `--json` da `"status": "skipped"` y el `reason`. Combínalo con una etiqueta, como `@postgres`, y `--tags "not @postgres"` deja esos escenarios fuera por completo.

## BDD.set y BDD.get {#bddset-and-bddget}

```signature
BDD.set(ctx: BDD.Context, name: String, value: JSON.Value) -> BDD.Context
BDD.get(ctx: BDD.Context, name: String) -> Result[JSON.Value]
```

Guarda valores JSON entre los pasos de un escenario (cada uno empieza vacío). `BDD.get` da un error para un nombre que falta.

## BDD.keep y BDD.call {#bddkeep-and-bddcall}

```signature
BDD.keep(ctx: BDD.Context, name: String, service: Fn[JSON.Value, Result[JSON.Value]]) -> BDD.Context
BDD.call(ctx: BDD.Context, name: String, request: JSON.Value) -> Result[JSON.Value]
```

Guarda un valor que no es JSON entre los pasos de un escenario, como una conexión abierta. El servicio es una función de una solicitud a un resultado, ambos JSON, y captura el valor. `BDD.call` ejecuta el servicio guardado bajo `name`, o da un error cuando no hay ninguno. Cada escenario empieza sin servicios. Guardar un nombre otra vez reemplaza el servicio, y el handle anterior no se cierra hasta que termine el proceso del escenario (usa [BDD.after](#bddafter) para cerrarlo antes). Un paso no puede dejar una tarea en ejecución, así que el servicio hace su trabajo en el paso llamador.

```agentica {mode="check"}
import BDD from "std/bdd"

def open_pair(ctx: BDD.Context, args: List[String]) -> BDD.Context
  listener = TCP.listen("127.0.0.1", 0).unwrap!
  client = TCP.connect("127.0.0.1", TCP.local_port(listener), 5000).unwrap!
  server = TCP.accept(listener, 5000).unwrap!
  BDD.keep(ctx, "pair") do |request|
    try TCP.send(client, JSON.encode(request) + "\n", 5000)
    JSON.parse(try TCP.read_line(server, 5000))
  end
end

def check_echo(ctx: BDD.Context, args: List[String]) -> BDD.Context
  reply = BDD.call(ctx, "pair", JSON.from(args[0])).unwrap!
  BDD.assert(ctx, JSON.string(reply).unwrap! == args[0], "wrong reply")
end

def main() -> Void
  BDD.run([BDD.step("a connected pair", &open_pair), BDD.step("the pair echoes {string}", &check_echo)])
end
```

## Un programa peer {#a-peer-program}

`BDD.given_program` inicia un programa, y cada paso que envía, lee o comprueba habla con él. Un segundo programa con nombre necesitaría un nombre en cada uno de esos pasos, y un peer necesita sus propios pasos de todos modos (para conocer su puerto, o para leer lo que recibió). Por eso un paso inicia el peer él mismo con [Process.spawn_captured](/library/io-and-system/process/#processspawn_captured) y guarda el handle con `BDD.keep`. Un programa que inicia un paso pertenece al escenario y se detiene cuando este termina, así que no hace falta limpieza. Inicia primero el peer, y luego pasa lo que el programa necesita de él con `BDD.given_env` o `BDD.given_argument`:

```agentica {mode="check"}
import BDD from "std/bdd"

# ./peer prints the port it listens on, then one line for each message it receives.
def start_peer(ctx: BDD.Context, args: List[String]) -> BDD.Context
  peer = Process.spawn_captured("./peer", [], Process.Options(timeout_ms: 5000)).unwrap!
  port = Process.read_line(peer, 5000).unwrap!
  kept = BDD.keep(ctx, "peer") do |_request| ok(JSON.from(Process.read_line(peer, 5000).unwrap_or(""))) end
  BDD.given_env(kept, "PEER_PORT", port)
end

def check_received(ctx: BDD.Context, args: List[String]) -> BDD.Context
  line = JSON.string(BDD.call(ctx, "peer", JSON.null()).unwrap!).unwrap!
  BDD.assert(ctx, line == args[0], "the peer received #{line.inspect}")
end

def main() -> Void
  BDD.run([BDD.step("a peer", &start_peer), BDD.step("the peer received {string}", &check_received)])
end
```

```gherkin
Scenario: The program talks to the peer
  Given a peer
  And the Agentica program "../app.agc"
  When I send the line "hello"
  Then the peer received "hello"
```

El handle del peer vive en el closure del servicio, así que un paso posterior lee de él por `BDD.call`, y la lectura tiene un tiempo de espera para que un peer silencioso haga fallar el paso. Una lectura que agota el tiempo mata al peer, como hace con un programa bajo prueba (véase [Process](/library/io-and-system/process/)), así que hazla el último uso. Inicia el peer en el propio handler del paso: un programa pertenece a la tarea que lo inició, así que uno iniciado en un `Task.spawn` se detiene cuando esa tarea termina, y un paso no puede dejar una tarea en ejecución.

## BDD.after {#bddafter}

```signature
BDD.after(ctx: BDD.Context, hook: Fn[BDD.Context, Result[Void]]) -> BDD.Context
```

Registra una limpieza que se ejecuta cuando el escenario termina, tanto si pasó, falló como si se omitió. Un paso la registra justo después de crear lo que hay que limpiar, así que el hook existe solo cuando hay algo que limpiar.

- Los hooks se ejecutan en el orden inverso al de registro, en el proceso del escenario. Un hook recibe el contexto con el que terminó el escenario, y devuelve `ok()` o `error(message)`. Usa ese contexto para cualquier llamada a `BDD` dentro del hook.
- Un hook que devuelve un `error`, tiene un fallo o hace fallar una comprobación de `BDD` es un hook fallido, y los demás hooks se siguen ejecutando. Esto vale para una comprobación en cualquier contexto, también en uno que el hook capturó al registrarse. Un hook fallido hace fallar un escenario que pasó, con el código `RUNTIME-BDD-AFTER` en la línea del escenario. En un escenario que falló, el fallo sigue siendo el informado, y el mensaje del hook se añade a él.
- Los hooks **no** se ejecutan cuando termina el proceso del escenario en sí: un paso que falla (un `.unwrap!` sobre un `error`, una división entre cero), un paso o hook que llama a `System.exit`, o el límite de 30 segundos. Un escenario que falla por un fallo deja lo que creó, así que mantén una limpieza de carpetas viejas para ese caso, o haz que los pasos devuelvan `error` y compruébalo con `BDD.assert` en vez de `.unwrap!`.
- Los hooks se ejecutan antes de detener el programa bajo prueba, y ninguna llamada a `BDD` lo detiene antes. En Windows, puede que un hook no pueda quitar una carpeta que el programa todavía tiene abierta.
- Un hook se guarda en el contexto que devuelve `BDD.after`. Un paso que registra un hook y luego falla con un contexto anterior (`BDD.assert(ctx, ...)` con el `ctx` de antes) no lo ejecuta: pasa el contexto que devolvió `BDD.after`.
- Un hook no puede llamar a `BDD.skip`. Un hook que falla después de `BDD.skip` convierte el escenario omitido en uno fallido (`RUNTIME-BDD-AFTER`). Un hook que nunca termina se informa cuando pasa el límite de 30 segundos del escenario.

```agentica {mode="check"}
import BDD from "std/bdd"

def remove(path: String) -> Result[Void] = Path.remove(path, 5000)

def make_folder(ctx: BDD.Context, args: List[String]) -> BDD.Context
  path = args[0]
  Dir.mkdir(path, 5000).unwrap!
  BDD.after(ctx) do |_| remove(path) end
end

def main() -> Void
  BDD.run([BDD.step("a folder {string} for this scenario", &make_folder)])
end
```

## BDD.doc_string y BDD.table {#bdddoc_string-and-bddtable}

```signature
BDD.doc_string(ctx: BDD.Context) -> String
BDD.table(ctx: BDD.Context) -> List[List[String]]
```

Lee el Doc String o la tabla de datos bajo el paso actual.

```agentica {mode="check"}
import BDD from "std/bdd"

def check_rows(ctx: BDD.Context, args: List[String]) -> BDD.Context
  rows = BDD.table(ctx)
  BDD.assert(ctx, rows.size == 3, "expected a header and two rows")
end

def send_body(ctx: BDD.Context, args: List[String]) -> BDD.Context = BDD.when_line(ctx, BDD.doc_string(ctx))

def main() -> Void
  BDD.run([BDD.step("the table has two rows:", &check_rows), BDD.step("I send the record:", &send_body)])
end
```

## Controlar el programa {#driving-the-program}

```signature
BDD.given_env(ctx: BDD.Context, name: String, value: String) -> BDD.Context
BDD.given_argument(ctx: BDD.Context, value: String) -> BDD.Context
BDD.given_program(ctx: BDD.Context, path: String) -> BDD.Context
BDD.when_line(ctx: BDD.Context, text: String) -> BDD.Context
BDD.when_input(ctx: BDD.Context, text: String) -> BDD.Context
BDD.when_eof(ctx: BDD.Context) -> BDD.Context
BDD.read_line(ctx: BDD.Context, timeout_ms: Int) -> Result[String]
BDD.then_line(ctx: BDD.Context, expected: String, timeout_ms: Int) -> BDD.Context
BDD.then_json_line(ctx: BDD.Context, expected: String, timeout_ms: Int) -> BDD.Context
BDD.then_stdin_open(ctx: BDD.Context) -> BDD.Context
BDD.then_exit(ctx: BDD.Context, code: Int, timeout_ms: Int) -> BDD.Context
BDD.then_stdout(ctx: BDD.Context, expected: String) -> BDD.Context
BDD.then_stderr(ctx: BDD.Context, expected: String) -> BDD.Context
BDD.then_stdout_includes(ctx: BDD.Context, expected: String) -> BDD.Context
BDD.then_stderr_includes(ctx: BDD.Context, expected: String) -> BDD.Context
```

Los pasos integrados como funciones, para combinarlos en tus propios pasos. Pasa el contexto que devuelve `BDD.given_program`: contiene el programa. `BDD.given_program` compila un programa una vez por ejecución, la primera vez que un escenario lo inicia, y los escenarios posteriores inician ese bytecode mientras el texto del archivo y las variables que ubican los paquetes y el compilador de C (`AGENTICA_PATH`, `HOME`, `CC` y similares, dadas por `BDD.given_env`) sean los mismos: un cambio durante la ejecución en un archivo que importa no se ve. Un programa que no compila se inicia con `agentica FILE.agc`, que imprime su diagnóstico. `BDD.given_env` y `BDD.given_argument` van antes de `BDD.given_program` y devuelven el contexto que se le pasa.

`BDD.read_line` devuelve la siguiente línea de salida en lugar de compararla, así que un paso puede usarla. Es un error cuando la salida terminó o no llegó ninguna línea dentro de `timeout_ms`; un tiempo de espera agotado detiene el programa bajo prueba, como en `BDD.then_line`: cada lectura, envío o comprobación de terminación posterior falla con `RUNTIME-BDD-IO`, así que hazla el último uso del programa.

`stdout is:` compara la salida que ningún paso de línea ha leído aún. `stdout includes:` y `stderr includes:` comprueban el mismo texto como subcadena, igual que lo hace `s.include?` (un texto vacío es `RUNTIME-BDD-CONTEXT`), así que un escenario de registro puede comprobar una línea de un stderr ruidoso; un fallo muestra el flujo entero como `actual`. Las cuatro necesitan que el programa haya terminado. La salida se guarda hasta 1 MiB por flujo.

Una comprobación `then_*` fallida informa `expected` y `actual` en la forma inspect, igual que `Test.eq`: una línea o una salida entre comillas, un código de salida como número, una línea JSON como su texto JSON, con las claves en su orden (la propia comprobación ignora el orden de las claves). El `actual` de un paso no definido o ambiguo es el texto del paso entre comillas. Un texto de más de 64 Ki caracteres se corta, termina con `...` y se omite la cantidad. Un error de front end del programa de pasos mantiene los nombres de tipo tal cual (`Int`, `String`), así que su forma `--json` depende del código.

## Ejecutar pruebas desde un programa {#running-tests-from-a-program}

Ninguna función ejecuta archivos de características desde un programa. Inicia `agentica test --json` con `Process.spawn` y lee su informe.
