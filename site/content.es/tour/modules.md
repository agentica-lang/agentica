---
title: Módulos e importaciones
weight: 13
description: Divide un programa en archivos, haz públicas las declaraciones y usa la biblioteca estándar.
source_hash: "418ed0ef861b"
---

## Un archivo, un módulo {#one-file-one-module}

Cada archivo `.agc` es un módulo. Todas las declaraciones son públicas, así que otros archivos pueden usarlas, salvo las que van después de una línea `private`, que quedan privadas al archivo.

Guarda esto como `shapes.agc`:

```agentica {file="shapes.agc"}
struct Square
  side: Int
end

def area(s: Square) -> Int = s.side * s.side

private

def secret() -> Int = 42
```

`private` va sola en su línea, con una línea en blanco antes y después, una vez por archivo. Las importaciones nunca son públicas. Un archivo sin `private` es público por completo. `export` antes de una declaración es un error (`PARSE-UNEXPECTED-TOKEN`); solo queda `export Alias.name`, para reexportar un nombre.

## Disposición del archivo {#file-layout}

Cada archivo lista sus declaraciones en este orden (si no, `CHECK-DECL-ORDER`):

```text
# module doc and imports
# the public part:
#   constants and re-exports (see Constants and Re-exports)
#   struct, enum, type alias, module block and extern block with a resource or a struct (its defs too), in any order
#   def
# private
# the private part, in the same order: constants, then types and blocks, then def
```

Va una línea en blanco antes de cada declaración, salvo la primera.

Una estructura después de una función privada da `CHECK-DECL-ORDER`:

```agentica {expect="CHECK-DECL-ORDER"}
def main() -> Void
  puts(secret())
end

private

def secret() -> Int = 42

struct Box
  value: Int
end
```

## Importar un archivo {#import-a-file}

`import` carga un archivo y le da un nombre, el alias. Usa el alias delante de cada nombre de ese archivo.

```agentica
import Shapes from "shapes"

def main() -> Void
  s = Shapes.Square(side: 3)
  puts(Shapes.area(s))
end
```

```output
9
```

Las rutas son relativas al archivo que importa y no llevan la extensión `.agc`: `"shapes"` carga `shapes.agc`. Los alias empiezan con mayúscula. Llamar a una función privada es un error:

```agentica {expect="CHECK-IMPORT-NAME"}
import Shapes from "shapes"

def main() -> Void
  puts(Shapes.secret())
end
```

## Tipos y enums de un módulo {#types-and-enums-from-a-module}

Los tipos importados también usan el alias: en las anotaciones, en la construcción y en los patrones.

```agentica {file="status.agc"}
enum Status
  Active
  Banned(String)
end
```

```agentica
import S from "status"

def show(s: S.Status) -> String
  case s
    S.Status.Active -> "active"
    S.Status.Banned(why) -> "banned: #{why}"
  end
end

def main() -> Void
  puts(show(S.Status.Banned("spam")))
end
```

```output
banned: spam
```

Un alias de tipo transparente puede ser público e importarse de la misma forma. Por ejemplo, `type Names = List[String]` se usa como `S.Names` o se importa con `import {Names} from "status"`. Un alias genérico como `type Matrix[T] = List[List[T]]` funciona igual: `S.Matrix[Int]`, o `Matrix[Int]` después de `import {Matrix} from "status"`.

## Importar nombres {#import-names}

`import Alias from "path"` le da al archivo el alias `Alias`. Para no usar alias, pon entre llaves los nombres exportados que quieras y úsalos sin prefijo:

```agentica
import {Square, area} from "shapes"

def main() -> Void
  s = Square(side: 3)
  puts(area(s))
end
```

```output
9
```

Esto funciona con funciones, estructuras, enums y constantes. Para un enum, importa el enum, no sus variantes: sus valores y patrones mantienen el nombre del enum delante.

```agentica
import {Status} from "status"

def show(s: Status) -> String
  case s
    Status.Active -> "active"
    Status.Banned(why) -> "banned: #{why}"
  end
end

def main() -> Void
  puts(show(Status.Banned("spam")))
end
```

```output
banned: spam
```

Una entrada puede cambiar de nombre con `as`. Un tipo conserva un nombre con mayúscula, y una función uno en minúscula (`CHECK-IMPORT-RENAME`). Cambiar el nombre también permite importar dos módulos que exportan el mismo nombre:

```agentica
import {Square as Box, area as box_area} from "shapes"

def main() -> Void
  puts(box_area(Box(side: 4)))
end
```

```output
16
```

Un nombre que el módulo no exporta, o que mantiene privado, es un error en la importación:

```agentica {expect="CHECK-IMPORT-NAME"}
import {Square, secret} from "shapes"

def main() -> Void
  puts(secret())
end
```

