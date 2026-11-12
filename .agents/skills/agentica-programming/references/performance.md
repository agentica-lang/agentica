# Performance

Time code inside the program:

```ruby
start = Time.monotonic_ns()
work()
ms = (Time.monotonic_ns() - start) / 1000000
```

## Lookup tables and loops

Build a `Set` or `Map` once and test it with `include?` or `get`, not a chain of
comparisons. A table that does not depend on the arguments belongs in a module
constant: built once before `main`. Build it in the function only when it
depends on the input.

For one pass over a text, a `while` with `text.at(j).code` is enough; keep the
codes in a list (`text.split("").map do |c| c.code end`) when you scan the same
text twice or move back and forth.

A `while` over an index with mutable locals is a little faster than a
`step(state)` tail-call loop with `.with`. `value.with(field: x)` copies the
struct in one instruction, a constructor writes every field: `.with` pays from
4 fields up.

## VM steps

`AGENTICA_VM_TRACE=profile` prints a report to stderr when a run ends (`agentica
FILE.agc`, `agentica check FILE`, `agentica run -- FILE.agcb`). Its first line
is `total wall_ms= steps= calls= builtin_calls= builtin_ms= gc_ms=
collections=`; then `fn` rows (a block is `block@FILE:LINE:COL`, a lambda
`lambda@FILE:LINE:COL`), `file` rows, `builtin calls= us= name=` rows and the
`section` rows of `Profile.measure`; the `events`, `op` and `pair` rows at the
end are for work on the VM. `agentica
FILE.agc` prints the front end's report, then the program's (its `steps` are its
own, while `gc_ms` and `collections` count the whole process).
`AGENTICA_VM_TRACE_FILE=PATH` writes the report to a file. Steps repeat exactly
from run to run; wall time does not, so compare steps. A profiled run is slower
(up to about 15 times for a loop of cheap builtin calls, since each is timed):
rank builtins with the `builtin ... us=` rows, then time the program without the
profiler. A `<native>` row is the steps of a range loop such as `(0...n).each`,
one per item (the block's own steps are on its `block@` row); a list's `each`
and `map` add none.

Costs in steps: `while chars[i] == "a"` 9 per character (a sentinel after the
last element takes `i < size` out of the loop); `xs.push(x)` 4; `Map.get(k, d)`
5; a 3-field struct built in place 9; `text.split("").map do |c| c.code end` 3
and a builtin call per character. A `case` on an enum is a jump table. A call
costs several steps: inline a function that runs for each token, build a table
once, and find the work done per item (a closure per character, a table per
call) before tuning a helper.

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

- A run keeps 4096 labels: do not build labels from data.
- Sections are inclusive. In one task, a label inside itself (recursion) counts
  every call but its steps and time once, for the outermost call.
- `steps` are the running task's; `us` and `gc_ms` are wall time, which goes on
  while the task waits.
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

CPU time on Linux: `AGENTICA_PERF_MAP=1 perf record -g agentica app.agc`
writes `/tmp/perf-PID.map`, so `perf report` names the compiled functions
(`agentica:NAME`).

- Frames: `name@FILE:LINE` for a function, `block@FILE:LINE:COL` for a block,
  `lambda@FILE:LINE:COL` for a lambda, the builtin's name for a native loop or
  callback (`Int.times`, `List.map`), `measure:LABEL` for a `Profile.measure`.
- One sample every 1000 steps, weight 1000; `AGENTICA_PROFILE_SAMPLE=N` sets N
  (1 counts every step, so the weights add up to the report's `steps`). There is
  no time weight, so the file is the same on every run.

## Collections and strings

- `Map` and `Set` lookups and inserts (`get`, `put`, `include?`, `add`) take
  effectively constant time (a 32-way hash trie).
- A table keyed by dense `Int` ids is faster as a `List` (`List.repeat` once,
  then `set` and `[]`) than as a `Map[Int, T]`. `List.repeat` halts above
  1,048,576 items: build a bigger list from several repeats.
- `Set.new` costs 7 to 10 µs per element, rising with size; one `include?`
  about 0.2 µs. Build a large set once and keep it.
- A builtin runs to the end of its turn, except the resumable ones (`map`,
  `select`, `reduce`, `each`, `any?`, `all?`, `sort_by`), so a 10-second
  `Set.new` stalls every other task. Keep big builds out of code others wait on.
- `String.at` and `String.slice` count characters: O(1) on ASCII; on multi-byte
  text each call walks from the nearest of the start, the end or the last
  position used, eight ASCII bytes at a time (a forward scan is cheap, random
  access can cost O(n)).

## Hot paths

Rough numbers, measured on Agentica 0.29.0, x86-64 Linux.

- Use `map.get(key, default)`, not `get` plus `unwrap_or`: no Optional is
  built.
- Do not build many small Bytes pieces in a hot loop. Precompute the fixed
  pieces (a table of headers built once as a module constant) and join them
  with one `Bytes.concat` at the end. `"...#{n}".bytes` builds a String, then
  copies it (about 280 ns).
- An immutable `Map#put` copies the nodes on the path (about 0.8 µs at 1,000
  keys). `ATS` costs about twice a `Map` per operation: use it only for state
  that tasks really share.

## Enumerable methods

`find`, `find_index`, `each_with_index`, `flat_map`, `partition`, `take_while`,
`drop_while`, `each_slice`, `group_by`, `tally`, `uniq`, `sum`, `min`, `max`,
`min_by`, `max_by`, `Map.each` and `Map.select` are written in Agentica and run
in your program, so their steps count against `--max-steps`. Each is one O(n)
pass with no list copy per element, 4 to 28 steps per element of its own (not
the block's; `min` and `max` on Floats take 12 to 14). Measure the one you use
with the profiler.

Wall time of `tally`, `uniq` and `group_by` also grows with the number of
distinct keys (the cost of the VM's `Map` and `Set` insert). The bodies avoid
list `+`, `take`, `drop`, `reverse`, `sort`, `Map.keys` and `Map.values` inside
a loop, because an O(n) builtin in a loop is quadratic in time while its steps
look linear: write your own loops the same way.
