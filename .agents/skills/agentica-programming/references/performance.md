# Performance

Measured costs for fast `.agc` code on the release VM. One run each unless a
count is given. Times are wall milliseconds unless stated.

Time a piece of code inside the program:

```ruby
start = Time.monotonic_ns()
work()
ms = (Time.monotonic_ns() - start) / 1000000
```

## Lookup tables

Build a `Set` or `Map` once, then test it with `include?` or `get`, instead of
a chain of comparisons. A table that does not depend on the arguments belongs
in a module constant: it is built once before `main`, and a read is one array
access. Build it in the function only when it depends on the input. On 900,000
characters, a `Set[String]` test took 185 ms against 400 ms for an `or` chain of
five comparisons, and a `Set[Int]` test took 205 ms against 305 ms [measured,
three runs].

```ruby
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

For one pass over a text, a `while` with `String.code(text.at(j))` is enough.
On 1M ASCII characters [measured, two runs] it took 283 ms. Building the codes
once (`codes = text.split("").map do |c| String.code(c) end`, 129 to 134 ms) and
then a `while` over `codes[i]` (163 to 165 ms) took about 295 ms, about one `at`
pass. Keep the list when you scan the same text twice or move back and forth in
it.

## Loops

- A `while` over an index with mutable locals is about 3% to 6% faster than a
  `step(state)` tail-call loop with `.with` (measured on lexer tables).
- Mutual tail calls also run to depth 1,000,000 when each function ends in
  `return` of the other.

## VM steps

`AGENTICA_VM_TRACE=profile` makes a run print a report to stderr when it ends:
`AGENTICA_VM_TRACE=profile agentica FILE.agc`, `... agentica check FILE`, or
`... agentica run -- FILE.agcb`. The first line is `total wall_ms= steps=
calls= builtin_calls= builtin_ms= gc_ms= collections=`. Then come up to 30
`fn calls= steps= name= at=FILE:LINE` rows (a block is `block@FILE:LINE:COL`),
up to 12 `file` rows, up to 30 `builtin calls= us= name=` rows and the `section`
rows of `Profile.measure` (below). `agentica FILE.agc` prints two reports, the
front end's first and the program's second: the program's `steps` are its own,
while `gc_ms` and `collections` count the whole process.
`AGENTICA_VM_TRACE_FILE=PATH` writes the report to a file instead. Steps repeat
exactly from run to run, so they are the evidence to compare; wall time is not.

Costs in steps, measured on 100,000 repeats of one form:

- A scan loop `while set.include?(chars[i])` and `while chars[i] == "a"` cost 9
  steps for each character. A guard against codes above 127 in front of a
  `List[Bool]` table costs 15, and unrolling by two gives 8.5. A sentinel after
  the last element (`""` or `-1`, in no set) takes `i < size` out of the loop.
- A struct with 3 fields built in place, such as a position, costs 9 steps with
  a column `offset - start + 1` and 7 with a precomputed sum. A token with its
  two positions, a span, a value and the `push` costs about 36. `xs.push(x)`
  costs 4, `Map.get(k, d)` 5, and a `case` on an enum is a jump table: the first
  and the last variant cost the same.
- A call costs several steps (the arguments and the return). Inline a function
  that runs for each token when the loop makes a token every few characters: a
  lexer went from 52 to 24 steps for each character by moving the hot arms into
  `lex`, the tables into module constants and using `text.split("")` as the text
  instead of `String.code` of each character. Inlining one helper alone cut
  2.1%, so first find the work done for each item: a closure called for each
  character, a table built on each call, a call for each token.
- `text.split("").map do |c| String.code(c) end` costs 3 steps and a builtin
  call for each character (about 100 ms for 1,000,000), and `Set[String]` tests
  cost as much as `Set[Int]` ones (177 and 184 ms for 1,000,000 tests).
- The line lengths of `text.split("\n")` find the end of a comment or a line
  with no scan of its characters (a CR needs the scan: it ends a line too).
- Keep a value that is used again in a local: a computed column, or the top and
  the depth of a bracket stack instead of reading a list, took about 2% and 3%
  off a lexer's steps.
- The profile's `builtin ... us=` rows give the time of each builtin. A profiled
  run is about a third slower, so use the rows to rank builtins and time the
  program without the profiler.
- A `<native>` row is the steps of a range loop such as `(0...n).each`, one for
  each item; the block's own steps are on its `block@` row. A list's `each` and
  `map` add no `<native>` steps.

## Sections, step budgets and flame graphs

`Profile.measure(label) do ... end` gives the block's value (a block of no
parameters, or `&f`). With `AGENTICA_VM_TRACE=profile` each label adds a row
`section calls= steps= us= gc_ms= name=LABEL` after the builtin rows, up to 30,
most steps first. Without the profile it is one block call (one step), so it
can stay in the code.

- A run keeps 4096 labels; later labels share one `[overflow]` section (frame
  `measure[overflow]`). Do not build labels from data.
- Sections are inclusive: an outer section counts the sections inside it. A
  label inside itself in one task (recursion) counts every call, but its steps
  and time once, for the outermost call.
- `steps` are the running task's; `us` and `gc_ms` are wall time, which goes on
  while the task waits. A block that ends in a runtime error or a cancel counts
  a call with no steps.
- A block that uses `try` needs a `Result` type from the call:
  `r: Result[Int] = Profile.measure("parse") do ... end`; without one, `try` is
  `CHECK-TRY-CONTEXT`.

`Profile.steps()` is the steps of the running task so far, with or without the
profile, and the same on every run. Hold code to a budget in a test:

```ruby
before = Profile.steps()
parse(text)
used = Profile.steps() - before
try Test.assert(used < 50000, "parse took #{used} steps")
```

Flame graphs: `AGENTICA_PROFILE_FORMAT=folded` with the profile writes folded
stacks instead of the report, one line per stack: frames from the outermost,
joined by `;`, a space and the weight in steps. flamegraph.pl, inferno and
speedscope read it.

```sh
AGENTICA_VM_TRACE=profile AGENTICA_PROFILE_FORMAT=folded \
  AGENTICA_VM_TRACE_FILE=app.folded agentica app.agc
