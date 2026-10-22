# Performance

Measured on the release VM, one run each unless a count is given; times are wall
milliseconds. Time code inside the program:

```ruby
start = Time.monotonic_ns()
work()
ms = (Time.monotonic_ns() - start) / 1000000
```

## Lookup tables

Build a `Set` or `Map` once and test it with `include?` or `get`, not a chain of
comparisons. A table that does not depend on the arguments belongs in a module
constant: built once before `main`, read with one array access. Build it in the
function only when it depends on the input. On 900,000 characters a
`Set[String]` test took 185 ms against 400 ms for an `or` chain of five
comparisons, and a `Set[Int]` test 205 ms against 305 ms [measured, three
runs].

For one pass over a text, a `while` with `text.at(j).code` is enough
(283 ms on 1M ASCII characters). Keep the codes in a list
(`text.split("").map do |c| c.code end`) when you scan the same text
twice or move back and forth.

## Loops and structs

- A `while` over an index with mutable locals is 3% to 6% faster than a
  `step(state)` tail-call loop with `.with`. Mutual tail calls also run to depth
  1,000,000 when each function ends in `return` of the other.
- `value.with(field: x)` copies the struct in one instruction; a constructor
  writes every field. For 1,000,000 updates `.with` takes about 8% longer than
  the constructor for 2 fields and 15% to 34% less time for 4 to 16, so use it
  from 4 fields up, once per token or node, not once per character.

## VM steps

`AGENTICA_VM_TRACE=profile` prints a report to stderr when a run ends (`agentica
FILE.agc`, `agentica check FILE`, `agentica run -- FILE.agcb`). Its first line
is `total wall_ms= steps= calls= builtin_calls= builtin_ms= gc_ms=
collections=`; then up to 30 `fn calls= steps= name= at=FILE:LINE` rows (a block
is `block@FILE:LINE:COL`), 12 `file` rows, 30 `builtin calls= us= name=` rows
and the `section` rows of `Profile.measure`. `agentica FILE.agc` prints the
front end's report, then the program's: the program's `steps` are its own, while
`gc_ms` and `collections` count the whole process. `AGENTICA_VM_TRACE_FILE=PATH`
writes the report to a file. Steps repeat exactly from run to run; wall time
does not, so compare steps. A profiled run is about a third slower: rank
builtins with the `builtin ... us=` rows, then time the program without the
profiler. A `<native>` row is the steps of a range loop such as `(0...n).each`,
one per item (the block's own steps are on its `block@` row); a list's `each`
and `map` add none.

Costs in steps, measured on 100,000 repeats:

- `while set.include?(chars[i])` and `while chars[i] == "a"`: 9 per character. A
  sentinel after the last element (`""` or `-1`, in no set) takes `i < size` out
  of the loop.
- A 3-field struct built in place: 9 steps (7 with a precomputed sum). A token
  with positions, span, value and the `push`: about 36. `xs.push(x)` 4,
  `Map.get(k, d)` 5. A `case` on an enum is a jump table: first and last variant
  cost the same.
- A call costs several steps. Inline a function that runs for each token when
  the loop makes a token every few characters: a lexer went from 52 to 24 steps
  per character by moving hot arms into `lex`, tables into module constants and
  using `text.split("")` instead of `code` of each character. Inlining
  one helper alone cut 2.1%, so first find the work done per item: a closure
  called per character, a table built per call, a call per token.
- `text.split("").map do |c| c.code end` costs 3 steps and a builtin
  call per character. `Set[String]` tests cost as much as `Set[Int]`.
- The line lengths of `text.split("\n")` find the end of a line or comment with
  no scan (a CR needs the scan: it ends a line too). A value used again goes in
  a local (a computed column, or the top and depth of a bracket stack): 2% to 3%
  off a lexer's steps.

## Sections, step budgets and flame graphs

```text
Profile.measure(label: String, block: Fn[T]) -> T   # runs the block once; a section row with the profile on
Profile.steps() -> Int                              # steps of this task so far; the same on every run
```

`Profile.measure(label) do ... end` gives the block's value (a block of no
parameters, or `&f`). With the profile, each label adds a `section calls=
steps= us= gc_ms= name=LABEL` row after the builtin rows (up to 30, most steps
first). Without it the call is one block call (one step), so it can stay in the
code; `Profile.steps()` works with or without the profile.

- A run keeps 4096 labels; later ones share an `[overflow]` section (frame
  `measure[overflow]`). Do not build labels from data.
- Sections are inclusive. In one task, a label inside itself (recursion) counts
  every call but its steps and time once, for the outermost call.
