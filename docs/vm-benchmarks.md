# VM benchmarks

Speed of the VM against CPython and of the JIT against the interpreter, the
HTTP sanity check of roadmap 20c, and the speed passes of the front end. Each
section keeps its result, its method and what was tried and dropped; the full
tables of each round are in git history.

## How to run

```sh
make bench                                                      # builds the VM, then runs every program
python3 benchmarks/run.py --runs 5 --size 1 --only knight-tour,calls --runners vm,python
```

`benchmarks/run.py` runs each program in `benchmarks/programs/` on these
runners:

- `exe`: `dist/agentica f.agc`, the whole path from source, start-up included.
  It runs only when `dist/agentica` exists, so run `make` first.
- `vm`: `dist/agentica run` on bytecode that `agentica compile` wrote. Only the
  VM run is timed.
- `python`: the CPython twin in `benchmarks/python/`.

Options: `--runs N` (timed runs, default 5), `--size N` (scales the work of
every program), `--only a,b`, `--runners exe,vm,python`, and `--no-startup` to
skip the `hello.agc` start-up check and the front-end rows (see "Front end").
`run.py` has no `--jit`; programs run with the default `--jit on`, and
`AGENTICA_JIT=off python3 benchmarks/run.py ...` sets the JIT mode of every
program it runs (see "JIT").

Every runner must print the same output, or the row is a mismatch and the script
exits 1. A program the VM cannot compile yet shows as `unsupported`, with its
`LOWER-UNSUPPORTED` summary. The Python twins are idiomatic, not step-by-step
copies, so a ratio compares two idiomatic programs.

**Method.** Run the two binaries alternately (A B A B, several rounds, the
median of the round medians), keep the old binary built apart, and say when the
load average was above 2 ("measured under load"). Step counts
(`AGENTICA_VM_TRACE=profile`) do not depend on the load.

**The link layout hides small differences.** Padding the text of one binary by
64 to 1,216 bytes moved an empty loop between 53 and 98 ms, and `arithmetic` by
10% to 30%, with the same code. It is not field offsets, heap offsets or the
start of `agc_run_turn`; most likely the indirect jump of the `switch` and the
predictor. Read a pure-interpreter difference below 10% from one layout as
noise, and build several layouts (padding) before blaming a change.

## Results

Run of 2026-10-11, median of 5 runs at size 1, on an AMD Ryzen 5 3550H (4
cores, 12 GB RAM), Debian 13, gcc 14.2, Python 3.13.5; a shared host, so the
numbers are rough. The third speed pass (below) later made the loop-bound rows
1.2 to 2 times faster.

| Program | Work | VM s | Python s | VM / Python |
|---|---|---:|---:|---:|
| knight-tour | Warnsdorff search, 8x8, 22 starts | 0.037 | 0.031 | 1.2 |
| maze-bfs | BFS over four 40x40 mazes | 0.059 | 0.044 | 1.3 |
| traveling-salesman | branch and bound, 9 cities | 0.031 | 0.030 | 1.0 |
| arithmetic | Collatz lengths of 1 to 2500 | 0.044 | 0.040 | 1.1 |
| strings | 2,000 lines with `+` and interpolation | 0.019 | 0.026 | 0.7 |
| string-library | split, trim, upcase, join, replace, non-ASCII | 0.034 | 0.045 | 0.8 |
| lists | 30 rounds of 1,000 `push`, then filter, map, reduce, sort | 0.064 | 0.057 | 1.1 |
| list-build | 20,000 `push`, 20,000 scattered `set`, a `for` sum | 0.062 | 0.039 | 1.6 |
| maps | 5 rounds of 6,000 `put` and `get`, 1,009 keys | 0.094 | 0.024 | 3.9 |
| calls | recursive `fib`, 40,000 helper calls | 0.021 | 0.037 | 0.6 |
| case | an enum instruction list, 5,000 times through `case` | 0.022 | 0.069 | 0.3 |
| small-values | one-character and empty values (2026-10-16) | 0.111 | 0.093 | 1.2 |