flamegraph.pl app.folded > app.svg
```

- Frames: `name@FILE:LINE` for a function, `block@FILE:LINE:COL` for a block,
  the builtin's name for a native loop or callback (`Int.times`, `List.map`),
  `measure:LABEL` for a `Profile.measure`.
- A sample of the running task's stack every 1000 steps, weight 1000;
  `AGENTICA_PROFILE_SAMPLE=N` sets N (1 counts every step, and the weights add
  up to the report's `steps`). The file is the same on every run; there is no
  time weight.
- `;`, `%` and control bytes in a name are written as `%XX`. At most 1,048,576
  distinct stacks; the weight of later new stacks goes to one `[truncated]`
  line, followed by an `agc-trace folded profile full` line.
- With `agentica FILE.agc` the file has the program's stacks only. Write it to a
  file: on stderr it mixes with the program's own output.
- The sampling adds a few percent to a profiled run at N = 1000 and about a
  fifth at N = 100.

## Struct updates

`value.with(field: x)` copies the struct in one instruction, and a constructor
call writes every field. For 1,000,000 updates in a `while` loop, `.with` takes
about 8% longer than the constructor for 2 fields, and 15% to 34% less time for
4 to 16 fields, so use it from 4 fields up. It copies every field, so do it once
per token or node, not once per character.

## Collections and strings

- `Map` and `Set` lookups and inserts (`get`, `put`, `include?`, `add`) take
  effectively constant time: both are a 32-way hash trie.
- A table keyed by dense `Int` ids (node ids, indexes) is faster as a `List`
  indexed by id (`List.repeat` once, then `set` and `[]`) than as a `Map[Int,
  T]`: `List.set` took about 1.6 µs and `Map.put` about 5 µs at 5,000 entries.
  `List.repeat` halts above 1,048,576 items, so build a bigger list from several
  repeats.
- `Set.new` costs about 7 to 10 µs per element, and the cost rises with size:
  100,000 items took 0.69 s and 1,000,000 took 10.3 s [measured, one run each].
  One `include?` in a loop costs about 0.2 µs, so each element of a `Set.new`
  costs 30 to 50 lookups. Build a large set once and keep it.
- A builtin runs to the end of its turn, except the resumable ones (`map`,
  `filter`, `reduce`, `each`, `any?`, `all?`, `sort_by`), so a 10-second
  `Set.new` stalls every other task. Keep big builds out of code that other
  tasks wait on.
- `String.at` and `String.slice` count characters. On ASCII text each is O(1).
  On text with multi-byte characters each call walks from the nearest of the
  start, the end or the last position used, so a forward scan is cheap and a
  random access can cost O(n).

## Enumerable methods

`find`, `each_with_index`, `flat_map`, `partition`, `take_while`, `drop_while`,
`each_slice`, `group_by`, `tally`, `uniq`, `sum`, `min_by`, `max_by`, `Map.each`
and `Map.filter` are written in Agentica and run in your program, so their steps
count against `--max-steps`. Each is O(n) with one pass and no copy of the list
for each element. The table gives the steps of the method itself, not counting
the block, measured with `AGENTICA_VM_TRACE=profile` on 100,000 elements:

| Method | Steps for each element |
|---|---:|
| `find` (no match) | 4 |
| `sum` (`Int` or `Float`) | 4 |
| `flat_map` (1 item each) | 8 |
| `partition` | 8 |
| `each_with_index`, `take_while`, `drop_while` | 9 |
| `tally` (1,000 keys) | 10 |
| `each_slice(3)` | 11 |
| `Map.each` | 7 |
| `Map.filter` | 11.5 |
| `group_by` (1,000 keys) | 14 |
| `uniq` (1,000 distinct) | 5 |
| `min_by` (`Int`) | 20 |
| `max_by` (`Int`, every key a new best) | 24 |
| `max_by` (`String`) | 22 |
| `min_by` (`Float`) | 28 |

The step counts do not show one cost: the wall time of `tally`, `uniq` and
`group_by` grows with the number of distinct keys. That is the VM's `Map` and
`Set` insert cost (about 4 s at 400,000 distinct keys, the same as a
hand-written loop), not the body.

Each block call is 4 to 6 steps more on its own `block@` row. The bodies avoid
`concat`, `take`, `drop`, `reverse`, `sort`, `Map.keys`, `Map.values` and
`Map.delete` inside a loop, because an O(n) builtin in a loop is quadratic in
time while its steps still look linear. Write your own loops the same way.
`take_while` and `drop_while` do one `take` or `drop` after the scan.
