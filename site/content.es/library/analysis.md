---
title: Análisis de código (std)
weight: 8
description: El módulo std/analysis, que responde desde un programa a las preguntas de check, outline, type-at, symbol y refs.
source_hash: "a41783d6a281"
---

`std/analysis` responde, dentro de un programa, a las preguntas que responde la línea de comandos: `import Analysis from "std/analysis"`. Las respuestas son estructuras simples. Las funciones `*_json` dan los mismos bytes que la salida `--json` de `agentica outline`, `type-at`, `symbol` y `refs` ([Línea de comandos](/cli/#query-the-code)), y `Analysis.diagnostic_json` da lo que `--json check` escribe en stderr.

```ruby
Analysis.workspace() -> Analysis.Workspace
Analysis.open(files: Analysis.Workspace) -> Analysis.Session
Analysis.update(session: Analysis.Session, path: String, text: String) -> Analysis.Session
Analysis.close(session: Analysis.Session, path: String) -> Analysis.Session
Analysis.refresh(session: Analysis.Session, path: String) -> Analysis.Session
Analysis.entry(session: Analysis.Session, path: String) -> Result[Analysis.Entry]
Analysis.adopt(session: Analysis.Session, entry: Analysis.Entry) -> Analysis.Session
Analysis.check(session: Analysis.Session, path: String) -> Analysis.Checked
Analysis.outline(session: Analysis.Session, path: String) -> Result[Analysis.Outline]
Analysis.type_at(session: Analysis.Session, path: String, line: Int, column: Int) -> Result[Analysis.TypeAt]
Analysis.type_at_partial(session: Analysis.Session, path: String, line: Int, column: Int) -> Result[Analysis.TypeAt]
Analysis.symbol(session: Analysis.Session, name: String, paths: List[String]) -> Result[Analysis.Symbols]
Analysis.refs(session: Analysis.Session, path: String, line: Int, column: Int) -> Result[Analysis.Refs]
Analysis.refs_partial(session: Analysis.Session, path: String, line: Int, column: Int) -> Result[Analysis.Refs]
Analysis.native_modules(session: Analysis.Session, path: String) -> Result[Analysis.NativeModules]
Analysis.bodies(session: Analysis.Session, path: String) -> Result[Analysis.Bodies]
Analysis.diagnostic(message: String) -> Result[Analysis.Diagnostic]
Analysis.outline_json(found: Analysis.Outline) -> JSON.Value
Analysis.type_at_json(found: Analysis.TypeAt) -> JSON.Value
Analysis.symbols_json(found: Analysis.Symbols) -> JSON.Value
Analysis.refs_json(found: Analysis.Refs) -> JSON.Value
Analysis.native_modules_json(found: Analysis.NativeModules) -> JSON.Value
Analysis.bodies_json(found: Analysis.Bodies) -> JSON.Value
Analysis.diagnostic_json(found: Analysis.Diagnostic) -> JSON.Value
```

## Sesiones y búferes {#sessions-and-buffers}

Una `Session` lee archivos del disco bajo la carpeta de trabajo, salvo los archivos que tienen un búfer: texto que un editor tiene abierto y no ha guardado. `Analysis.update(session, path, text)` devuelve una sesión donde `path` tiene `text`, haya o no haya archivo en el disco. `Analysis.close` quita el búfer. Dos formas de escribir un mismo archivo son un solo búfer. Crea la carpeta de un archivo nuevo antes de `update`, y ciérralo con `close`, usando la misma forma de escribir la ruta que usaste. Un búfer responde por su propio archivo y por cada archivo que lo importa.

`Analysis.open` toma un `Workspace`: `Analysis.workspace()` da uno vacío, o crea uno cuyo mapa `buffers` guarda rutas y textos. Su `version` debe ser 1. Cuando dos rutas nombran un mismo archivo, gana la última.

Una sesión es un valor. Las tareas pueden compartir una y hacerle preguntas a la vez; un `update` en una tarea deja sin cambios las copias de las demás. Sus campos no forman parte de la API. Una sesión nueva no tiene caché: cada pregunta ejecuta las etapas desde el principio, hasta que `refresh` la llena (sección siguiente).

## Refrescar y la caché {#refresh-and-the-cache}

`Analysis.refresh(session, path)` devuelve una sesión cuya caché guarda el programa enlazado y comprobado de `path`, y los módulos analizados que lee. Un bucle que mantiene una sesión ejecuta `update`, luego `refresh`, y luego las preguntas, que se saltan el análisis y la comprobación sobre `path`.

`check`, `type_at` y `refs` usan el programa comprobado de la caché; `symbol` enlaza cada archivo que busca y usa solo sus módulos analizados. Cada pregunta vuelve a leer los archivos, empezando por el suyo, y usa la caché solo donde los módulos y sus textos son los de los que se hizo la caché. Las ediciones de búferes, `close`, los cambios en el disco, los archivos nuevos y los borrados, y un cambio de `agentica.toml` que cambie lo que significa un import, cuentan. Así, las respuestas son las mismas con o sin `refresh`: una caché desactualizada cuesta tiempo, nunca una respuesta errónea. Al refrescar, se vuelve a comprobar solo cuando cambió un módulo, y solo se analizan los módulos cuyo texto cambió. Un módulo cuyo texto es el mismo, junto con todos los módulos que importa, no se vuelve a comprobar: la comprobación toma lo que dejó para él el último programa de `path` que se comprobó, así que una edición de `path` cuesta lo que cuesta el propio archivo, y una edición de un módulo importado comprueba ese módulo y los que lo importan. Las respuestas son las de una comprobación desde el principio. Un archivo que no se puede leer ni enlazar deja la caché como estaba, y las preguntas dicen por qué.

La caché guarda como máximo 16 archivos comprobados, y sale primero el que menos recientemente se refrescó, junto con los módulos analizados a los que llegan. Vive en el valor: no hay tarea, canal ni bloqueo, así que el llamador controla el bucle. Ejecuta un `refresh` a la vez por sesión y guarda la sesión que devuelve. Refrescar dos veces una misma sesión hace dos cachés, y guardar una descarta el trabajo de la otra, lo que cuesta solo tiempo. Un programa que refresca en una tarea y llama a `update` en su propia copia, mientras tanto, adopta la sesión refrescada solo si no llegó ningún `update` ni `close` después de que empezara a refrescar; si no, guarda su propia sesión y refresca de nuevo después.

## Compartir la caché entre tareas {#sharing-the-cache-between-tasks}

Una `Session` tiene funciones, así que una tabla `ATS` no puede guardar una. Un `Analysis.Entry` es lo que `refresh` guardó para un archivo, como datos simples. `Analysis.entry(session, path)` lo toma de una sesión refrescada; es un error cuando la caché no guarda ninguno para `path` (sin refrescar, un archivo que no se enlaza, o un Entry que salió de la caché). Usa para `entry` la misma forma de escribir la ruta que en `refresh`: un archivo que solo tiene un búfer no se canoniza, así que otra forma no encuentra nada. `Analysis.adopt(session, entry)` devuelve la sesión con la caché de ese Entry y nada más, y los mismos búferes. Después, al refrescar o al preguntar por ese archivo toma el programa del Entry si los archivos y los búferes siguen igual; si no, vuelve a comprobar solo los módulos que cambiaron o que importan uno que cambió. Un Entry desactualizado cuesta tiempo, nunca una respuesta errónea. Los campos de un `Entry` no forman parte de la API.

Así, las tareas que refrescan archivos distintos no pierden nada. Cada tarea refresca su propia sesión, guarda `Analysis.entry(refreshed, path)` en un `ATS[String, Analysis.Entry]` bajo la ruta, y una tarea que pregunta por un archivo adopta primero el Entry de ese archivo. Los Entry de dos archivos son cachés separadas: la tabla comparte el programa comprobado de cada archivo, no los módulos que importan ambos archivos. El programa decide cuándo un Entry sale de la tabla, por ejemplo cuando se cierra el archivo.

```ruby
def refresh_into(entries: ATS[String, Analysis.Entry], session: Analysis.Session, path: String) -> Void
  found = Analysis.entry(Analysis.refresh(session, path), path)
  if found.ok?
    entries.put(path, found.unwrap!)
  end
end

def check_from(entries: ATS[String, Analysis.Entry], session: Analysis.Session, path: String) -> Analysis.Checked
  found = entries.get(path)
  return Analysis.check(Analysis.adopt(session, found.unwrap!), path) if found.ok?
  return Analysis.check(session, path)
end
```

## Respuestas {#answers}

Las respuestas son estructuras de cadenas, enteros, booleanos y listas, sin enum. Sus campos son las claves de las formas `--json`, con los mismos nombres, salvo que `range` es un `Region` con `start` y `stop` (en JSON, `end`). Un valor ausente es `""`, o una lista vacía en el caso de una estructura: `Outline.doc`, `Item.doc` y `Import.alias` son `""` donde el JSON tiene `null`. `TypeAt.definition` está vacío o guarda un `Definition`. Un `kind` es una cadena, un conjunto abierto: un programa acepta una clase que no conoce.

Los tipos son alias de los propios de la biblioteca. Un programa lee sus campos, pero no los puede crear por nombre: `Analysis.Position(line: 3, column: 9)` es `CHECK-UNKNOWN-TYPE`. Para obtener un `Diagnostic`, por ejemplo por un tiempo de espera, léelo desde JSON con `Analysis.diagnostic`.

Un archivo se nombra como en la línea de comandos: por su ruta canónica, relativa a la carpeta de trabajo cuando está dentro de ella. Un diagnóstico guarda el archivo raíz con la ruta que diste, como hace `check`, así que `Checked.file` y el `file` de su diagnóstico pueden escribirse de forma distinta.

- `Analysis.check` enlaza y comprueba el archivo. `Checked.passed` es verdadero cuando no hay ningún problema; `diagnostics` guarda el primero, si lo hay.
- `Analysis.outline` lista lo que declara el archivo. El archivo solo se analiza. Un bloque de módulo es un `Item` de clase `"module"` cuyos `items` son sus declaraciones; `items` está vacío en cualquier otra clase.
- `Analysis.type_at` da el tipo y la definición en una posición. La línea y la columna cuentan desde 1.
- `Analysis.symbol` busca dónde se declara `name` en los archivos y carpetas de `paths` (`.` cuando la lista está vacía). Una carpeta significa cada archivo `*.agc` que hay dentro de ella. Los archivos se enlazan juntos, y los que no se enlazan se listan en `Symbols.skipped`. `Symbol.module` es el archivo (`""` para un integrado), y `help` es el objeto de `agentica help NAME --json` para un integrado, y null de JSON para los demás. Cada archivo con un búfer en la sesión también se busca, primero, como lo hace `--stdin FILE`, aunque `paths` no lo nombre, así que una consulta no puede limitarse a una carpeta mientras hay otros búferes abiertos. Los búferes vienen en el orden por bytes de sus rutas canónicas, sea cual sea el orden en que se pusieron, así que `matches` no depende del historial de llamadas a `update`. Las carpetas se listan en el disco: una carpeta que existe solo como búferes (el búfer `newdir/new.agc` con `paths` `["newdir"]`) es un `QUERY-USAGE` "cannot read". Nombra el archivo del búfer, o deja `paths` vacío.
- `Analysis.refs` da la declaración del nombre en la posición y cada referencia a él, como hace `agentica refs`. Enlaza y comprueba el archivo como lo hace `type_at`, y ve el archivo y lo que importa; un archivo que solo lo importa no se ve. `Refs.definition` está vacío para un integrado, que `Refs.builtin` nombra (`""` para cualquier otra cosa). Un `Reference` es el `range` del nombre en su `file`.
- `Analysis.type_at_partial` y `Analysis.refs_partial` son `type_at` y `refs` con `--partial`: cuando algunas funciones no se comprueban, responden con las demás, con `partial` en verdadero y los fallos en `diagnostics`; una declaración, `main` o constante que no se comprueba, o un campo o un integrado en el caso de `refs_partial`, sigue siendo el primer problema como error. `TypeAt.type` es `""` para un nombre dentro de una función que no se comprobó, y en esa función una posición que el enlace no puede nombrar da el primer problema como error.

## Módulos nativos {#native-modules}

`Analysis.native_modules(session, path)` describe los bloques `extern module "NAME"` de un archivo para una herramienta que genera código para un [módulo nativo](/library/io-and-system/native/modules/), como una cabecera de C, sin tener que escribir su propio parser ni sus propias reglas de tipos. El archivo se enlaza y se comprueba como para `type_at`, y no necesita `main`. No tiene forma de línea de comandos; `native_modules_json` da el JSON de la respuesta, con `command` `native-modules`.

Un `NativeModules` tiene los `blocks` del archivo, en el orden del código fuente; dos bloques de una misma biblioteca cuentan como uno. Un `NativeBlock` tiene:

- `library`, el `NAME` tal como se escribió, y el `range` de sus declaraciones, desde la primera hasta la última, sin la línea `extern module` ni el `end` (el árbol de sintaxis no tiene lugar para ellos). Los bloques de una misma biblioteca son un solo bloque, así que su rango puede cubrir las declaraciones de otro bloque, y dos rangos pueden solaparse;
- `functions`, cada una con su `name` tal como se escribió (`empty?`), su `mode` (`short` para un `def`, `dirty` para un `compute def`), `parameters` (`name` y `type` canónico), `result`, `signature`, `exported`, `doc` y `range`, y `types_in` y `types_out`, los nombres de las estructuras, enums y recursos que alcanzan los parámetros y el que alcanza el resultado, también a través de los campos y de los payloads, cada uno una vez, cada lista en el orden de su propio recorrido, que no es una subsecuencia del orden de `types` del bloque: para un parámetro `A{b: B}`, `B{c: C}` y un resultado `C`, el bloque lista A, C, B pero `types_in` es A, B, C, así que no las juntes por posición (un tipo solo en `types_out` lo crea el módulo y nunca se lee, y uno solo en `types_in` se lee y nunca se crea);
- `resources`, las líneas `resource Name`, con `exported`, `doc` y `range`;
- `types`, las estructuras y los enums que cruzan, cada uno con su `kind` (`struct` o `enum`), su `name` suelto, sus `members` (campos o variantes, con sus `types` canónicos) y su `shape`;
- `api_major` y `api_minor`, la versión mínima de la API de C (`AN_API_MAJOR` y `AN_API_MINOR` de `agentica_native.h`) que tiene lo que usa el bloque: 1.0 para escalares y colecciones, 1.1 cuando cruza una estructura o un enum, 1.2 para un recurso.

Un `doc` es `""` en el registro cuando no hay ninguno, y null en el JSON. Una `signature` es el texto que debe tener la tabla de funciones del módulo, `(List[Float]) -> Optional[Summary]`, y un `shape` es el texto que debe tener su tabla de tipos, `count: Int, mean: Float` o `Empty | Number(Float) | Text(String)`. Los escribe el código con el que el compilador vincula una llamada, así que son los bytes que compara el cargador. Un `shape` es el texto que sigue a `=` en el `{S<index>=...}` o `{E<index>=...}` que escribe el compilador, cuyo `<index>` es el lugar del tipo en el programa y no forma parte de la respuesta.

## Cuerpos de funciones {#function-bodies}

`Analysis.bodies(session, path)` da las funciones de un archivo con sus cuerpos como un árbol con tipos, para una herramienta que los traduce, como un demostrador de teoremas. **Es experimental:** hasta que una primera herramienta lo use, su forma puede cambiar entre versiones sin marcarlo como cambio incompatible, aunque la respuesta tiene una `version`. El archivo se enlaza y se comprueba como para `type_at`, y no necesita `main`. Un nombre de `std/` sin búfer, como `std/binary`, es ese módulo tal como lo lleva el binario, y la respuesta lo nombra `std/binary.agc`. No tiene forma de línea de comandos; `bodies_json` da el JSON de la respuesta, con `command` `bodies`.

Un `Bodies` tiene las `functions` del archivo que tienen cuerpo, también las privadas, en el orden del código fuente, el `prelude`, y los `modules` del programa enlazado, cada uno un `BodyModule` con su `prefix` (el `@N::` con el que empiezan los nombres enlazados de sus declaraciones, `""` para el propio archivo) y su `file`. Un `Body` tiene su `name` tal como se escribió, su `linked` (el nombre al que apunta una llamada), su `file`, `exported`, su `range` y `name_range`, sus `generics`, sus `params`, su `result` y su `body`, una lista de `Node`. Un parámetro tiene `name`, `type`, `range` y `default`: su valor predeterminado como un solo nodo, o una lista vacía. Un parámetro para el que una llamada no da argumento toma su predeterminado: una función del archivo lo tiene en sus `params`, y un integrado, que no tiene `Body`, en los `parameters` de `agentica help NAME --json`, con sus nombres en orden. Un tipo es un `TypeShape`: `kind` es `builtin` (`name` es `Int`, `Bytes`, `List`, `Result`, `Fn`, ...), `struct`, `enum` u `opaque` (`name` es el nombre enlazado), `var` (un parámetro de tipo) o `none` (un nodo sin valor), y `args` son sus argumentos de tipo.

Un `Node` tiene un `kind`, su `type`, su `range`, un `text`, un `target`, `new`, sus `children` (en el orden del código fuente), `type_args` y `prelude`:

- `int`, `float`, `string`, `bool`, `nil`: un literal, con su valor en `text`. `local`: una lectura de un nombre, en `text`.
- `let`: `text = value`, con `new` en verdadero cuando crea una variable local nueva, y en falso cuando cambia una existente. `discard` es `_ = value`.
- `call`: el `target` es lo que resolvió el comprobador: una función por su nombre enlazado, o un integrado, como `Int.shift_left`, `Bytes.length` para `data.size`, `Bytes.at` para `data[i]`, `ok` o `some`. Los hijos son los argumentos, primero el receptor de un método, en el orden en que se ejecutan, que es el orden en que se escribieron: los posicionales llenan los parámetros de izquierda a derecha, cada `name: value` es un nodo `named` (`text` es el parámetro, y su hijo es el valor), y en una llamada con argumentos con nombre, un bloque final también es un nodo `named` (`xs.reduce(initial: 0) do ... end` da `xs`, `named` `initial`, `named` `block`). `type_args` son los tipos que una llamada de una función o de un integrado genérico vincula: uno por parámetro de tipo de la función, en orden, o uno por variable de tipo del integrado, en el orden en que aparecen por primera vez en sus parámetros y luego en su resultado (`xs.map do |x| x.to_s end` sobre un `List[Int]` tiene `Int` y `String`); un tipo que la llamada deja abierto tiene la clase `none`, y en cualquier otro nodo `type_args` es una lista vacía. Un integrado escrito en Agentica (`List.sum`, `Optional.unwrap_or`, `File.foreach`) tiene en `prelude` el nombre enlazado de la función que lo ejecuta para estos tipos (`@prelude::list::sum_int`), y `""` en otro caso. `index` es `target[index]` en un `List` o un `Map`.
- `op`: un operador binario, escrito en `text` como en el código fuente (`+`, `<=`, `==`, `!=`, ...); sus dos hijos tienen sus tipos. `and`, `or`, `not` (`text` `!`) y `neg` (menos unario, `text` `-`) son clases propias. `-9223372036854775808`, que solo cabe bajo su signo menos, es un único nodo `int`.
- `try`, `return` e `interpolation`, cuyos hijos son partes `string` y expresiones con tipo.
- `if`: un `branch` (la condición, y luego un `block`) por cada `if` y `elsif`, luego un `block` para `else`. `case`: el valor, y luego un `arm` por rama: su patrón, un `guard` cuando se escribe, y un `block`. Un `case` que da un valor tiene su tipo, y el último nodo del bloque de cada rama es el valor de esa rama. Un patrón es un `wildcard`, un `literal` o un `variant` (`target` `Shape.Square`, `ok`, `error`, `some` o `none`) cuyos hijos son sus huecos: `bind`, `skip` o un patrón anidado. Una rama de varios patrones (`"ex", "px" ->`) tiene un nodo `alternatives` cuyos hijos son esos patrones.
- `while`: la condición, y luego un `block`. `for`: `text` es la variable, con su tipo, luego el iterable y un `block`. `next` y `break` no tienen hijos.
- `list`: sus elementos. `map`: un `entry` por cada par clave-valor, su clave y luego su valor. `range`: `text` `..` o `...`, y luego sus dos extremos.
- `struct`: `target` es el nombre enlazado de la estructura, y luego un nodo `named` por cada `name: value` tal como se escribió (`text` es el nombre, y su hijo es el valor). `with`: la estructura, y luego sus nodos `named`. `variant` como valor: `target` igual que en un patrón, luego sus argumentos, y un nodo `named` por cada uno con nombre.
- `field`: `text` es el campo, y su hijo es la estructura. `method`: un método que tienen todos los tipos y que no es un integrado (`to_s`, `inspect` de una estructura, `T.members`), `text` es su nombre, luego el receptor y los argumentos.
- `function`: `&name`, con la función o el integrado en `target` y `prelude` como en un `call`. `invoke`: una llamada a un valor de función (`f.call(x)`, `text` `call`, el valor y luego los argumentos) o a un campo `Fn` (`h.run(x)`, `text` el campo, la estructura y luego los argumentos).
- `lambda`: un bloque (`text` `block`) o una lambda (`text` `lambda`): un nodo `param` por cada parámetro (`text` su nombre, con su tipo), y luego un `block`.
- `type`: un tipo usado como valor (`Point.members`), `text` es su nombre. `constant`: una lectura de una constante de módulo, `text` es su nombre enlazado. `regex`: `text` `/body/flags`, y su hijo es la llamada que lo crea. `template`: su hijo es la llamada que crea su texto.

Un `Body` es `pure` cuando ninguna llamada que hace, a través de cada función que llama, tiene un efecto ni lee un estado que otra tarea o el sistema puede cambiar. Un integrado tiene un efecto cuando `agentica help NAME --json` lista uno en sus `effects` (`stdout`, `filesystem`, `network`, ...), y las lecturas de estado compartido también tienen uno: `concurrency` para una lectura de un `ATS` o de un `Channel` y para `ch.lazy`, `filesystem` para `File.foreach` y `File.chunks`, `clock` para `System.Profile.steps`. Así, `+`, `b[i]` y `unwrap!` son puros: pueden detener el programa, pero no hacen nada más. Una llamada a una función de un `extern module` tiene el efecto `native`. Una llamada que puede ejecutar un valor de función tiene el efecto `function-value`: `f.call(x)`, una llamada a un campo `Fn` (`h.run(x)`), un integrado al que se da un valor de función que no es un bloque ni `&name` (`xs.map(f)`), y una operación final de un `Lazy` (`to_a`, `first`, ...), que ejecuta la fuente y los pasos que la hicieron. Una llamada a método que el comprobador no resolvió tiene el efecto `unresolved`. Una referencia `&name` cuenta como una llamada a `name`. `impure` da cada motivo una vez, como un `Reason`: el `effect`, el `call` (un integrado, un nombre de función enlazado, o `call`), su `range`, y `through`, los nombres enlazados de las funciones desde la primera llamada hasta la que hace la llamada (vacío cuando la función la hace ella misma). La llamada está en el archivo del prefijo del último nombre. Las recursiones y los ciclos se siguen una sola vez.

El `prelude` de un `Bodies` tiene esas funciones, cada una una vez, en el orden en que las funciones del archivo las llaman por primera vez, con sus cuerpos, `pure` e `impure` como en cualquier función. Una referencia a un integrado (`&Int.abs`) ejecuta una función que el preludio crea para ella, también listada, desde el archivo `<prelude>/builtin_refs.agc`, que escribe el front end. Las demás tienen el `file` `<prelude>/NAME.agc`, el archivo `std/prelude/NAME.agc` que lleva el binario, y sus tipos genéricos son las letras `A`, `B`, `K` y `V`.

Un `block` va desde su primera sentencia hasta la última. Algunos rangos son aproximados: una parte `string` de una interpolación tiene el rango de la interpolación, un hueco `skip` el de su variante, y una sentencia `if` o `case` llega hasta el inicio de la línea siguiente. Los argumentos de tipo de una llamada a una función genérica todavía no están en la respuesta.

## Errores {#errors}

`outline`, `type_at`, `type_at_partial`, `symbol`, `refs`, `refs_partial`, `native_modules` y `bodies` devuelven un `Result` cuyo mensaje de error es el diagnóstico como un objeto JSON, la forma `--json`, así que `try` funciona. `Analysis.diagnostic` lo lee de vuelta como un `Analysis.Diagnostic`. Los códigos son los de la línea de comandos: `LEX-`, `PARSE-`, `CHECK-` y `PKG-`; `QUERY-NO-EXPRESSION` para una posición que no está en ninguna expresión; `QUERY-NOT-FOUND` para un nombre de `symbol` que nada declara; y `QUERY-USAGE` para un archivo que no se puede leer, una posición con línea o columna menor que 1, o un `symbol` con un nombre vacío o con una ruta que no nombra ningún archivo `*.agc`. Para `outline`, `type_at` y `refs` el diagnóstico nombra el archivo; para `symbol`, su `file` es `<arguments>`, como en la línea de comandos. A diferencia de la línea de comandos, `QUERY-USAGE` no tiene una línea `help` de uso; `QUERY-NOT-FOUND` conserva su `help` (los archivos que no se buscaron).

```agentica {mode="check"}
import Analysis from "std/analysis"

def main() -> Void
  session = Analysis.open(Analysis.workspace())
  session = Analysis.update(session, "app.agc", "def twice(n: Int) -> Int\n  return n * 2\nend\n")
  outline = Analysis.outline(session, "app.agc")
  if outline.ok?
    for item in outline.unwrap!.items
      puts("#{item.kind} #{item.signature}")
    end
  else
    puts(Analysis.diagnostic(outline.message).unwrap!.code)
  end
end
```

## Costo {#cost}

El compilador es parte del programa que importa `std/analysis`: su núcleo puro lo lleva el binario como `std/internal/compiler/`, que es privado, y solo los módulos de `std/` pueden importarlo. Un programa que importa `std/analysis` por eso comprueba y hace el lowering de los archivos de `stdlib/CORE` también cuando se ejecuta desde el código fuente, y el comprobador y el catálogo de integrados que pide son los del binario que lo compiló, congelados en el programa compilado. El binario rechaza un archivo `.agcb` de otra versión de Agentica, así que vuelve a compilar una herramienta después de actualizar agentica. Un programa que se ejecuta a menudo puede pagar el tiempo de compilación una sola vez: `agentica compile tool.agc -o tool.agcb`, y luego `agentica run -- tool.agcb`.
