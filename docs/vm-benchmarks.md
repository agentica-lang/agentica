# VM benchmarks

Speed numbers for the roadmap's 7g speed check. The server measurement (roadmap 7j) adds a server section here, and phase 12 a cross-language section, later.

## How to run

```sh
make build vm exe          # exe is optional: dist/agentica is timed whenever it exists, so rebuild it after a change or leave it out with --runners
make bench                 # same as: python3 benchmarks/run.py
python3 benchmarks/run.py --runs 5 --size 1 --only knight-tour,calls --runners evaluator,vm,python
```

`benchmarks/run.py` (Python standard library only) runs each program in `benchmarks/programs/` on four runners:

| Runner | Command | What is timed |
|---|---|---|
| `evaluator` | `racket src/main.rkt f.agc` | the whole run, start-up included |
| `exe` | `dist/agentica f.agc` (only if it exists; `make bench` does not rebuild it, run `make exe` first) | the whole run, start-up included |
| `vm` | `racket src/main.rkt compile f.agc -o f.agcb`, then `dist/agentica-vm -- f.agcb` | only the VM run; compiling happens once, untimed |
| `python` | the interpreter running the script (`sys.executable`) on `benchmarks/python/<name>.py SIZE` | the whole run, an idiomatic CPython version as an outside reference |

The `vm` runner times only the VM on precompiled bytecode. A user who runs a source file with `agentica --vm f.agc` also pays for starting Racket, checking and compiling, which this table does not show. Runners that time that whole source → result path (`racket src/main.rkt --vm f.agc` and `dist/agentica --vm f.agc`) are planned next to the `vm` runner (roadmap 7g).

For each program and runner it does one warm-up run under GNU `/usr/bin/time -f %M` for the peak RSS (without GNU time the RSS column shows `n/a`), then `--runs` timed runs (default 5), and reports the median and the minimum wall time. Every run must print the same stdout as the first runner that succeeded; a different output is a `mismatch`, and a `failed` or `mismatch` row (start-up rows included) makes the script exit 1. A program the VM cannot compile yet is reported as `unsupported` with a one-line summary of the `LOWER-UNSUPPORTED` diagnostic. `hello.agc` start-up is measured apart (`--no-startup` skips it).

`--size N` multiplies the work of every program: each `.agc` has a `def scale() -> Int` that returns 1, which the script rewrites to N in a temporary copy, and each Python version takes N as its first argument. Size 1 keeps every program at a few seconds at most on the evaluator.

The programs print a deterministic checksum and use only fixed inputs (a seeded linear congruential generator where they need data):

| Program | Work |
|---|---|
| `knight-tour` | Warnsdorff search with backtracking on 8x8 from 22 start squares |
| `maze-bfs` | four 40x40 generated mazes, breadth-first search with `Map` queues, as in `examples/maze-bfs.agc` |
| `traveling-salesman` | branch and bound over 9 generated cities, as in `examples/traveling-salesman.agc` |
| `arithmetic` | Collatz lengths of 1..2500 (`Int` `%`, `/`, `*`, `while`) |
| `strings` | 2,000 lines built with `+` and interpolation |
| `lists` | 30 rounds of `push` to 1,000 items, `filter`, `map`, `reduce`, `sort`, `any?`, indexing |
| `maps` | 5 rounds of 6,000 `put`/`get` counts over 1,009 keys, `has_key?`, `delete`, `keys` |
| `calls` | recursive `fib(20)`/`fib(21)` and 40,000 small helper calls |
| `case` | an `enum` instruction list run 5,000 times through `case`, plus `case` on `Int` literals |
| `string-library` | 300 rounds of `split`, `trim`, `upcase`, `join`, `replace`, `downcase` (final sigma), `index_of` and `at` over every code point of non-ASCII text |

The VM has the `List` and `Map` library since PR #80 and the `String` library since PR #81; of `docs/vm/12-testing-and-pr-plan.md` §12.2 item 6b only `Float`, `Time` and `Random` are still missing, and none of these programs needs them. The programs stay written the idiomatic way (`push`, `size`, `set`, `put`, `get`). The tables below were measured before PR #80, so their VM rows for `knight-tour`, `maze-bfs`, `traveling-salesman`, `lists` and `maps` come from a later run, described under the programs table.

