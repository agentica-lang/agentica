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

Build a `Set` or `Map` once, then test it with `include?` or `get`, instead of
a chain of comparisons. A table that does not depend on the arguments belongs
in a module constant (`VOWELS = Set.new(["a", "e", "i", "o", "u"])` at the top
of the file): it is built once before `main`, not on every call, and a read is
one array access. Build it in the function only when it depends on the input.
On 900,000 characters, a `Set[String]` test took 185 ms against 400 ms for an
`or` chain of five comparisons, and a `Set[Int]` test took 205 ms against
305 ms [measured, three runs].

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

## VM steps

`AGENTICA_VM_TRACE=profile` makes a run print a report to stderr when it ends:
`AGENTICA_VM_TRACE=profile agentica FILE.agc`, `... agentica check FILE`, or
`... agentica run -- FILE.agcb`. Its first line is `total wall_ms= steps=
calls= builtin_calls= builtin_ms= gc_ms= collections=`, then up to 30 `fn
calls= steps= name= at=FILE:LINE` rows (a block is `block@FILE:LINE:COL`), up
to 12 `file` rows and up to 30 `builtin calls= us= name=` rows.
`agentica FILE.agc` prints two reports, the front end's first and the
program's second: the program's `steps` are its own, while `gc_ms` and
`collections` count the whole process. `AGENTICA_VM_TRACE_FILE=PATH` writes the
report to a file instead. Steps repeat exactly from run to run, so they are the
evidence to compare; wall time is not. Costs in steps, measured on 100,000
repeats of one form [PR #317]:

- A scan loop `while set.include?(chars[i])` and `while chars[i] == "a"` cost 9
  steps for each character. A guard against codes above 127 in front of a
  `List[Bool]` table costs 15, and unrolling by two gives 8.5. A sentinel
  after the last element (`""` or `-1`, in no set) takes `i < size` out of the
  loop.
- A struct with 3 fields built in place, such as a position, costs 9 steps
  with a column `offset - start + 1` and 7 with a precomputed sum. A token with
  its two positions, a span, a value and the `push` costs about 36. `xs.push(x)`
  costs 4, `Map.get(k, d)` 5, and a `case` on an enum is a jump table: the first
  and the last variant cost the same.
- A call costs several steps (the arguments and the return), so a function
  that runs once for each token is worth inlining when the loop makes a token
  every few characters. The lexer went from 52 to 24 steps for each character
  by moving the hot arms into `lex`, the tables into module constants and
  `text.split("")` as the text instead of `String.code` of each character
  [PR #317, `docs/vm-benchmarks.md`]. Inlining one helper at its call sites
  alone cut 2.1%, so first find the work done for each item: a closure called
  for each character, a table built on each call, a call for each token.
- Scan the characters themselves: `text.split("").map do |c| String.code(c) end`
  costs 3 steps and a builtin call for each character (about 100 ms for
  1,000,000), and `Set[String]` tests cost as much as `Set[Int]` ones (177 and
  184 ms for 1,000,000 tests).
- The line lengths of `text.split("\n")` find the end of a comment or a line
  with no scan of its characters (a CR needs the scan: it ends a line too).
- Keep a value that is used again in a local. Computing the lexer's column as
  `index + column_base`, and keeping the top and the depth of its bracket stack
  in locals instead of reading a list, took about 2% and 3% off the lexer's
  steps (25.7 M to 25.1 M, then 25.1 M to 24.3 M, on the 112 files of
  `compiler/` and `stdlib/`).
- The profile's `builtin ... us=` rows give the time of each builtin. In the
  profiled front end `List.set` took 109 ms for 44,404 calls and `Map.put` 105
  ms for 24,793 [`docs/vm-benchmarks.md`]. A profiled run is about a third
  slower, so use the rows to rank builtins and time the program without the
  profiler.
- A `<native>` row is the steps of a range loop such as `(0...n).each`, one
  for each item; the block's own steps are on its `block@` row. A list's
  `each` and `map` add no `<native>` steps.

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

## Enumerable methods

`find`, `each_with_index`, `flat_map`, `partition`, `take_while`, `drop_while`,
`each_slice`, `group_by`, `tally`, `uniq`, `sum`, `min_by`, `max_by`,
`Map.each` and `Map.filter` are written in Agentica (the compiler prelude,
`stdlib/prelude/`) and run in your program, so their steps count against
`--max-steps`. Each is O(n) with one pass and no copy of the list for each
element. Steps of the method itself on 100,000 elements, not counting the
block, measured with `AGENTICA_VM_TRACE=profile` on 2026-10-16
[`tests/fixtures/vm/prelude-cost.agc` keeps the same figures for 2,000
elements]:

| Method | Steps | For each element |
|---|---:|---:|
| `find` (no match) | 400,005 | 4 |
| `sum` (`Int` or `Float`) | 400,006 | 4 |
| `flat_map` (1 item each) | 800,006 | 8 |
| `partition` | 800,010 | 8 |
| `each_with_index`, `take_while`, `drop_while` | 900,004 to 900,005 | 9 |
| `tally` (1,000 keys) | 1,000,006 | 10 |
| `each_slice(3)` | 1,100,019 | 11 |
| `Map.each` | 700,005 | 7 |
| `Map.filter` | 1,150,009 | 11.5 |
| `group_by` (1,000 keys) | 1,400,006 | 14 |
| `uniq` (1,000 distinct) | 508,009 | 5 |
| `min_by` (`Int`) | 2,000,003 | 20 |
| `max_by` (`Int`, every key a new best) | 2,399,999 | 24 |
| `max_by` (`String`) | 2,200,113 | 22 |
| `min_by` (`Float`) | 2,799,995 | 28 |

Each block call is 4 to 6 steps more on its own `block@` row. The bodies
avoid `concat`, `take`, `drop`, `reverse`, `sort`, `Map.keys`, `Map.values` and
`Map.delete` inside a loop, because an O(n) builtin in a loop is quadratic in
time while its steps still look linear (`tests/test_stdlib_prelude.py` checks
that). Write your own loops the same way. `take_while` and `drop_while` do one
`take` or `drop` after the scan.
