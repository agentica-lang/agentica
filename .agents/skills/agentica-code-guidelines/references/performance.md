# Performance rules

Read this when you choose between `while`, blocks, `.with`, `Set`, `Map` and
`List` on a hot path. Clear code comes first: change a function for speed only
when a profile shows that it is hot, and keep the change only if the
measurement improves.

The costs, the profiler and its report are in `agentica-programming`
`references/performance.md`; this file adds the bad/good code. Find the work
done for each item before you change anything: a closure called for each
character, a table built on each call, a call for each token.

## Tables built once

A table that does not depend on the arguments is a module constant: built once
before `main`, read with one array access. A `Set` test also beats a chain of
comparisons.

```ruby
# bad
def vowel?(c: String) -> Bool
  return c == "a" or c == "e" or c == "i" or c == "o" or c == "u"
end
```

```ruby
# good
VOWELS = Set.new(["a", "e", "i", "o", "u"])

def vowel?(c: String) -> Bool
  return VOWELS.include?(c)
end
```

A key-to-value `if` chain is a `Map` constant read with `get`:
`NAMES.get(letter, "unknown")`.

## Strings and dense tables

Build text with `push` and one `join`; `s = s + piece` in a loop copies the
text each time (quadratic: 6,112 ms against 96 ms for 100,000 appends; release
VM 0.4.0, one run).

```ruby
# bad
s = s + "ab"
```

```ruby
# good
parts = parts.push("ab")    # in the loop
return parts.join("")       # once, after it
```

A table keyed by dense `Int` ids (node ids, indexes) is faster as a `List`
indexed by id (`List.repeat` once, then `set` and `[]`) than as a `Map[Int, T]`.
`List.repeat` halts above 1,048,576 items, so build a bigger list from several
repeats.

`value.with(field: x)` pays from 4 fields up (programming skill,
`references/performance.md`); it still copies every field, so do it once per
token or node, not once per character.