The Python versions are idiomatic CPython, not step-by-step copies: they compute the same result but use Python's own tools. `strings` builds each line with `"".join` over f-string parts where the Agentica version uses repeated `+`; `arithmetic` sums a list comprehension; `knight_tour` and `traveling_salesman` mutate one `visited` list and path in place and undo the change on backtrack, where Agentica builds new values; `maze_bfs` uses a `deque` and a `set`. So a ratio against Python compares two idiomatic programs, not two interpreters on identical steps.

## Results, 2026-10-11

The host is shared with the self-hosted CI runners, so other jobs may run at the same time: treat the numbers as rough (the evaluator's median and minimum differ by up to 30% in places).

- Machine: AMD Ryzen 5 3550H (4 cores, 8 threads), 12 GB RAM.
- OS: Debian GNU/Linux 13 (trixie), Linux 6.12.107+deb13-amd64.
- Tools: Racket v9.3 [cs], gcc 14.2.0 (Debian 14.2.0-19), `make vm` flags (`-O2`, Boehm GC from the submodule), Python 3.13.5.
- Code: `master` at `b28c1b1`, `python3 benchmarks/run.py` (size 1, 5 runs).

### Start-up (`hello.agc`)

| Runner | Median s | Min s | Max RSS MB |
|---|---:|---:|---:|
| evaluator | 0.845 | 0.692 | 144.1 |
| exe | 0.615 | 0.559 | 140.4 |
| vm | 0.001 | 0.001 | 1.7 |
| python (`-c "print('hello')"`) | 0.019 | 0.018 | 8.3 |

### Programs (size 1)

"vs evaluator" is the evaluator's median divided by the runner's median. The evaluator and `exe` times include their 0.6 to 0.8 s start-up.

| Program | Runner | Median s | Min s | Max RSS MB | vs evaluator |
|---|---|---:|---:|---:|---:|
| knight-tour | evaluator | 2.311 | 2.299 | 144.1 | 1.0x |
| knight-tour | exe | 1.283 | 1.235 | 148.7 | 1.8x |
| knight-tour | vm | 0.037 | 0.033 | 2.4 | 33.3x* |
| knight-tour | python | 0.031 | 0.027 | 9.1 | 74.0x |
| maze-bfs | evaluator | 0.955 | 0.870 | 144.1 | 1.0x |
| maze-bfs | exe | 1.036 | 0.983 | 144.5 | 0.9x |
| maze-bfs | vm | 0.059 | 0.050 | 3.0 | 18.5x* |
| maze-bfs | python | 0.044 | 0.039 | 9.6 | 21.6x |
| traveling-salesman | evaluator | 1.331 | 1.310 | 146.1 | 1.0x |
| traveling-salesman | exe | 1.218 | 1.194 | 148.1 | 1.1x |
| traveling-salesman | vm | 0.031 | 0.030 | 2.1 | 38.5x* |
| traveling-salesman | python | 0.030 | 0.027 | 9.2 | 43.8x |
| arithmetic | evaluator | 2.065 | 1.513 | 143.9 | 1.0x |
| arithmetic | exe | 1.453 | 1.416 | 148.1 | 1.4x |
| arithmetic | vm | 0.044 | 0.041 | 1.9 | 46.4x |
| arithmetic | python | 0.040 | 0.039 | 8.8 | 51.4x |
| strings | evaluator | 0.893 | 0.745 | 144.7 | 1.0x |
| strings | exe | 0.873 | 0.759 | 148.8 | 1.0x |
| strings | vm | 0.019 | 0.019 | 1.9 | 47.1x |
| strings | python | 0.026 | 0.021 | 8.8 | 33.9x |
| lists | evaluator | 1.205 | 1.160 | 143.8 | 1.0x |
| lists | exe | 1.332 | 1.256 | 159.6 | 0.9x |
| lists | vm | 0.089 | 0.083 | 2.2 | 15.3x* |
| lists | python | 0.030 | 0.027 | 9.0 | 40.1x |
| maps | evaluator | 1.005 | 0.980 | 144.1 | 1.0x |
| maps | exe | 0.973 | 0.942 | 148.4 | 1.0x |
| maps | vm | 0.094 | 0.091 | 2.4 | 11.1x* |
| maps | python | 0.024 | 0.023 | 9.0 | 42.3x |
| calls | evaluator | 1.195 | 1.181 | 144.1 | 1.0x |
| calls | exe | 1.256 | 1.176 | 149.7 | 1.0x |
| calls | vm | 0.021 | 0.021 | 1.8 | 57.2x |
| calls | python | 0.037 | 0.035 | 8.8 | 32.7x |
| case | evaluator | 0.994 | 0.991 | 144.2 | 1.0x |
| case | exe | 1.041 | 1.030 | 148.6 | 1.0x |
| case | vm | 0.022 | 0.021 | 1.9 | 46.1x |
| case | python | 0.069 | 0.068 | 12.4 | 14.5x |

\* From a later run on the PR #80 branch: `python3 benchmarks/run.py --runs 3 --only knight-tour,maze-bfs,traveling-salesman,lists,maps`, on the same shared host, so other jobs may have run at the same time. The ratio is against that run's evaluator medians (knight-tour 1.249 s, maze-bfs 1.097 s, traveling-salesman 1.180 s, lists 1.368 s, maps 1.043 s); CPython there took 0.028 to 0.036 s for each of the five.

At size 1 the VM programs finish in about 20 to 40 ms, so their ratios are dominated by the evaluator's start-up. A second run with more work shows the VM against CPython (`--runners vm,python --only arithmetic,strings,calls,case --size 20 --no-startup`):

| Program | VM median s | Python median s | VM max RSS MB | Python max RSS MB |
|---|---:|---:|---:|---:|
| arithmetic | 1.056 | 0.573 | 1.9 | 9.1 |
| strings | 0.313 | 0.157 | 1.8 | 8.8 |
| calls | 0.391 | 0.262 | 2.0 | 8.9 |
| case | 0.374 | 0.397 | 1.9 | 12.1 |

### Reading

- Start-up: the VM starts in about 1 ms and 2 MB on precompiled bytecode; the evaluator needs 0.6 to 0.8 s and about 145 MB (Racket CS boot plus loading the front end), and the `raco exe` build is only slightly faster. Running a source file on the VM (`agentica --vm f.agc`) still goes through that Racket front end, so its real start-up is the evaluator's plus the compile time, not 1 ms; the source → result runners of roadmap 7g will measure it.
- Where it runs, the VM is about 45x to 60x faster than the evaluator per program at size 1, start-up included. Most of that gap is the evaluator's start-up: subtracting the `hello.agc` median leaves about 1.2 s for `arithmetic` (about 28x the VM), 0.35 s for `calls` (about 17x) and 0.15 s for `case` (about 7x), while `strings` is within the noise of start-up. Larger sizes are needed to compare the evaluator's run time itself.
- Against CPython the VM is in the same range: as fast on `case`, 1.5x to 2x slower on `arithmetic`, `strings` and `calls` at size 20, with about a fifth of the memory. Instruction dispatch and Int arithmetic are the first hot-spot candidates for the next 7g item. The `strings` gap is weaker evidence, since the Python twin uses `"".join` rather than repeated `+`; profile before blaming string concatenation.
- The evaluator, start-up included, is 14.5x to 74x slower than CPython on every program.
- With the `List`/`Map` library (PR #80) the three real programs, `lists` and `maps` run on the VM in 31 to 94 ms at size 1, 11x to 39x faster than the evaluator with its start-up. `knight-tour` and `traveling-salesman` are about as fast as CPython; `maze-bfs`, `lists` and `maps` are 1.6x to 3.1x slower, which fits arrays copied on every `push`/`set`: `List.append` copies the whole array, so building a list with n pushes is O(n²) (persistent vectors come with 8d, which the roadmap puts before any dispatch micro-optimization) and map puts that copy a HAMT path.
- `string-library` was added after this run with the `String` library on the VM (PR #81, `--runs 3`): at size 1 the evaluator takes 3.645 s, the VM 0.034 s (107x) and Python 0.045 s; at size 20 the VM takes 0.327 s and Python 0.103 s (1.9 MB against 9.3 MB). `at` over non-ASCII text is O(1) per call through the VM's string cursor (`docs/vm/02-reference-behavior.md` §2.3); the Python twin uses `sum` over the characters and `str.find`.
