# Performance rules

Read this when a program is slow, a loop runs over 100,000 items or about 1 MB,
or you choose between `while`, blocks, `.with`, `Set`, `Map` and `List` on a hot
path. Clear code comes first: change a function for speed only when a profile
shows that it is hot, and keep the change only if the measurement improves.

The costs, the profiler and its report are in `agentica-programming`
`references/performance.md`; this file adds the bad/good code. Times are wall
milliseconds unless stated. A figure tagged `[here]` was run for this skill
(release VM 0.4.0, 2026-10-16, one run). Wall time varies from run to run; VM
steps do not.

## Measure first

`AGENTICA_VM_TRACE=profile agentica FILE.agc` prints a report on stderr when the
run ends, with a row per function, file and builtin. Time a piece of code with
`Time.monotonic_ns()` around it.

- Steps repeat exactly, so compare steps. A profiled run is about a third
  slower, so time the real run without the profiler.
- Find the work done for each item before you change anything: a closure called
  for each character, a table built on each call, a call for each token.

## Tables built once

A table that does not depend on the arguments is a module constant. It is built
once before `main`, and a read is one array access. Build it in the function
only when it depends on the input.

```ruby
# bad
def count_vowels(text: String) -> Int
  vowels = Set.new(["a", "e", "i", "o", "u"])
  total = 0
  for c in text.split("")
    if vowels.include?(c)
      total += 1
    end
  end
  return total
end
```

```ruby
# good
VOWELS = Set.new(["a", "e", "i", "o", "u"])

def count_vowels(text: String) -> Int
  total = 0
  for c in text.split("")
    if VOWELS.include?(c)
      total += 1
    end
  end
  return total
end
```

A `Set` test beats a chain of comparisons (185 against 400 ms on 900,000
characters).

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

A key-to-value `if` chain is a `Map` constant read with `get`.

```ruby
# good
NAMES = {"r": "red", "g": "green", "b": "blue"}

def color_name(letter: String) -> String
  return NAMES.get(letter, "unknown")
end
```

## Struct updates

`value.with(field: x)` copies a struct in one instruction; a constructor call
writes every field. `.with` costs more than the constructor at 2 fields and less
from 4 fields up (15% to 34% at 4 to 16). It still copies every field: do it
once per token or node, not once per character.

## Collections and strings

- Build text with `push` and one `join`, not `s = s + piece` in a loop, which
  copies the text each time. Appending `"ab"` n times [here]:

| n | `s = s + "ab"` | `push` then `join` |
|---:|---:|---:|
| 25,000 | 483 | 18 |
| 50,000 | 1,810 | 33 |
| 100,000 | 6,112 | 96 |

```ruby
# bad
def repeat_text(n: Int) -> String
  s = ""
  i = 0
  while i < n
    s = s + "ab"
    i += 1
  end
  return s
end
```

```ruby
# good
def repeat_text(n: Int) -> String
  parts: List[String] = []
  i = 0
  while i < n
    parts = parts.push("ab")
    i += 1
  end
  return parts.join("")
end
```

- A table keyed by dense `Int` ids (node ids, indexes) is faster as a `List`
  indexed by id (`List.repeat` once, then `set` and `[]`) than as a `Map[Int,
  T]` (a checker that kept types in a list instead of a map went from 1.83 s to
  1.24 s on a 630,000 character program). `List.repeat` halts above 1,048,576
  items, so build a bigger list from several repeats.

```ruby
# good
def squares(n: Int) -> List[Int]
  table = List.repeat(0, n)
  i = 0
  while i < n
    table = table.set(i, i * i)
    i += 1
  end
  return table
end
```