Un nombre importado no puede chocar con una declaración, un alias, otra importación ni un integrado (`CHECK-REDEFINED-NAME`). Una misma ruta puede aparecer en dos importaciones, una con alias y otra con nombres. Un módulo importado solo por nombres no tiene alias.

Un alias de importación que el archivo nunca usa es un error en el alias (`CHECK-UNUSED-IMPORT`); quita la importación. Un literal de expresión regular cuenta como uso de la importación de `std/regex`, y una plantilla `<<~EAG` como uso de la importación de `std/eag`. Los comandos de consulta, como `type-at` y `symbol`, no lo reportan en el archivo por el que se les pregunta (los archivos que importa siguen la misma regla). Un alias escrito sin miembro, como `x: Shapes`, es `CHECK-IMPORT-NAME`. Los nombres sin usar de una lista de importación no se reportan.

Solo el archivo principal necesita `main`. Los archivos importados no tienen código de nivel superior, así que importar un archivo nunca ejecuta nada.

## Reexportaciones {#re-exports}

Un módulo puede pasar un nombre que importa con `export Alias.name`, así un pequeño archivo de fachada reúne la API de varios archivos. Guarda esto como `geometry.agc`:

```agentica {file="geometry.agc"}
import Shapes from "shapes"

export Shapes.Square
export Shapes.area
```

Quien importa ve la declaración original: `Geometry.Square` y `Shapes.Square` son un solo tipo, y `&Geometry.area` y `&Shapes.area` son una sola función.

```agentica
import Geometry from "geometry"

def main() -> Void
  puts(Geometry.area(Geometry.Square(side: 5)))
end
```

```output
25
```

El alias debe ser una importación del archivo, y el módulo debe exportar el nombre (`CHECK-IMPORT-NAME`). El nombre no debe ser una declaración, otra reexportación ni un alias de importación del archivo (`CHECK-REDEFINED-NAME`). No hay `as` ni comodín: una fachada que quiera otro nombre escribe una función envoltorio. Una reexportación no añade ningún nombre local, así que dentro de la fachada el nombre sigue siendo `Shapes.area`. Las reexportaciones siguen a las importaciones, y una que va después de una declaración necesita una línea en blanco (`PARSE-MISSING-BLANK-LINE`).

## Bloques de módulo {#module-blocks}

`module Name ... end` agrupa declaraciones bajo un nombre, así un archivo puede tener varios módulos. Un bloque tiene constantes, estructuras, enums, alias de tipo y funciones con las reglas de disposición de un archivo, incluida su propia línea `private`: lo que está encima del bloque es visible desde fuera, y un bloque sin `private` es público por completo. Guarda esto como `agents.agc`:

```agentica {file="agents.agc"}
module Counter
  LIMIT = 100

  enum Msg
    Add(Int)
    Get
  end

  def start(initial: Int) -> Int = step(initial, Msg.Add(1))

  private

  def step(count: Int, msg: Msg) -> Int
    case msg
      Msg.Add(n) -> count + n
      Msg.Get -> count
    end
  end
end

module Greeter
  def hello(name: String) -> String = "hello #{name}, up to #{Counter.LIMIT}"
end
```

Dentro de un bloque, sus propios nombres van sin prefijo, y también se ven las importaciones, los nombres de nivel superior y los demás bloques del archivo. Fuera, escribe primero el nombre del bloque. `import {Counter} from "agents"` importa un bloque público como un alias, y `import Agents from "agents"` lo lee como `Agents.Counter`:

```agentica
import {Counter, Greeter} from "agents"
import Agents from "agents"

def main() -> Void
  puts(Counter.start(1))
  puts(Greeter.hello("Ana"))
  msg = Agents.Counter.Msg.Add(2)
  puts(Agents.Counter.start(0) + Counter.LIMIT)
  puts(msg == Counter.Msg.Add(2))
end
```

```output
2
hello Ana, up to 100
101
true
```

Un nombre privado de un bloque es `CHECK-IMPORT-NAME`, igual que un nombre privado de un archivo:

```agentica {expect="CHECK-IMPORT-NAME"}
import {Counter} from "agents"

def main() -> Void
  puts(Counter.step(1, Counter.Msg.Get))
end
```

El nombre de un bloque sigue las reglas de un alias de importación (`CHECK-REDEFINED-NAME`). Un bloque va en el nivel superior, junto con las estructuras y los enums (un bloque dentro de otro bloque es `PARSE-NESTED-MODULE`), y no contiene importaciones, reexportaciones ni bloques extern. Un bloque después de la línea `private` del archivo es privado a ese archivo. Dentro de un bloque, un nombre que el archivo ya declara o importa da `CHECK-SHADOWED-NAME` (un nombre significa una sola cosa), y `main` da `CHECK-MAIN`. Dos bloques pueden tener cada uno un `start`.

## La biblioteca estándar {#the-standard-library}