The lists and list-build rows are from the 8d run (2026-10-14). The
`list-build` twin appends to one mutable list, which the VM cannot do, so 1.6
there is a good result. Start-up on precompiled bytecode: the VM takes about 1
ms and 2 MB, CPython 19 ms and 8 MB; the VM uses about a fifth of CPython's
memory.

Conclusions: maps are the slow spot (a `put` copies a HAMT path). Lists were
slow because `List.append` copied the whole array; the persistent vector of 8d
fixed it (below). Dispatch and Int arithmetic were the next candidates (7g),
which the third speed pass took.

## Lists (roadmap 8d)

The persistent vector of 8d (`docs/vm/17-lists.md`) against the flat array
(71717e0), 2026-10-14:

| Program | Flat s | Vector s | Max RSS MB (flat / vector) |
|---|---:|---:|---:|
| lists, size 1 | 0.232 | 0.048 | 6.0 / 5.9 |
| list-build, size 1 (20,000 pushes and sets) | 3.47 | 0.054 | 8.1 / 6.6 |
| list-build, size 2 (40,000) | 14.5 | 0.118 | 10.5 / 7.5 |
| 160,000 pushes in a loop | 68 | 0.09 | 17.2 / 12.4 |

Pushes in a loop are linear: doubling n multiplies the time by 1.7 to 2.0 (gate
2.5), from 0.016 s for 20,000 to 0.663 s for 1,280,000; 160,000 take 0.09 s
(gate 1 s). No other benchmark moved by more than the link-layout noise.

### Bulk builds and memory

A list built at once (`List.repeat`, `Range.to_a`, `reverse`, `take`, `drop`,
`concat`, `String.split`, `sort`) allocates its trie in a handful of blocks, and
`List.repeat` shares one leaf. The first trie attached one leaf per 32 pushes:
it took six times as long as the flat array to build a million items, spent 45%
more memory (every 512-byte leaf and 256-byte branch a separate allocation),
and made the GC-stress run of `process-channel-close.agc` miss its 100 ms
window. With the leaves of one build as slices of one array, the cost over the
flat array is the branches, 1.6% (about 264 KB for a million items), and
`List.repeat(7, 1000000)` peaks at 5.6 MB (the VM start-up) against 21.4 MB.
Indexing and `for` cost about 1.3 and 1.06 times the flat array, the price of
the two to four loads per item.

### Bulk operations after the trie

The list performance PR (`docs/vm/17-lists.md` §17.11), one operation per loop
next to the same live data, the empty loop subtracted, 1,000,000 items,
milliseconds per operation, collections included:

| Operation | Flat | Trie | After the PR | Python |
|---|---:|---:|---:|---:|
| `sort`, reversed range | 170 | 174 | 21 | 16 |
| `sort`, scattered ints | 308 | 319 | 100 | 173 |
| `String.split(big, "")` | 52 | 65 | 15 | 7 |
| `take` and `drop` of n / 2 | 9.9 | 12.2 | 1.0 | 9 |
| `map` | 100 | 99 | 102 | 69 |
| `filter` | 149 | 159 | 162 | 83 |

`reverse`, `join`, `map` and `filter` did not move: a million-item operation is
an allocation of 16 MB plus its share of the collector (a collection costs 15
to 25 ms here), and `map` and `filter` are 70 to 100 ns of callback per item.
`sort` of an ordered list is O(n); a scattered one is 3 times faster because
the keys are read once and compared as `uint64_t`. `list-bulk` (size 2) went
from 0.44 s to 0.22 s (CPython 0.455 s).

## Unboxed numeric leaves (roadmap 8d step 3)

A list whose items are all Int, or all Float, stores 8 bytes per item and no tag
(`docs/vm/17-lists.md` §17.12). Master (88b9dbb) against the PR, 2026-10-15, one
case per process on a list of 1,000,000 items:

- What gains is what moves or compares raw words: `sort` 0.67 to 0.81 of
  master, `take`, `drop`, `concat` 0.33 to 0.36, pushes 0.77 to 0.81. A
  million-item Int list is 8 MB instead of 16, exactly. `map` and `filter`
  (callback-bound), the Int `for` sum and `xs[i]` (dispatch-bound) do not
  change. The Float `for` sum was 32% faster in every run with no cause found:
  a bonus, not a result.
