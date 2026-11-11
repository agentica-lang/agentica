# VM benchmarks

How to measure the VM against CPython and the JIT against the interpreter, the
HTTP sanity check, the front-end timings, and what was tried and dropped. The
before and after numbers of a speed change go in its PR.

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

Start-up on precompiled bytecode: the VM takes about 1 ms and 2 MB, CPython 19
ms and 8 MB.

## Struct update

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
interpreter (`--jit off`). Seconds, best of 5 runs at size 4 on one pinned core
and one scheduler, on an AMD Ryzen 5 3550H (8 threads, 12 GB RAM, Debian 13,
gcc 14.2.0, Linux 6.12, a default `make` build), load average 0.7 to 1.2. The
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
| bytes | 1.015 | 0.870 | 0.875 | 0.86 |
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
bytes. The `always` ratio of the self-compile is 0.79. Why `on` leaves some
loops out: §6.4, "Why the policy".

- **Slower rows.** Under `on`, `channel-pingpong` and `maps` are within the
  noise. Under `always`, `logger-disabled` (1.35) leaves compiled code four
  times per `Logger.debug` call; this row also moves by 9% with the address of
  `agc_jit_code_of` alone. `deadline-pingpong` (1.26) and `channel-pingpong`
  (1.17) compile their parking loops under `always`.
- **Small or no gain.** `string-library`, `maze-bfs`, `sets` and `print-lines`
  gain 5% to 8%, and `sleepers` and `maps` do not move beyond the noise.
- **bytes.** On GitHub's runners, at size 16 with one scheduler, `on` makes it
  slower: 1.06 to 1.07 on x86-64, 1.10 on Linux ARM64 and 1.00 to 1.11 on macOS
  ARM; `print-lines` is 1.05 there on Linux ARM64. On this host `bytes` is 0.86
  at size 4 and 0.85 at size 16, so the slowdown comes from the runner hosts,
  not from the size.
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

The script marks any round that ran on a busy machine. The results include
connection count, server, requests per second, min-to-max latency, p50 and p99
latency, server CPU and maximum client CPU.

## Front end

With the `exe` runner, `benchmarks/run.py` also times the front end inside
`dist/agentica`: `check` of `examples/hello.agc`, of
`stdlib/bdd/gherkin.agc` and of `compiler/syntax/parser.agc` (`check` checks
every body, with or without a `main`), of a three-line `main` that imports
gherkin, and of `compiler/front_end.agc`, and one `agentica test` of a one-test
file. The heading of the table prints the load average, and says "measured
under load" when the one-minute load is above 2. CI does not gate on these
times. The `gherkin` target is issue #1007.

```sh
python3 benchmarks/run.py --runs 11 --only calls --runners exe
```

`AGENTICA_VM_TRACE=profile agentica check FILE` counts steps and calls per
function and the time per builtin (a profiled run is about a third slower; the
counts are exact). `AGENTICA_VM_TRACE=loader` prints the loader time.

## Tried and dropped

### Lists and sets

- One leaf allocation per 32 pushes was six times slower to build and used 45%
  more memory than slices of one array, so bulk builds must not work that way
  (`docs/vm/17-lists.md` §17.2).
- A `Set.add` that looked the key up before the `put` was 10% to 35% slower
  when every key was new; the single pass stayed.

### VM start-up

All inside the noise or Linux-only: a larger first heap
(`GC_INITIAL_HEAP_SIZE` 4 to 8 MB); `madvise(MADV_POPULATE_READ)` of the
carried front end (0.25 ms); a bump allocator for the small objects of the
load; `GC_DONT_GC=1` as a bound (1.2 ms, which the load's GC pause mostly
takes). Not done: reading the span table in place would save about 1.7 ms but
load the front end with less checking than a file given to `run`.

### The lexer

The lexer made a token every 5 characters or so, and each token cost 150 to 200
steps. A call costs several steps, a `Token` with its positions about 36, and a
scan loop `while set.include?(chars[i])` 9 steps per character, which is the
floor. So a gain comes from fewer calls per token, not from a faster scan.

Tried and dropped: a `List[Bool]` table by code (15 steps per character
against 9); unrolling the name scan by two (8.5 against 9, for more code).
Counted, not built: lexing by pieces split on a marker (about 22 M steps,
needs a marker the text does not hold) and line by line (a line costs more
than the comments save).

### The interpreter loop

Computed-goto dispatch (GCC 14 cannot inline it; `arithmetic` +64%, so the
`switch` stays); `MOVE` as two 8-byte copies (`arithmetic` +24%); separate
`ADD_I`, `SUB_I`, `MUL_I` handlers (layout noise). Kept inside the noise: lazy
span reads and the opcode range check before the jump table (second line of
defence). Not tried: counting `STEP` in a local (every failure path would
store it back before the `longjmp`).

The shared small values left out are in
`docs/vm/05-values-execution-builtins.md` §5.4.
