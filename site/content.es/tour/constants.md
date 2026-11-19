---
title: Constantes
weight: 14
description: Da nombre a un valor fijo una vez al principio de un archivo, construye una tabla una sola vez y compártela entre archivos.
source_hash: "7cdf4fd7252f"
---

## Un valor fijo durante la ejecución {#a-value-fixed-for-the-run}

Una constante es un nombre en mayúsculas en el nivel superior de un archivo, con un valor después de `=`. Nunca cambia, y cualquier función del archivo puede leerla:

```agentica
SECONDS_PER_DAY = 24 * 60 * 60
GREETING = "hello"

def main() -> Void
  puts("#{GREETING}: #{SECONDS_PER_DAY}")
end
```

```output
hello: 86400
```

Un nombre tiene letras mayúsculas, dígitos y `_`, y al menos dos caracteres (`LIMIT`, `MAX_DEPTH`). Otra escritura es `PARSE-CONSTANT-NAME`:

```agentica {expect="PARSE-CONSTANT-NAME" fmt="off"}
MaxDepth = 8

def main() -> Void
  puts(MaxDepth)
end
```

- Las constantes van después de las importaciones y antes de los tipos y las funciones, sin línea vacía entre ellas.
- Indica un tipo como en una asignación (`RATIO: Float = 1.5`). También da tipo a `[]` y `{}`.

## Construye una tabla una sola vez {#build-a-table-once}

Una función que construye una lista o un mapa ejecuta el código cada vez que se llama. Una constante se construye una sola vez, antes de `main`, y cada lectura da el mismo valor:

```agentica
PRICES = {"tea": 3, "cocoa": 5}
FRUITS = Set.new(["kiwi", "apple"])

def kind(name: String) -> String
  return "fruit" if FRUITS.include?(name)

  "drink"
end

def main() -> Void
  puts(PRICES.get("cocoa", 0))
  puts(kind("kiwi") + " " + kind("tea"))
end
```

```output
5
fruit drink
```

- Una constante funciona como cualquier valor: `PRICES.get(...)`, `PRICES["tea"]`, `FRUITS.size`.
- Una constante puede leer otra, por encima o por debajo de ella. Un ciclo es `CHECK-CONSTANT-CYCLE`.

## Cuándo se construye una constante {#when-a-constant-is-built}

- Un literal, como `WIDTH = 8`, es parte del programa.
- Cualquier otra constante se construye una sola vez, antes de `main`, y solo si una función que `main` puede alcanzar la lee. Una constante que nadie lee nunca se ejecuta.
- Si un inicializador falla, el programa se detiene antes de que `main` imprima nada:

```agentica {expect="RUNTIME-INDEX-OUT-OF-RANGE"}
BAD = [1][5]

def main() -> Void
  puts("never printed")
  puts(BAD)
end
```

La traza de pila menciona `BAD`.

## Qué puede contener una constante {#what-a-constant-may-hold}

- Puede contener literales, listas, mapas, conjuntos, valores de estructura y enum, operadores, otras constantes e integradas sin efectos (`Set.new`, `map`, `reduce`, ...).
- Llamar a una función propia, un valor de función, un bucle `while` o una función integrada que lee o escribe en el mundo es `CHECK-CONSTANT-EXPRESSION`:

```agentica {expect="CHECK-CONSTANT-EXPRESSION"}
LINE = IO.gets!()

def main() -> Void
  puts(LINE)
end
```

- Su tipo es números, texto, listas, mapas, conjuntos, rangos, `Result`, o estructuras y enums de esos. Un canal, una tarea o una función es `CHECK-CONSTANT-TYPE`. La única excepción es un inicializador completo `ATS.new()`, una tabla que comparten todas las tareas ([una tabla constante](/library/concurrency/ats/#a-constant-table)).
- Nada asigna un valor a una constante: `LIMIT = 2` dentro de una función es `PARSE-INVALID-ASSIGNMENT-TARGET`.

## Compartir una constante entre archivos {#share-a-constant-between-files}

Una constante por encima de `private` (o en un archivo sin `private`) es pública, y el archivo que importa la trae por nombre, como una función o una estructura:

```agentica {file="limits.agc"}
MAX = 100
NAMES = ["x", "y"]
```

```agentica
import {MAX, NAMES as LABELS} from "limits"

def main() -> Void
  puts(MAX)
  puts(LABELS.size)
end
```

```output
100
2
```

Un archivo que importa el módulo con un alias lee la constante como `Limits.MAX`, igual que una función exportada:

```agentica
import Limits from "limits"

def main() -> Void
  puts(Limits.MAX)
  puts(Limits.NAMES.size)
end
```

```output
100
2
```

Una constante que el módulo deja privada es `CHECK-IMPORT-NAME`, igual que en una función.
