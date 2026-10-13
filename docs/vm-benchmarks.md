# VM benchmarks

Speed of the VM against CPython, and the HTTP sanity check of roadmap 20c.

## How to run

```sh
make bench                                                      # builds the VM, then runs every program
python3 benchmarks/run.py --runs 5 --size 1 --only knight-tour,calls --runners vm,python
```

`benchmarks/run.py` runs each program in `benchmarks/programs/` on these runners:

- `exe`: `dist/agentica f.agc`, the whole path from source, start-up included. It runs only when `dist/agentica` exists, so run `make exe` first.
- `vm`: `dist/agentica-vm` on precompiled bytecode. Only the VM run is timed.
- `python`: the CPython twin in `benchmarks/python/`.

Options: `--runs N` (timed runs, default 5), `--size N` (scales the work of every program), `--only a,b`, `--runners exe,vm,python`, and `--no-startup` to skip the `hello.agc` start-up check.

Every runner must print the same output, or the row is a mismatch and the script exits 1. A program the VM cannot compile yet shows as `unsupported`, with its `LOWER-UNSUPPORTED` summary. The Python twins are idiomatic, not step-by-step copies, so a ratio compares two idiomatic programs.

## Results

Latest run: 2026-10-11, median of 5 runs at size 1, on an AMD Ryzen 5 3550H (4 cores, 12 GB RAM), Debian 13, Racket 9.3 CS, gcc 14.2, Python 3.13.5. The host is shared with CI, so the numbers are rough.

| Program | Work | VM s | Python s | VM / Python (below 1 is faster) |
|---|---|---:|---:|---:|
| knight-tour | Warnsdorff search with backtracking, 8x8, 22 starts | 0.037 | 0.031 | 1.2 |
| maze-bfs | breadth-first search over four 40x40 mazes | 0.059 | 0.044 | 1.3 |
| traveling-salesman | branch and bound over 9 cities | 0.031 | 0.030 | 1.0 |
| arithmetic | Collatz lengths of 1 to 2500 | 0.044 | 0.040 | 1.1 |
| strings | 2,000 lines built with `+` and interpolation | 0.019 | 0.026 | 0.7 |
| string-library | split, trim, upcase, join, replace and more over non-ASCII text | 0.034 | 0.045 | 0.8 |
| lists | 30 rounds of `push` to 1,000 items, then filter, map, reduce, sort | 0.089 | 0.030 | 3.0 |
| maps | 5 rounds of 6,000 `put` and `get` over 1,009 keys | 0.094 | 0.024 | 3.9 |
| calls | recursive `fib` and 40,000 small helper calls | 0.021 | 0.037 | 0.6 |
| case | an enum instruction list run 5,000 times through `case` | 0.022 | 0.069 | 0.3 |

At size 1 each run takes 20 to 100 ms, so the ratios are rough. The VM rows for knight-tour, maze-bfs, traveling-salesman, lists and maps come from a run on the PR #80 branch (`--runs 3`), and string-library from PR #81 (also `--runs 3`), on the same host.

Start-up on precompiled bytecode: the VM takes about 1 ms and 2 MB, and CPython takes 19 ms and 8 MB.

At size 20 (`--runners vm,python --size 20 --no-startup`), the VM takes 1.06 s on arithmetic against 0.57 s for CPython, 0.31 s on strings against 0.16 s, 0.39 s on calls against 0.26 s, and 0.37 s on case against 0.40 s.

## Conclusions

- Start-up is cheap on bytecode but not yet measured from source. A source file goes through the Racket front end first, so the `exe` numbers for source → result are still missing (roadmap 7g).
- At size 20 the VM is 1.5 to 2 times slower than CPython on arithmetic, strings and calls, and as fast on case. It uses about a fifth of the memory: about 2 MB against 9 to 12 MB. The strings twin uses `"".join`, not repeated `+`, so profile before blaming string concatenation.
- Lists and maps are the slow spots: at size 1 they take 3.0 and 3.9 times CPython's time. `List.append` copies the whole array, so n pushes take O(n²) time, and a map `put` copies a HAMT path. Persistent vectors (roadmap 8d) come before any dispatch micro-optimization.
- Instruction dispatch and Int arithmetic are the first candidates for the next speed item (roadmap 7g).

## HTTP sanity check

`benchmarks/http_bench.py` is not a CI gate. It needs Python 3.10 or newer, `taskset`, and Node for the load client and one server. It compares `examples/http_server.agc serve` on the VM with three single-process servers (Node `http`, a Python asyncio server, and Python's `ThreadingHTTPServer`). Every server gets the same keep-alive load from Node clients in 4 processes. The rounds run interleaved under `taskset`, and a round starts only when the machine is idle.

```sh
make vm
python3 benchmarks/http_bench.py                                          # 40000 requests per run, 8 and 64 connections, 3 rounds
python3 benchmarks/http_bench.py --requests 8000 --rounds 2 --retries 0   # a quick check of the script
```

Results are not recorded yet. They need an idle-machine run (roadmap [20c-bench](roadmap/20-hybrid-http.md)), and the script marks any round that ran on a busy machine. The table below fills in after that run.

| Connections | Server | Requests/s | Min to max | p50 ms | p99 ms | Server CPU | Max client CPU |
|---:|---|---:|---|---:|---:|---:|---:|
