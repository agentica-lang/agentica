# Performance

Measured costs for fast `.agc` code. The figures were run on the release VM
on 2026-10-15, one run each unless a count is given. Tags such as `[PR #255]`
and `[bench]` only name where a figure was first published (the merged PR's
description, `docs/vm-benchmarks.md`); the figures stand in this text. Times
are wall milliseconds unless stated.

Time a piece of code inside the program:

```ruby
start = Time.monotonic_ns()
work()
ms = (Time.monotonic_ns() - start) / 1000000
```

## Lookup tables

Build a `Set` or `Map` once per call, then test it with `include?` or `get`,
instead of a chain of comparisons. On 900,000 characters, a `Set[String]` test
took 185 ms against 400 ms for an `or` chain of five comparisons, and a
`Set[Int]` test took 205 ms against 305 ms [measured, three runs].

The lexer rewrite of PR #255 cut time by 13% to 32% against master. That gain
is the whole rewrite (tables and a `while` loop), not the tables alone: 1 MB of
strings 1,241 to 910; 1 MB of identifiers 1,127 to 771; 1 MB of mixed source
1,918 to 1,664; gherkin (18.5 KB) 33.4 to 29.2 [PR #255]. The old
`name_char?` chain cost about 680 ns per character, against 250 ns for a
`Set` loop [PR #255].

```ruby
def count_vowels(text: String) -> Int
  vowels: Set[String] = Set.new(["a", "e", "i", "o", "u"])
  total = 0
  for c in text.split("")
    if vowels.include?(c)
      total += 1
    end
  end
  return total
end
```

For one pass over a text, `String.code(text.at(i))` is enough. On 1M ASCII
characters [measured, two runs]: building the codes once with
`codes = text.split("").map do |c| String.code(c) end` took 129 to 134 ms;
a `while` over `codes[i]` took 163 to 165 ms; a `while` with
`String.code(text.at(j))` took 283 ms. One build plus one indexed pass (about
295 ms) costs about what one `at` pass costs, so keep the list when you scan
the same text twice or move back and forth in it.

## Loops

- A `while` over an index with mutable locals is faster than a `step(state)`
  tail-call loop with `.with`. On the same lexer tables, `while` took about 3%
  to 6% less time (29.2 against 31.0 ms, 1,664 against 1,741, 910 against 939,
  771 against 815) [PR #255].
- Mutual tail calls also run to depth 1,000,000 when each function ends in
  `return` of the other [measured].

## Struct updates

`value.with(field: x)` copies the struct in one instruction, and a constructor
call writes every field. Wall time for 1,000,000 updates in a `while` loop, in
ms [bench]. An empty loop takes about 110 ms of each row, and the percentages
below are of the totals.

| Struct and update | Constructor | `.with` |
|---|---:|---:|
| 2 fields, 1 changed | 197 | 212 |
| 4 fields, 1 changed | 289 | 240 |
| 8 fields, 1 changed | 380 | 280 |
| 16 fields, 1 changed | 567 | 373 |
| 8 fields, `step(s.with(...))` tail call | 570 | 485 |

`.with` takes about 8% longer than the constructor for 2 fields, and 15% to
34% less time for 4 to 16 fields, so use it from 4 fields up. It copies every
field, so do it once per token or node, not once per character.

## Collections and strings

- `Map` and `Set` lookups and inserts (`get`, `put`, `include?`, `add`) take
  effectively constant time: both are one 32-way HAMT.
- A table keyed by dense `Int` ids (node ids, indexes) is faster as a `List`
  indexed by id (`List.repeat` once, then `set` and `[]`) than as a `Map[Int, T]`:
  `List.set` took about 1.6 µs and `Map.put` about 5 µs at 5,000 entries, and
  keeping the types of a checker in a list instead of a map took a 630,000
  character program from 1.83 s to 1.24 s and `std/bdd/gherkin` from 38 to
  33 ms [measured under load, with other jobs running]. `List.repeat` halts
  above 1,048,576 items, so build a bigger list from several repeats.
- `Set.new` costs about 7 to 10 µs per element, and the cost rises with size:
  100,000 items took 0.69 s, 200,000 1.18 s, 400,000 3.05 s and 1,000,000
  10.3 s [measured, one run each]. One `include?` in a loop costs about 0.2 µs,
  so each element of a `Set.new` costs 30 to 50 lookups. Build a large set
  once and keep it.
- A builtin runs to the end of its turn, except the resumable ones (`map`,
  `filter`, `reduce`, `each`, `any?`, `all?`, `sort_by`), so a 10-second
  `Set.new` stalls every other task [docs/vm/10-io-scheduler.md]. Keep big
  builds out of code that other tasks wait on.
- `String.at` and `String.slice` count characters. On ASCII text each is
  O(1). On text with multi-byte characters each call walks from the nearest of
  the start, the end or the last position used [vm/strings.c], so a forward
  scan is cheap and a random access can cost O(n).
