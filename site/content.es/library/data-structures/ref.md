---
title: Ref
weight: 9
description: Un token único en la ejecución, de Ref.new, para dar identidad a un valor.
source_hash: "4fb8ea041338"
---

Un `Ref` es un token que ningún otro `Ref` de la ejecución es igual a, como `make_ref()` en Erlang y Elixir. Los valores se comparan por su estructura, así que dos valores iguales son un solo valor; pon un `Ref` en un campo para distinguir valores que por lo demás son iguales, como dos nodos de un grafo con la misma operación y los mismos argumentos.

- `==` y `!=` comparan Refs: un Ref es igual solo a sí mismo.
- Un Ref es una clave de `Map`, un elemento de `Set`, una clave de `ATS` y un elemento de `uniq`, `tally` y `group_by`.
- `sort` y `sort_by` ordenan los Refs por el momento en que se crearon: un Ref creado después de otro se ordena después de él, en la misma tarea o en una tarea que recibió el primero por un canal o por `Task.await`. Así, cuando cada valor se crea después de los valores que usa, ordenar sus Refs da un orden topológico.
- Un Ref es un dato: un campo de estructura, un payload de enum, un elemento de lista, un mensaje de canal o un valor de `ATS`.
- Un Ref se imprime como `<Ref 1>`, el número de su creación en la ejecución, para depurar. Ninguna función convierte un número o un texto en un Ref, y un Ref no tiene aritmética, `<`, conversión a `Int` ni forma JSON (`CHECK-TYPE-MISMATCH`, `CHECK-NOT-ENCODABLE`).
- `Ref` no es un nombre reservado: un archivo que declara o importa su propio tipo `Ref` (como `std/actor`) se refiere a ese tipo cuando escribe `Ref`, y `Ref.new()` sigue creando un token.

## Ref.new {#refnew}

```signature
Ref.new() -> Ref
```

Devuelve un Ref nuevo. Las tareas en cualquier hilo de planificador crean Refs a la vez, sin un bloqueo, y cada uno es distinto de todos los demás Refs de la ejecución.

```agentica
struct Node
  id: Ref
  name: String
end

def main() -> Void
  a = Node(id: Ref.new(), name: "a")
  b = Node(id: Ref.new(), name: "a")
  puts(a == b)
  puts(a == a)
  seen = Set.new([a.id])
  puts(seen.include?(b.id))
  puts([b, a].sort_by { |n| n.id } == [a, b])
  puts(a.id)
end
```

```output
false
true
false
true
<Ref 1>
```
