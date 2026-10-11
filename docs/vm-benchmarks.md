# VM benchmarks

Speed numbers for the roadmap's 7g speed check. Phase 12 adds a cross-language section here later.

## How to run

```sh
make build vm exe          # exe is optional: dist/agentica is timed when it exists
make bench                 # same as: python3 benchmarks/run.py
python3 benchmarks/run.py --runs 5 --size 1 --only knight-tour,calls --runners evaluator,vm,python
```

`benchmarks/run.py` (Python standard library only) runs each program in `benchmarks/programs/` on four runners:

| Runner | Command | What is timed |
|---|---|---|
| `evaluator` | `racket src/main.rkt f.agc` | the whole run, start-up included |
| `exe` | `dist/agentica f.agc` (if built with `make exe`) | the whole run, start-up included |
| `vm` | `racket src/main.rkt compile f.agc -o f.agcb`, then `dist/agentica-vm -- f.agcb` | only the VM run; compiling happens once, untimed |
| `python` | `python3 benchmarks/python/<name>.py SIZE` | the whole run, an idiomatic CPython version as an outside reference |

For each program and runner it does one warm-up run under `/usr/bin/time -f %M` for the peak RSS, then `--runs` timed runs (default 5), and reports the median and the minimum wall time. Every run must print the same stdout as the first runner that succeeded; a different output is a `mismatch` and the script exits 1. A program the VM cannot compile yet is reported as `unsupported` with the `LOWER-UNSUPPORTED` reason. `hello.agc` start-up is measured apart (`--no-startup` skips it).

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

The VM today has no `List`/`Map`/`String` library functions (`docs/vm.md` §12.2 item 6b), so `knight-tour`, `maze-bfs`, `traveling-salesman`, `lists` and `maps` are unsupported on it. They stay written the idiomatic way (`push`, `size`, `set`, `put`, `get`) rather than bent around the gap; they run on the VM once 6b lands.

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
| knight-tour | vm | unsupported (`List.append`) | | | |
| knight-tour | python | 0.031 | 0.027 | 9.1 | 74.0x |
| maze-bfs | evaluator | 0.955 | 0.870 | 144.1 | 1.0x |
| maze-bfs | exe | 1.036 | 0.983 | 144.5 | 0.9x |
| maze-bfs | vm | unsupported (`Map.put`) | | | |
| maze-bfs | python | 0.044 | 0.039 | 9.6 | 21.6x |
| traveling-salesman | evaluator | 1.331 | 1.310 | 146.1 | 1.0x |
| traveling-salesman | exe | 1.218 | 1.194 | 148.1 | 1.1x |
| traveling-salesman | vm | unsupported (`List.size`) | | | |
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
| lists | vm | unsupported (`List.append`) | | | |
| lists | python | 0.030 | 0.027 | 9.0 | 40.1x |
| maps | evaluator | 1.005 | 0.980 | 144.1 | 1.0x |
| maps | exe | 0.973 | 0.942 | 148.4 | 1.0x |
| maps | vm | unsupported (`Map.put`) | | | |
| maps | python | 0.024 | 0.023 | 9.0 | 42.3x |
| calls | evaluator | 1.195 | 1.181 | 144.1 | 1.0x |
| calls | exe | 1.256 | 1.176 | 149.7 | 1.0x |
| calls | vm | 0.021 | 0.021 | 1.8 | 57.2x |
| calls | python | 0.037 | 0.035 | 8.8 | 32.7x |
| case | evaluator | 0.994 | 0.991 | 144.2 | 1.0x |
| case | exe | 1.041 | 1.030 | 148.6 | 1.0x |
| case | vm | 0.022 | 0.021 | 1.9 | 46.1x |
| case | python | 0.069 | 0.068 | 12.4 | 14.5x |

At size 1 the VM programs finish in about 20 to 40 ms, so their ratios are dominated by the evaluator's start-up. A second run with more work shows the VM against CPython (`--runners vm,python --only arithmetic,strings,calls,case --size 20 --no-startup`):

| Program | VM median s | Python median s | VM max RSS MB | Python max RSS MB |
|---|---:|---:|---:|---:|
| arithmetic | 1.056 | 0.573 | 1.9 | 9.1 |
| strings | 0.313 | 0.157 | 1.8 | 8.8 |
| calls | 0.391 | 0.262 | 2.0 | 8.9 |
| case | 0.374 | 0.397 | 1.9 | 12.1 |

### Reading

- Start-up: the VM starts in about 1 ms and 2 MB; the evaluator needs 0.6 to 0.8 s and about 145 MB (Racket CS boot plus loading the front end), and the `raco exe` build is only slightly faster.
- Where it runs, the VM is about 45x to 60x faster than the evaluator per program at size 1, start-up included. Most of that gap is the evaluator's start-up: subtracting the `hello.agc` median leaves about 1.2 s for `arithmetic` (about 28x the VM), 0.35 s for `calls` (about 17x) and 0.15 s for `case` (about 7x), while `strings` is within the noise of start-up. Larger sizes are needed to compare the evaluator's run time itself.
- Against CPython the VM is in the same range: as fast on `case`, 1.5x to 2x slower on `arithmetic`, `strings` and `calls` at size 20, with about a fifth of the memory. These are the first hot-spot candidates for the next 7g item (instruction dispatch, Int arithmetic, string concatenation).
- The evaluator, start-up included, is 15x to 75x slower than CPython on every program.
- The three real programs, `lists` and `maps` cannot be compared on the VM until the `List`/`Map` library lands (`docs/vm.md` §12.2 item 6b); rerun this page then.
