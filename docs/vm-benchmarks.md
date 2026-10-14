# VM benchmarks

Speed of the VM against CPython, and the HTTP sanity check of roadmap 20c.

## How to run

```sh
make bench                                                      # builds the VM, then runs every program
python3 benchmarks/run.py --runs 5 --size 1 --only knight-tour,calls --runners vm,python
```

`benchmarks/run.py` runs each program in `benchmarks/programs/` on these
runners:

- `exe`: `dist/agentica f.agc`, the whole path from source, start-up included.
  It runs only when `dist/agentica` exists, so run `make exe` first.
- `vm`: `dist/agentica-vm` on precompiled bytecode. Only the VM run is timed.
- `python`: the CPython twin in `benchmarks/python/`.

Options: `--runs N` (timed runs, default 5), `--size N` (scales the work of
every program), `--only a,b`, `--runners exe,vm,python`, and `--no-startup` to
skip the `hello.agc` start-up check.

Every runner must print the same output, or the row is a mismatch and the script
exits 1. A program the VM cannot compile yet shows as `unsupported`, with its
`LOWER-UNSUPPORTED` summary. The Python twins are idiomatic, not step-by-step
copies, so a ratio compares two idiomatic programs.

## Results

Latest run: 2026-10-11, median of 5 runs at size 1, on an AMD Ryzen 5 3550H (4
cores, 12 GB RAM), Debian 13, Racket 9.3 CS, gcc 14.2, Python 3.13.5. The host
is shared with CI, so the numbers are rough.

| Program | Work | VM s | Python s | VM / Python (below 1 is faster) |
|---|---|---:|---:|---:|
| knight-tour | Warnsdorff search with backtracking, 8x8, 22 starts | 0.037 | 0.031 | 1.2 |
| maze-bfs | breadth-first search over four 40x40 mazes | 0.059 | 0.044 | 1.3 |
| traveling-salesman | branch and bound over 9 cities | 0.031 | 0.030 | 1.0 |
| arithmetic | Collatz lengths of 1 to 2500 | 0.044 | 0.040 | 1.1 |
| strings | 2,000 lines built with `+` and interpolation | 0.019 | 0.026 | 0.7 |
| string-library | split, trim, upcase, join, replace and more over non-ASCII text | 0.034 | 0.045 | 0.8 |
| lists | 30 rounds of `push` to 1,000 items, then filter, map, reduce, sort | 0.064 | 0.057 | 1.1 |
| list-build | 20,000 `push` calls, 20,000 `set` calls at scattered indexes, a `for` sum | 0.062 | 0.039 | 1.6 |
| maps | 5 rounds of 6,000 `put` and `get` over 1,009 keys | 0.094 | 0.024 | 3.9 |
| calls | recursive `fib` and 40,000 small helper calls | 0.021 | 0.037 | 0.6 |
| case | an enum instruction list run 5,000 times through `case` | 0.022 | 0.069 | 0.3 |

At size 1 each run takes 20 to 100 ms, so the ratios are rough. The VM rows for
knight-tour, maze-bfs, traveling-salesman and maps come from a run on the PR #80
branch (`--runs 3`), and string-library from PR #81 (also `--runs 3`), on the
same host. The lists and list-build rows come from the 8d run (2026-10-14,
`make bench` with `--runs 7 --only lists,list-build --runners vm,python`, on a
host with other work running, load average about 4). The `list-build` Python
twin appends to one mutable list, which the VM cannot do, so a ratio near 1.6
there is a good result.

Start-up on precompiled bytecode: the VM takes about 1 ms and 2 MB, and CPython
takes 19 ms and 8 MB.

At size 20 (`--runners vm,python --size 20 --no-startup`), the VM takes 1.06 s
on arithmetic against 0.57 s for CPython, 0.31 s on strings against 0.16 s, 0.39
s on calls against 0.26 s, and 0.37 s on case against 0.40 s.

## Lists (roadmap 8d)

The persistent vector of 8d (`docs/vm/17-lists.md`) against a VM built from
master before it (71717e0), on the same host, 2026-10-14. Runs alternate between
the two binaries (`python3 benchmarks/run.py --runners vm`, 5 or 6 rounds of 5
to 7 runs each, the median of the medians). The host had other work running
(load average 1 to 4), so compare the two columns of a row, not rows with
earlier tables.

| Program | Master VM s | This VM s | Max RSS MB (master / this) |
|---|---:|---:|---:|
| lists, size 1 | 0.232 | 0.048 | 6.0 / 5.9 |
| list-build, size 1 (20,000 pushes and sets) | 3.47 | 0.054 | 8.1 / 6.6 |
| list-build, size 2 (40,000) | 14.5 | 0.118 | 10.5 / 7.5 |
| 160,000 pushes in a loop | 68 | 0.09 | 17.2 / 12.4 |
| maze-bfs, size 1 | 0.085 | 0.084 | 6.6 / 6.6 |
| maps, size 1 | 0.164 | 0.154 | 6.0 / 6.0 |

