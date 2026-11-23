---
title: Ref
weight: 9
description: A token unique in the run, from Ref.make, to give a value an identity.
---

A `Ref` is a token that no other `Ref` of the run equals, like `make_ref()` in Erlang and Elixir. Values are compared by structure, so two equal values are one value; put a `Ref` in a field to tell apart values that are otherwise equal, such as two nodes of a graph with the same operation and arguments.

- `==` and `!=` compare Refs: a Ref equals only itself.
- A Ref is a `Map` key, a `Set` element, an `ATS` key, and an item of `uniq`, `tally` and `group_by`.
- `sort` and `sort_by` order Refs by when they were made: a Ref made after another sorts after it, in the same task or in a task that got the first one through a channel or `Task.await`. So when each value is made after the values it uses, sorting their Refs gives a topological order.
- A Ref is data: a struct field, an enum payload, a list item, a channel message or an `ATS` value.
- A Ref prints as `<Ref 1>`, the number of its creation in the run, for debugging. No function turns a number or a text into a Ref, and a Ref has no arithmetic, no `<`, no conversion to `Int` and no JSON form (`CHECK-TYPE-MISMATCH`, `CHECK-NOT-ENCODABLE`).
- `Ref` is not a reserved name: a file that declares or imports its own type `Ref` (such as `std/actor`) means that type when it writes `Ref`, and `Ref.make()` still makes a token.

## Ref.make

```signature
Ref.make() -> Ref
```

Returns a new Ref. Tasks on any scheduler thread make Refs at once without a lock, and each one differs from every other Ref of the run.

```agentica
struct Node
  id: Ref
  name: String
end

def main() -> Void
  a = Node(id: Ref.make(), name: "a")
  b = Node(id: Ref.make(), name: "a")
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
