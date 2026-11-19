---
title: Valores y tipos
weight: 1
description: Los tipos básicos, cómo imprimir valores y la forma del programa.
source_hash: "89bc45625874"
---

## Un programa {#a-program}

Un programa es un archivo de declaraciones. Tiene una sola función `main`, y al ejecutar el archivo se llama a esa función. Los bloques terminan con `end`.

```agentica
def main() -> Void
  puts("one line")
  print("no new line, ")
  puts("then one")
end
```

```output
one line
no new line, then one
```

`#` inicia un comentario que llega hasta el final de la línea. El código no puede ir suelto al principio del archivo, fuera de una función.

Una línea `##` es un comentario de documentación, que se pone justo encima de un `def`, `struct`, `enum`, campo o variante. Es Markdown y no cambia el programa.

```agentica
# An ordinary comment: nothing reads it.
## Adds two numbers.
def add(a: Int, b: Int) -> Int = a + b

def main() -> Void
  puts(add(2, 3)) # a note after code
end
```

```output
5
```

Un bloque `##` al principio de un archivo, seguido de una línea vacía, documenta el módulo. Un bloque `##` que no está justo encima de su destino es `PARSE-DETACHED-DOC`.

## Tipos básicos {#basic-types}

Cada valor tiene un tipo. El comprobador de tipos conoce el tipo de cada expresión antes de que se ejecute el programa.

| Tipo | Valores |
|---|---|
| `Int` | números enteros de 64 bits: `42`, `-7` |
| `Float` | números decimales: `3.14`, `0.5` |
| `Bool` | `true` y `false` |
| `String` | texto: `"hello"` |
| `Nil` | el único valor `nil` |

```agentica
def main() -> Void
  puts(42)
  puts(3.14)
  puts(true)
  puts("hello")
  puts(nil)
end
```

```output
42
3.14
true
hello
nil
```

También hay listas, mapas, estructuras, enums, resultados y [valores opcionales](/library/data-structures/optional/) (`some(value)` o `none`). Las páginas siguientes los muestran.

`type Names = List[String]` da un nombre corto a un tipo largo. No es un tipo nuevo. Los alias no pueden ser constructores ni patrones de enum, y los ciclos se rechazan.

Un alias puede recibir parámetros de tipo. `Matrix[Int]` significa exactamente `List[List[Int]]`, y cada parámetro necesita un argumento:

```agentica
type Matrix[T] = List[List[T]]

def main() -> Void
  rows: Matrix[Int] = [[1, 2], [3]]
  plain: List[List[Int]] = rows
  puts(plain.size)
end
```

```output
2
```

## to_s e inspect {#to_s-and-inspect}

`puts` imprime cualquier valor como su texto `to_s`: las cadenas tal cual, y los demás valores en una forma corta y legible (`[1, 2, 3]`, `{"a": 1}`, `ok(5)`). Una función, una tarea o un manejador, como un `TCP.Listener`, no tiene `to_s`: `f.to_s` es `CHECK-UNKNOWN-METHOD`. `inspect` es la forma de depuración: las cadenas conservan sus comillas.

```agentica
def main() -> Void
  puts(7.to_s)
  puts("hi".to_s)
  puts("hi".inspect)
  puts([1, 2].to_s)
end
```

```output
7
hi
"hi"
[1, 2]
```

`IO.inspect` imprime la forma de depuración y devuelve el valor, así que puedes ponerlo en medio de una expresión:

```agentica
def main() -> Void
  total = IO.inspect(2 + 3) * 10
  puts(total)
end
```

```output
5
50
```

## Sin conversión implícita {#no-implicit-conversion}

Los tipos nunca cambian solos. `1 + 2.5` es un error: convierte antes.

```agentica
def main() -> Void
  puts(1.to_f + 2.5)
  puts("n = " + 4.to_s)
end
```

```output
3.5
n = 4
```

## Sin truthiness {#no-truthiness}

`if` necesita un `Bool`. `0`, `""` y `nil` no son falsos; usarlos como condición es un error del comprobador.

```agentica {expect="CHECK-TYPE-MISMATCH"}
def main() -> Void
  if 1
    puts("never")
  end
end
```

## Los valores nunca cambian {#values-never-change}

Los valores son inmutables. Un método da un valor nuevo y deja el anterior como estaba. Asigna el resultado para conservarlo.

```agentica
def main() -> Void
  xs = [1, 2]
  ys = xs.push(3)
  puts(xs)
  puts(ys)
end
```

```output
[1, 2]
[1, 2, 3]
```