Las rutas que empiezan con `std/` cargan la biblioteca estándar que viene con Agentica. `std/queue` es una cola de cadenas en la que sale primero lo que entró primero:

```agentica
import Queue from "std/queue"

def main() -> Void
  q = Queue.new()
  q = Queue.push(q, "first")
  q = Queue.push(q, "second")
  case Queue.pop(q)
    ok(popped) ->
      puts(popped.value)
      puts(Queue.size(popped.remaining))
    error(message) -> puts(message)
  end
end
```

```output
first
1
```

Consulta [Queue](/library/data-structures/queue/) para cada función.

## Otras bibliotecas {#other-libraries}

Las rutas que empiezan con `pkg/` cargan bibliotecas instaladas: `import Tools from "pkg/acme/tools"` busca `acme/tools.agc` en `agc_libs/`, junto al programa principal, y luego en las carpetas de `AGENTICA_PATH` y en las carpetas de bibliotecas del usuario y del sistema ([orden de búsqueda](/reference/modules/#standard-library-and-external-libraries)).

## Paquetes {#packages}

Un paquete es un repositorio git de archivos `.agc`. Un proyecto con un `agentica.toml` junto a su archivo principal, o en una carpeta superior, puede importar los paquetes que declara el manifiesto. Cada dependencia tiene un nombre local y un solo fijado, un `tag` o un `ref` (un commit):

```toml
name = "notes"

[dependencies]
sqlite = { git = "https://github.com/owner/sqlite-ac", tag = "v1.2.0" }
json5 = { git = "https://gitlab.com/someone/json5", ref = "3f2a9c1" }
```

Importa un paquete por su nombre local, y luego una ruta dentro del paquete, sin `.agc`:

```text
import Sqlite from "pkg/sqlite/db"
```

Un manifiesto que declara dependencias necesita un `agentica.lock` a su lado, con el commit exacto y un hash de cada paquete. Una compilación nunca descarga nada: lee cada paquete de `deps/<name>/` y comprueba su hash. Tres comandos mantienen `deps/` y el bloqueo, a través del `git` del sistema:

- `agentica install` descarga en `deps/` lo que nombra el bloqueo; nunca cambia el bloqueo.
- `agentica add NAME URL --tag TAG` (o `--ref COMMIT`, `--subdir DIR`, `--workspace`) añade una dependencia a `agentica.toml`, al bloqueo y a `deps/`. `OWNER/REPO` en lugar de la URL es `https://github.com/OWNER/REPO`, y los archivos guardan la URL completa; otra fuente es `PKG-SOURCE-INVALID`. Un tag `NAME-X.Y.Z` sin `--subdir` toma la carpeta `NAME` del repositorio cuando el paquete está ahí y no en su raíz.
- `agentica update [NAME]` vuelve a descargar los fijados por tag y repara un bloqueo desactualizado.

```sh
agentica install
agentica add sqlite https://github.com/owner/sqlite-ac --tag v1.2.0
agentica add jobs agentica-lang/packages --tag jobs-0.1.0
agentica update sqlite
```

Un repositorio de paquetes que tiene una tabla `[workspace]` en la raíz de su `agentica.toml` puede ser una sola dependencia, con `workspace = true`. El proyecto bloquea e instala cada miembro, e importa uno como `pkg/NAME/MEMBER/MODULE`, así los nombres de los miembros nunca chocan con los nombres que usa el proyecto:

```toml
[dependencies]
finn = { git = "https://github.com/owner/finn", tag = "finn-1", workspace = true }
```

```text
import Core from "pkg/finn/core/agent"
```

Dentro del espacio de trabajo, un miembro que depende de otro miembro del mismo repositorio recibe el del espacio de trabajo, con el fijado del espacio de trabajo, sea cual sea el fijado que escriba.

Una dependencia que solo usan las pruebas, como un paquete de pruebas de propiedades, lleva `group = "test"` (`agentica add NAME URL --tag TAG --group test` la escribe). El proyecto la bloquea e instala, pero solo sus archivos `*_test.agc` y su programa de pasos la importan; cualquier otro programa que la importe se detiene con `CHECK-IMPORT-PACKAGE`. Un proyecto que depende de tu paquete nunca la descarga.

```toml
[dependencies]
prop = { git = "https://github.com/owner/prop", tag = "v1.0.0", group = "test" }
```

Un manifiesto puede nombrar la versión más antigua de Agentica que necesita, `agentica = "0.31.0"`; una versión anterior detiene `install`, `check`, `run` y `test` con `PKG-AGENTICA-TOO-OLD`.

Los problemas se reportan con códigos `PKG-`. Los espacios de trabajo, las dependencias `path` y `override`, las bibliotecas nativas y los módulos hechos en C, las tablas `[style]` y `[tool.NAME]`, y cada límite y código están en la [referencia de módulos](/reference/modules/). El código nativo está en [Código nativo](/library/io-and-system/native/).