- Peak RSS also depends on when the collector runs: read a row of RSS to within
  15 MB.
- The boxed path (`List[String]`) is the old code with one more branch: 0.95 to
  1.09 of master, inside the layout noise, except a scattered `sort` of strings
  at +5% (539 against 566 ms in 11 runs). Accepted, not chased.

`benchmarks/run.py`, size 2, seconds (master / PR / CPython): `list-bulk` 0.227
/ 0.147 / 0.446 (40% less peak memory), `list-build` 0.106 / 0.087 / 0.043,
`lists` 0.076 / 0.069 / 0.056; `maps` and `arithmetic` unchanged.

## Sets (8b)

`Set[T]` is a map with nil values (`vm/map.c`), so it shares the HAMT, and a
member of a set costs the same as a key of a map: 466 to 526 ns for a lookup
with Int keys, 3,800 to 5,730 ns for an insert. `sets` (size 1) takes 0.101 s
against 0.041 s in CPython.

- `Set.add` of a member allocates nothing (`agc_map_add_hash` returns the same
  map). A first version that looked the key up before the `put` made `add` 10%
  to 35% slower when every key was new; the single pass removed that cost.
- `intersection` and `difference` first count the elements they keep with
  lookups only, and return the first set itself when none is dropped: 150 ms
  instead of 3,455 ms on two equal sets of 300,000.

## Maps: dead key cells and compact nodes

Without `perf` on the host, the profiler showed `Map.delete` at 1.8 ms a call
on 20,000 keys: it copied the key list up to the key, so deleting half the map
was quadratic. A C loop over `agc_map_put` showed the rest: 2.5 us a put on
20,000 Int keys, nearly all copying, because every slot of a node, child links
too, was a 48-byte entry, and a put copies a 32-slot root and a full second
level. Two changes in `vm/map.c` (#704), with the same output and steps:

- A delete adds its key's insertion number to the map's dropped list and
  leaves the key list as it is. Walks skip the dead cells by number (a bitmap,
  or a sorted merge when the numbers are sparse), never by a key lookup, so a
  walk after one delete costs what it did. The list is rebuilt in one block
  once the dead cells outnumber the live ones.
- A node keeps its leaves, then its child pointers (8 bytes each), with a
  `datamap` and a `nodemap`; a child left with one key is pulled up.

The C loop went from 2,500 to 1,050 ns a put (get 120 to 110 ns, delete 300,000
to 1,300 ns). Run of 2026-10-26 against master `8a477867`, size 8, five rounds
alternated, median s, in two link layouts (a: the usual link order, b: `map.o`
last), load average 1.5 to 2.8:

| Program | Before, layout a / b | After, layout a / b | Ratio a / b |
|---|---:|---:|---:|
| maps | 1.399 / 1.222 | 0.470 / 0.539 | 0.34 / 0.44 |
| sets | 0.657 / 0.682 | 0.256 / 0.258 | 0.39 / 0.38 |
| maze-bfs | 0.443 / 0.441 | 0.278 / 0.276 | 0.63 / 0.63 |

The other programs moved between 0.70 and 1.13 in layout a and between 0.93 and
1.06 in layout b, with no direction common to both: layout noise.
`small-values` (0.86 / 0.87) is in that band too and is not claimed.

Map programs from the review, median of three alternated runs, s and peak RSS:

| Program | Before | After |
|---|---:|---:|
| 100,000 String keys, delete one, `keys.size` 300 times | 1.53, 58 MB | 1.19, 50 MB |
| 100,000 Int keys, delete one, 100 walks of `keys` and `values` | 4.94, 43 MB | 3.88, 43 MB |
| 20,000 String keys, delete every other, then `m.delete(k)` for each key left | 8.58, 15 MB | 3.49, 18 MB |
| 40 rounds of 20,000 Int `put` and `get` | 2.67, 11 MB | 1.08, 11 MB |

The third row deletes again and again from one map at the rebuild threshold,
so every delete rebuilds the key list; the rebuild is one pass over integers
and one block.

## Struct update (15c)

`value.with(f: x)` lowers to one `STRUCT_WITH` instruction (a `memcpy` of the
fields and one store per changed field, charged by size as `CONCAT` is). The
other plan was the constructor (`FIELD` for each field that stays, then
`STRUCT`, no VM change). A million updates in a loop, ms (the empty loop is
about 110):

| Struct and update | Constructor | `STRUCT_WITH` |
|---|---:|---:|
| 2 fields, 1 changed | 197 | 212 |
| 4 fields, 1 changed | 289 | 240 |
| 8 fields, 1 changed | 380 | 280 |
| 16 fields, 1 changed | 567 | 373 |

The instruction stayed: the case it is for, a lexer or parser state of 4 to 16
fields in a tail-recursive `step`, is 15% to 34% faster, and two fields cost
only about 8% more.

## JIT (`--jit`)

The x86-64 JIT (`docs/vm/05-values-execution-builtins.md` §6.4) against the
interpreter (`--jit off`), on the head of #770 (2026-10-28, the `on` changes
for parking loops and sampled turns). Seconds, best of 5 runs at size 4 on one
pinned core and one scheduler, on the Ryzen 5 3550H of "Results" (8 threads, 12
GB RAM, Debian 13, gcc 14.2.0, Linux 6.12, a default `make` build). The load
average was 0.7 to 1.2, from other sessions on the same host. The host ran
these programs about 1.4 times faster than for the table on `b04d44f9` (the same
binary timed both ways in one session), so compare ratios, not seconds. The
ratio is `on` / `off`, computed from the printed times.

