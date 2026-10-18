# Performance rules

Read this when a program is slow, a loop runs over 100,000 items or about 1 MB,
or you choose between `while`, blocks, `.with`, `Set`, `Map` and `List` on a hot
path. Clear code comes first: change a function for speed only when a profile
shows that it is hot, and keep the change only if the measurement improves.

Every figure here was measured on the release VM. A tag says where: `[PR #255]`
and `[PR #317]` are Agentica pull requests (the lexer rewrite and the lexer step
cuts), `[bench]` is the VM benchmark notes of the repository, `[here]` is a run
made when this skill was written (release VM 0.4.0, 2026-10-16, one run). Times
are wall milliseconds unless stated. Wall time varies from run to run; VM steps
do not.

## Measure first

```ruby
# good
def work() -> Int
  return 1
end

def main() -> Void
  start = Time.monotonic_ns()
  work()
  ms = (Time.monotonic_ns() - start) / 1000000
  puts("#{ms} ms")
end
```

`AGENTICA_VM_TRACE=profile agentica FILE.agc` prints a report on stderr when the
run ends (`agentica FILE.agc` prints two reports, the front end's first, the
program's second; `AGENTICA_VM_TRACE_FILE=PATH` writes it to a file). The first
line is `total wall_ms= steps= calls= builtin_calls= builtin_ms= gc_ms=
collections=`, then rows per function (`fn calls= steps= name= at=FILE:LINE`; a
block is `block@FILE:LINE:COL`), per file and per builtin (`builtin calls= us=
name=`).

- Steps repeat exactly, so compare steps. A profiled run is about a third
  slower, so use the builtin rows to rank builtins and time the real run without
  the profiler [PR #317].
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

A `Set` test beats a chain of comparisons. On 900,000 characters a `Set[String]`
test took 185 ms against 400 ms for an `or` chain of five comparisons, and a
`Set[Int]` test 205 ms against 305 ms (three runs). The `name_char?` chain of
the old lexer cost about 680 ns per character, a `Set` loop 250 ns [PR #255].

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

## Scanning text

- `text.split("")` gives a `List[String]` of characters. Keep that list when you
  scan the text more than once. `Set[String]` tests cost as much as `Set[Int]`
  tests (177 and 184 ms for 1,000,000 tests), so do not turn characters into
  codes only for a set [PR #317].
- For one pass, `String.code(text.at(i))` is enough. On 1M ASCII characters:
  building the codes once with `text.split("").map do |c| String.code(c) end`
  took 129 to 134 ms, a `while` over `codes[i]` 163 to 165 ms, and a `while`
  with `String.code(text.at(j))` 283 ms (two runs). One build plus one indexed
  pass costs about what one `at` pass costs, so keep the list when you scan
  twice or move back and forth.
- `String.at` and `String.slice` count characters: O(1) on ASCII text. With
  multi-byte characters each call walks from the nearest of the start, the end
  or the last position used, so a forward scan is cheap and a random access can
  cost O(n).
- The lengths of `text.split("\n")` find the end of a line without scanning its
  characters (a CR ends a line too, and needs the scan).
- A sentinel after the last element (`""` or `-1`, in no set) takes the `i <
  size` test out of the scan loop. A scan loop `while set.include?(chars[i])`
  costs 9 steps for each character [PR #317].

## Loops

- A `while` over an index with mutable locals beats a tail-call `step(state)`
  loop that updates a struct with `.with`: 3% to 6% less time on the lexer
  tables (29.2 against 31.0 ms, 1,664 against 1,741, 910 against 939, 771
  against 815) [PR #255].
- A call costs several steps (the arguments and the return). On a path that runs
  once per token, move the rare work into helper functions and keep the common
  arms in the loop. The lexer went from 52 to 24 steps for each character by
  moving its hot arms into one function, its tables into constants and the text
  into `split("")` [PR #317]. Inlining one helper alone cut only 2.1%, so find
  what each item costs first.
- Keep a value that is used again in a local: the lexer's column as `index +
  column_base`, and the top and depth of its bracket stack in two locals instead
  of a list read, took about 2% and 3% off its steps [PR #317].
- In a profile, a `<native>` row is the steps of a range loop such as
  `(0...n).each`, one for each item; the block's own steps are on its `block@`
  row. A list's `each` and `map` add no `<native>` steps.
- Mutual tail calls run to depth 1,000,000 when each function ends in `return`
  of the other. The VM allows 10,000 frames of other recursion, so loop or use
  an explicit stack for input-sized depth.

## Struct updates

`value.with(field: x)` copies a struct in one instruction; a constructor call
writes every field. For 1,000,000 updates in a `while` loop [bench]:

| Struct and update | Constructor | `.with` |
|---|---:|---:|
| 2 fields, 1 changed | 197 | 212 |
| 4 fields, 1 changed | 289 | 240 |
| 8 fields, 1 changed | 380 | 280 |
| 16 fields, 1 changed | 567 | 373 |

An empty loop is about 110 ms of each row. `.with` takes about 8% longer than
the constructor at 2 fields and 15% to 34% less at 4 to 16 fields, so use it
from 4 fields up. It still copies every field: do it once per token or node, not
once per character.

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

- `List.push` (`List.append`) takes near constant time, so n pushes build a list
  in O(n). `List.concat(a, b)` costs O(length of b) when b has at most 32 items,
  else O(length of a + b).
- `Map` and `Set` lookups and inserts (`get`, `put`, `include?`, `add`) take
  effectively constant time (one 32-way HAMT). List indexing is O(log32 n), at
  most four steps for a million items.
- A table keyed by dense `Int` ids (node ids, indexes) is faster as a `List`
  indexed by id (`List.repeat` once, then `set` and `[]`) than as a `Map[Int,
  T]`. `List.set` took about 1.6 microseconds and `Map.put` about 5 at 5,000
  entries; a checker that kept types in a list instead of a map went from 1.83 s
  to 1.24 s on a 630,000 character program [measured under load, with other jobs
  running]. `List.repeat` halts above 1,048,576 items, so build a bigger list
  from several repeats.

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

- `Set.new` costs about 7 to 10 microseconds per element, and the cost rises
  with size: 100,000 items took 0.69 s, 200,000 1.18 s, 400,000 3.05 s,
  1,000,000 10.3 s (one run each). One `include?` costs about 0.2 microseconds,
  so an element of a `Set.new` costs 30 to 50 lookups. Build a large set once
  and keep it.
- A builtin runs to the end of its turn, except the resumable ones (`map`,
  `filter`, `reduce`, `each`, `any?`, `all?`, `sort_by`). A 10-second `Set.new`
  stalls every other task, so keep big builds out of code that other tasks wait
  on.