The master time for 160,000 pushes was 68 s here (the design measured 88 s on
another run). `list-build` takes 3.47 s on master at size 1 and about 14.5 s at
size 2, so it is quadratic there, and 0.054 s and 0.118 s on the vector.

Time against the number of pushes in a loop (one `while` loop of
`xs = xs.push(i)`, median of 9 runs):

| Pushes | 20,000 | 40,000 | 80,000 | 160,000 | 320,000 | 640,000 | 1,280,000 |
|---|---:|---:|---:|---:|---:|---:|---:|
| Seconds | 0.016 | 0.029 | 0.049 | 0.092 | 0.169 | 0.340 | 0.663 |

Doubling n multiplies the time by 1.7 to 2.0, far below the gate of 2.5, and
160,000 pushes take 0.09 s against the gate of 1 s. `list-build` itself
(pushes, scattered `set` calls and a `for` sum) takes 0.054, 0.118, 0.229, 0.507
and 0.879 s at sizes 1, 2, 4, 8 and 16 (n = 20,000 times the size): the ratios
are 2.2, 1.9, 2.2 and 1.7.

No other benchmark is slower by more than the noise of the link layout. The
full run at size 4 (5 alternating rounds of 5 runs, median s, master / this VM):
arithmetic 0.271 / 0.269, calls 0.126 / 0.110, case 0.121 / 0.111, knight-tour
0.172 / 0.172, lists 0.841 / 0.161, maps 0.570 / 0.550, maze-bfs 0.220 / 0.222,
string-library 0.100 / 0.102, strings 0.124 / 0.128, traveling-salesman 0.171 /
0.171. Only `strings` (+3.2%) and `string-library` (+2%) are above 2%, and
neither does list work: `strings` loops over a five-item list once per round.
The same binary moves by that much when only its link layout changes. At size 8,
three layouts of each VM (the unchanged link, and 1,000 and 2,600 bytes of
padding in `value.o`) gave `arithmetic` 0.56 to 0.65 s (no lists at all) and
`strings` 0.234 to 0.243 s on master alone. Across the three layouts the means
of this VM against master were: maze-bfs +0.2%, maps -0.8%, knight-tour -1.3%,
arithmetic +0.2% and strings +1.8%; `lists` is 5.6 times faster (1.72 s to 0.31
s at size 8).

## Conclusions

- Start-up is cheap on bytecode but not yet measured from source. A source file
  goes through the Racket front end first, so the `exe` numbers for source →
  result are still missing (roadmap 7g).
- At size 20 the VM is 1.5 to 2 times slower than CPython on arithmetic, strings
  and calls, and as fast on case. It uses about a fifth of the memory: about 2
  MB against 9 to 12 MB. The strings twin uses `"".join`, not repeated `+`, so
  profile before blaming string concatenation.
- Maps are the slow spot: at size 1 they take 3.9 times CPython's time, because
  a map `put` copies a HAMT path. Lists were slow too, because `List.append`
  copied the whole array and n pushes took O(n²) time; the persistent vector of
  roadmap 8d fixed that (160,000 pushes in a loop: 68 s before, 0.09 s now), and
  `lists` now runs as fast as CPython. It comes before any dispatch
  micro-optimization.
- Instruction dispatch and Int arithmetic are the first candidates for the next
  speed item (roadmap 7g).

## HTTP sanity check

`benchmarks/http_bench.py` is not a CI gate. It needs Python 3.10 or newer,
`taskset`, and Node for the load client and one server. It compares
`examples/http_server.agc serve` on the VM with three single-process servers
(Node `http`, a Python asyncio server, and Python's `ThreadingHTTPServer`).
Every server gets the same keep-alive load from Node clients in 4 processes. The
rounds run interleaved under `taskset`, and a round starts only when the machine
is idle.

```sh
make vm
python3 benchmarks/http_bench.py                                          # 40000 requests per run, 8 and 64 connections, 3 rounds
python3 benchmarks/http_bench.py --requests 8000 --rounds 2 --retries 0   # a quick check of the script
```

Results are not recorded yet. They need an idle-machine run (roadmap
[20c-bench](roadmap/20-hybrid-http.md)), and the script marks any round that ran
on a busy machine. The table below fills in after that run.

| Connections | Server | Requests/s | Min to max | p50 ms | p99 ms | Server CPU | Max client CPU |
|---:|---|---:|---|---:|---:|---:|---:|