- `steps` are the running task's; `us` and `gc_ms` are wall time, which goes on
  while the task waits. A block that ends in a runtime error or a cancel counts
  a call with no steps.
- A block that uses `try` needs a `Result` type from the call: `r: Result[Int] =
  Profile.measure("parse") do ... end`, else `CHECK-TRY-CONTEXT`.

Hold code to a step budget in a test:

```ruby
before = Profile.steps()
parse(text)
used = Profile.steps() - before
try Test.assert(used < 50000, "parse took #{used} steps")
```

Flame graphs: with the profile, `AGENTICA_PROFILE_FORMAT=folded` writes folded
stacks (frames from the outermost joined by `;`, a space, the weight in steps)
for flamegraph.pl, inferno or speedscope. Write to a file (on stderr it mixes
with the program's output); with `agentica FILE.agc` the file has the program's
stacks only.

```sh
AGENTICA_VM_TRACE=profile AGENTICA_PROFILE_FORMAT=folded \
  AGENTICA_VM_TRACE_FILE=app.folded agentica app.agc
flamegraph.pl app.folded > app.svg
```

- Frames: `name@FILE:LINE` for a function, `block@FILE:LINE:COL` for a block,
  the builtin's name for a native loop or callback (`Int.times`, `List.map`),
  `measure:LABEL` for a `Profile.measure`.
- One sample every 1000 steps, weight 1000; `AGENTICA_PROFILE_SAMPLE=N` sets N
  (1 counts every step, so the weights add up to the report's `steps`). There is
  no time weight, so the file is the same on every run. Sampling adds a few
  percent at N = 1000, about a fifth at N = 100.
- `;`, `%` and control bytes in a name become `%XX`. At most 1,048,576 distinct
  stacks; later new stacks go to one `[truncated]` line, then an `agc-trace
  folded profile full` line.

## Collections and strings

- `Map` and `Set` lookups and inserts (`get`, `put`, `include?`, `add`) take
  effectively constant time (a 32-way hash trie).
- A table keyed by dense `Int` ids is faster as a `List` (`List.repeat` once,
  then `set` and `[]`) than as a `Map[Int, T]`: `List.set` about 1.6 µs,
  `Map.put` about 5 µs at 5,000 entries. `List.repeat` halts above 1,048,576
  items: build a bigger list from several repeats.
- `Set.new` costs 7 to 10 µs per element, rising with size (100,000 items took
  0.69 s, 1,000,000 took 10.3 s [one run each]); one `include?` costs about
  0.2 µs. Build a large set once and keep it.
- A builtin runs to the end of its turn, except the resumable ones (`map`,
  `select`, `reduce`, `each`, `any?`, `all?`, `sort_by`), so a 10-second
  `Set.new` stalls every other task. Keep big builds out of code others wait on.
- `String.at` and `String.slice` count characters: O(1) on ASCII; on multi-byte
  text each call walks from the nearest of the start, the end or the last
  position used (a forward scan is cheap, random access can cost O(n)).

## Enumerable methods

`find`, `each_with_index`, `flat_map`, `partition`, `take_while`, `drop_while`,
`each_slice`, `group_by`, `tally`, `uniq`, `sum`, `min_by`, `max_by`, `Map.each`
and `Map.select` are written in Agentica and run in your program, so their steps
count against `--max-steps`. Each is one O(n) pass with no list copy per
element. Their own steps per element (not the block's), on 100,000 elements:

| Method | Steps |
|---|---:|
| `find` (no match), `sum` | 4 |
| `uniq` (1,000 distinct) | 5 |
| `Map.each` | 7 |
| `flat_map` (1 item each), `partition` | 8 |
| `each_with_index`, `take_while`, `drop_while` | 9 |
| `tally` (1,000 keys) | 10 |
| `each_slice(3)` | 11 |
| `Map.select` | 11.5 |
| `group_by` (1,000 keys) | 14 |
| `min_by` (`Int`) | 20 |
| `max_by` (`String`) | 22 |
| `max_by` (`Int`, every key a new best) | 24 |
| `min_by` (`Float`) | 28 |

Wall time of `tally`, `uniq` and `group_by` also grows with the number of
distinct keys (the VM's `Map` and `Set` insert cost: about 4 s at 400,000
distinct keys, as in a hand-written loop). Each block call adds 4 to 6 steps on
its own `block@` row. The bodies avoid `concat`, `take`, `drop`, `reverse`,
`sort`, `Map.keys`, `Map.values` and `Map.delete` inside a loop, because an O(n)
builtin in a loop is quadratic in time while its steps look linear: write your
own loops the same way. `take_while` and `drop_while` do one `take` or `drop`
after the scan.