To rerun one program (size 4 is a copy of the source with `scale` returning 4;
bash's `time` prints milliseconds, GNU `time` only hundredths):

```sh
dist/agentica compile prog.agc -o prog.agcb
for round in 0 1 2 3 4 5; do for mode in off on always; do
  TIMEFORMAT="$mode %3R"
  time taskset -c 3 dist/agentica run --schedulers 1 --jit $mode -- prog.agcb >/dev/null
done; done
```

Interleaved means the loop above: one run of each mode per round, so a change
in the load hits the three modes alike; the table keeps the smallest of the 5
times per mode; round 0 is a warm-up and is not recorded. The front-end row is
`AGENTICA_VM_TEST_FRONT_END_JIT=$mode taskset -c 3 dist/agentica compile
compiler/front_end.agc -o out.agcb` in the same loop (a test-only variable: the
front end runs in the interpreter otherwise).

| Program | `off` s | `on` s | `always` s | `on` / `off` |
|---|---:|---:|---:|---:|
| case | 0.052 | 0.018 | 0.018 | 0.35 |
| calls | 0.060 | 0.022 | 0.021 | 0.37 |
| arithmetic | 0.074 | 0.037 | 0.036 | 0.50 |
| knight-tour | 0.066 | 0.042 | 0.041 | 0.64 |
| traveling-salesman | 0.069 | 0.046 | 0.048 | 0.67 |
| lists | 0.077 | 0.054 | 0.053 | 0.70 |
| small-values | 0.324 | 0.252 | 0.247 | 0.78 |
| strings | 0.082 | 0.066 | 0.065 | 0.80 |
| list-build (noise, see below) | 0.110 | 0.101 | 0.098 | 0.92 |
| string-library | 0.061 | 0.056 | 0.055 | 0.92 |
| maze-bfs | 0.108 | 0.101 | 0.100 | 0.94 |
| sets | 0.107 | 0.101 | 0.092 | 0.94 |
| print-lines | 0.525 | 0.498 | 0.489 | 0.95 |
| deadline-pingpong | 0.189 | 0.185 | 0.239 | 0.98 |
| sleepers | 0.354 | 0.348 | 0.355 | 0.98 |
| logger-disabled | 1.676 | 1.673 | 2.259 | 1.00 |
| channel-pingpong | 0.378 | 0.386 | 0.444 | 1.02 |
| maps | 0.164 | 0.169 | 0.172 | 1.03 |
| list-bulk (noise, see below) | 0.204 | 0.233 | 0.227 | 1.14 |
| front-end self-compile | 12.78 | 10.78 | 10.04 | 0.84 |

Every mode printed the same output, and the three self-compiles wrote the same
bytes. The `always` ratio of the self-compile is 0.79.

- **Coverage.** §6.4 says what compiles, which builtins run inside compiled
  code and which exits go back to the interpreter.
- **What changed.** On `b04d44f9`, `on` was 1.18 to 1.22 on
  `channel-pingpong`: its loops park at each send and receive, and each park
  costs about three plain exits. `on` now keeps them out, so nothing compiles.
  `logger-disabled` went from 1.02 to 1.00: nothing compiles there, and fewer
  turns run the slower jit copy of the turn loop. The self-compile did not move
  (0.84 before and after).
- **Slower rows.** Under `on`, `channel-pingpong` and `maps` are within the
  noise. Under `always`, `logger-disabled` (1.35) leaves compiled code four
  times per `Logger.debug` call; this row also moves by 9% with the address of
  `agc_jit_code_of` alone (the same code with 144 bytes of padding before it
  ran as fast as `b04d44f9`). `deadline-pingpong` (1.26) and
  `channel-pingpong` (1.17) compile their parking loops under `always`.
- **Small or no gain.** `string-library`, `maze-bfs`, `sets` and `print-lines`
  gain 5% to 8%, and `sleepers` and `maps` do not move beyond the noise.
- **Noise.** `list-build` moves by 35% to 40% between runs of one mode. Nothing
  compiles in `list-bulk`, and its best of 5 follows its rare fast runs: 20
  runs per mode gave the same spread (218 to 318 ms `off`, 220 to 312 ms `on`,
  both with a median of about 254 ms). Neither ratio is a JIT result.

## HTTP sanity check

`benchmarks/http_bench.py` is not a CI gate. It needs Python 3.10 or newer,
`taskset`, and Node for the load client and one server. It compares
`examples/http_server.agc serve` on the VM with three single-process servers
(Node `http`, a Python asyncio server, and Python's `ThreadingHTTPServer`).
Every server gets the same keep-alive load from Node clients in 4 processes. The
rounds run interleaved under `taskset`, and a round starts only when the machine
is idle.

```sh
make
python3 benchmarks/http_bench.py                                          # 40000 requests per run, 8 and 64 connections, 3 rounds
python3 benchmarks/http_bench.py --requests 8000 --rounds 2 --retries 0   # a quick check of the script
```

Results are not recorded yet. They need an idle-machine run (§30.14, item
20c-bench), and the script marks any round that ran on a busy machine. The
results include connection count, server, requests per second, min-to-max
latency, p50 and p99 latency, server CPU and maximum client CPU.

## Front end (post-bootstrap row 3)

With the `exe` runner, `benchmarks/run.py` also times the front end inside
`dist/agentica` (§18.5): `check` of `examples/hello.agc`, of
`stdlib/bdd/gherkin.agc` and of `compiler/syntax/parser.agc` (`check` checks
every body, with or without a `main`), of a three-line `main` that imports
gherkin, and of `compiler/front_end.agc`, and one `agentica test` of a one-test
file. The heading of the table prints the load average, and says "measured
under load" when the one-minute load is above 2. CI does not gate on these
times.

```sh
python3 benchmarks/run.py --runs 11 --only calls --runners exe
```

`AGENTICA_VM_TRACE=profile agentica check FILE` counts steps and calls per
function and the time per builtin (a profiled run is about a third slower; the
counts are exact). `AGENTICA_VM_TRACE=loader` prints the loader time.

Where things stand after the passes below (2026-10-16): `check
examples/hello.agc` 17.5 ms (the loader 8.3 ms of it), `check
stdlib/bdd/gherkin.agc` about 65 to 80 ms (the target of §18.5 is 100 ms),
`check compiler/syntax/parser.agc` about 205 to 225 ms. The parser is the next
front-end cost.

### Speed pass, first part

`agentica test` compiled `std/test/runner` (15.3 M steps, 0.73 s) and the
default step program `std/bdd` (0.15 s) on every run. The binary now carries
both compiled: `test` of one unit test went from 0.868 s to 0.051 s. The profile
hooks live in a second copy of the turn loop that only a profiled run enters,
so they cost nothing otherwise.

The profile then showed the lexer at 51% of the steps of `check
compiler/front_end.agc` (76.5 M steps), and the loader at 15 to 16 ms of every
command: the lexer came first, then the loader.

### Speed pass, VM start-up (row 8.3)

Every command that runs the front end first loads the carried `stage2` (3.8 MB,
about 1,400 functions and 90,000 spans), and the loader checks all of it: a
front end given with `--front-end` is not trusted. Release builds, measured
under load:

| command | before ms | after ms |
|---|---:|---:|
| `check examples/hello.agc` | 24.3 | 17.5 |
| `check stdlib/bdd/gherkin.agc` | 73.9 | 65.4 |
| `check compiler/syntax/parser.agc` | 217.5 | 206.6 |
| `run -- hello.agcb` (no front end) | 3.9 | 3.9 |
| `--version` | 2.4 | 2.3 |
| `loader done us` of a hello check | 15.4 | 8.3 |

The floor of a process start is 2.3 ms (`/bin/true` 1.0 ms): the static binary
has 24,600 relative relocations, almost all in OpenSSL's data. A default build
(shared libgc and OpenSSL) has about 1.1 MB more peak RSS, so compare binaries
of one configuration. What changed (`vm/loader.c`, `vm/value.c`):

1. **A table is taken once.** Spans, code and span indexes are read as one
   block and decoded with `get_u16` and `get_u32`, with no bounds check per
   field: `read_count` has already shown that the entries fit, so every
   rejection, with its reason, stays the same.
2. **ASCII is skipped eight bytes at a time** in `agc_utf8_chars` and
   `agc_utf8_count`; the line index finds newlines with `memchr` and counts them
   by words.
3. **The collector is held off while a program loads** (`agc_gc_pause`,
   `agc_gc_resume`): everything the loader allocates stays live until the load
   ends. The GC-stress build ignores the pause.

Tried and dropped, all inside the noise or Linux-only: a larger first
heap (`GC_INITIAL_HEAP_SIZE` 4 to 8 MB); `madvise(MADV_POPULATE_READ)` of
the carried front end (0.25 ms); a bump allocator for the small objects of
the load; `GC_DONT_GC=1` as a bound (1.2 ms, which the pause mostly takes).

Left, by worth: page faults are half of the 8.3 ms; reading the span table
in place would save about 1.7 ms but load the front end with less checking
than a file given to `run` (not done). The collector is about a third of a
hello check; the builtin catalog at start (`Map.put`, `Set.new`) is 44e
(static data).

### Speed pass, second part: the lexer

`compiler/syntax/lexer.agc` only; the output is the same byte for byte (fixed
point, goldens, every `.agc` file, the frozen corpus and 15,000 generated
texts).

| `check` of | steps before | steps after | s before | s after |
|---|---:|---:|---:|---:|
| `stdlib/bdd/gherkin.agc` | 2,833,726 | 1,923,661 | 0.126 | 0.099 |
| `compiler/syntax/parser.agc` | 11,153,906 | 7,420,483 | 0.401 | 0.304 |
| `compiler/front_end.agc` | 77,669,291 | 54,796,784 | 3.137 | 2.413 |

The lexer alone on `compiler/` and `stdlib/` went from 52 to 24 steps per
character. The cost was not in one place: the lexer made a token every 5
characters or so, and each token cost 150 to 200 steps. A call costs several
steps, a `Token` with its positions about 36, and a scan loop `while
set.include?(chars[i])` 9 steps per character, which is the floor. So the gain
came from fewer calls per token, not from a faster scan:

1. **Tables are module constants** (`CLASSES`, `WORD_ACTIONS`, `SINGLE_OPS`,
   ...), not built on every `lex` call. The main loop handles names, operators,
   brackets and line breaks in place, with no call per token; one lookup in
   `WORD_ACTIONS` tells a keyword, a block opener and `end`; the text ends with
   sentinels, so no scan tests `index < size`.
2. **Characters, not codes.** `text.split("")` is used as it is (`Set[String]`
   tests cost the same as `Set[Int]`); a comment ends at the length of its line.
3. The column of a position is `index + column_base`; the stack of open
   brackets keeps its last frame and size in locals.

Tried and dropped: a `List[Bool]` table by code (15 steps per character
against 9); unrolling the name scan by two (8.5 against 9, for more code).
Counted, not built: lexing by pieces split on a marker (about 22 M steps,
needs a marker the text does not hold) and line by line (a line costs more
than the comments save).

### Speed pass, third part: the interpreter loop

Two changes to the VM core, with the same steps and output, size 4, measured
under load:

| Program | Before s | After s | Ratio |
|---|---:|---:|---:|
| arithmetic | 0.276 | 0.133 | 0.48 |
| calls | 0.114 | 0.068 | 0.60 |
| case | 0.093 | 0.064 | 0.69 |
| maps | 0.574 | 0.483 | 0.84 |
| `check stdlib/bdd/gherkin.agc` | 0.102 | 0.080 | 0.78 |
| `check compiler/syntax/parser.agc` | 0.305 | 0.226 | 0.74 |

- **The value accessors are inline** (`static inline` in `value.h`, one cold
  `agc_wrong_tag`); `ADD_I` was three calls. The service resources stay in
  `value.c`.
- **The loop keeps the frame in locals** (code, spans, register window, `pc`)
  and reloads them (`goto reload`) only after `CALL`, `CALL_VALUE`,
  `TAIL_CALL`, `RETURN`, a failing `TRY` and a builtin that pushes a native
  frame (`docs/vm/05-values-execution-builtins.md` §6.1). `frame->pc` is still
  written before each instruction, for traces, parks and yields.
- **The empty List and Map are shared** (`agc_vm_init`), the first part of §34:
  a call with a `{}` argument went from 70 ns to 15 ns over the loop, and a
  disabled `Logger.debug` from 393 to 148 ms per million.

A `SIGPROF` sample of the front-end checks after this pass: the turn loop 41% to
52% (a third of it the dispatch), the collector 21% to 26%, the loader about 10%
of the gherkin check.

Tried and dropped: computed-goto dispatch (GCC 14 cannot inline it;
`arithmetic` +64%, so the `switch` stays); `MOVE` as two 8-byte copies
(`arithmetic` +24%); separate `ADD_I`, `SUB_I`, `MUL_I` handlers (layout
noise). Kept inside the noise: lazy span reads and the opcode range check
before the jump table (second line of defence). Not tried: counting `STEP`
in a local (every failure path would store it back before the `longjmp`).

### Speed pass, shared small values (§34)

The VM returns one shared object for `""`, the one-character ASCII Strings,
`[]`, `{}` and the empty `Set` from the builtins that compute them (the paths
are in `docs/future/34-shared-small-values.md`, §34.6). Output, steps and
goldens are the same.

The micro loops of each path allocate 25% to 98% fewer bytes and take 0.61 to
0.95 of the time: Boehm already takes small atomic objects from a free list, so
time falls less than bytes. `benchmarks/programs/small-values.agc`, the median
over seven padded layouts: 0.1448 s on master, 0.1111 s here (0.77; the gate of
§34.4 is 10%). The other programs stay within 0.92 to 1.08 (layout noise), and
the front end is neutral (it allocates 0.15% less).

Tried and dropped: `CONCAT` with an empty side returning the other String
(a branch in the hottest opcode, for a case real programs do not hit);
`filter` and `map` returning the shared empty List (one layout made
`File.each_line` 12% slower through the shared `resume_native` path).
Not done: sharing the Strings of process output, TCP reads, `read_text`,
HTTP bodies and `Dir.list`, and the `[]` of a JSON array.
