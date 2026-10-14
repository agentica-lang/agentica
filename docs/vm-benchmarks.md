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
arithmetic 0.272 / 0.289, calls 0.123 / 0.115, case 0.121 / 0.110, knight-tour
0.171 / 0.170, list-build 57.4 / 0.215, list-bulk 0.867 / 0.807, lists 0.873 /
0.168, maps 0.599 / 0.557, maze-bfs 0.224 / 0.224, string-library 0.101 /
0.105, strings 0.127 / 0.135, traveling-salesman 0.167 / 0.166. Only
`arithmetic` (+6%), `strings` (+6%) and `string-library` (+4%) are above 2%,
and none of them does list work: the same binary moves by that much when only
its link layout changes. Padding `list.o` by 48, 400 and 1,500 bytes gave
`arithmetic` 0.270, 0.311 and 0.304 s against 0.270 for master and 0.291 for
the unpadded build, with the same code. At size 8, three layouts of each VM
(the unchanged link, and 1,000 and 2,600 bytes of padding in `value.o`) gave
`arithmetic` 0.56 to 0.65 s (no lists at all) and `strings` 0.234 to 0.243 s on
master alone. Across the three layouts the means of this VM against master were:
maze-bfs +0.2%, maps -0.8%, knight-tour -1.3%, arithmetic +0.2% and strings
+1.8%; `lists` is 5.6 times faster (1.72 s to 0.31 s at size 8).

### Bulk builds and memory

A list built at once (`List.repeat`, `Range.to_a`, `reverse`, `take`, `drop`,
`concat`, `String.split`, `sort`) allocates its trie in a handful of blocks, and
`List.repeat` shares one leaf. The first version of the trie attached one leaf
per 32 pushes, took six times as long as the flat array to build a million
items, and made the GC-stress run of `process-channel-close.agc` miss its 100 ms
window. Milliseconds on 1,000,000 items, median of 7 runs, alternating the three
binaries (master 71717e0, the earlier head 82677b9, this VM); the GC lands in a
different operation from run to run, so read a row to within a few ms:

| Operation | Master | Earlier head | This VM |
|---|---:|---:|---:|
| `List.repeat(7, n)` | 5 | 19 | under 1 |
| `List.repeat("x", n)` | 6 | 15 | under 1 |
| `take(n / 2)` and `drop(n / 2)` | 2 | 21 | 6 |
| `reverse` | 6 | 27 | 5 |
| `(0...n).to_a` | 6 | 60 | 7 |
| `String.split(big, "")` of 1 MB | 95 | 44 | 43 |
| `join("")` | 20 | 30 | 20 |
| `sort` of a scattered list | 300 | 326 | 319 |
| `map` | 97 | 112 | 99 |
| `xs[i]` for every 7th item | 23 | 29 | 30 |
| `for x in xs` sum | 134 | 142 | 142 |
| `filter` | 144 | 157 | 148 |
| `concat` of two halves | 2 | 24 | 5 |
| 20,000 pushes | 2,087 | 7 | 7 |

At this head `take` and `drop` still copied their items (a leaf at a time, with
`memcpy`); the next section shares leaves. Indexing and `for` stay about 1.3 and
1.06 times master, the price of the two to four loads per item. `list-bulk`
(`repeat`, `to_a`, `reverse`, `take`, `drop`, `concat`, `join`, `split` and
`sort`, size 4) takes 0.867 s on master and 0.807 s here.

Peak RSS of a process that builds one list of 1,000,000 items and prints its
size (the start-up cost of the VM is 5.6 MB), median of 3:

| List | Master MB | Earlier head MB | This VM MB |
|---|---:|---:|---:|
| `(0...1000000).to_a` | 21.4 | 28.6 | 21.5 to 22.4 |
| `List.repeat(7, 1000000)` | 21.4 | 28.4 to 29.7 | 5.6 |
| 1,000,000 `push` calls in a loop | not run (quadratic) | 43.4 | 43.5 |

The earlier head spent 45% more than master on the same list, because every
512-byte leaf and 256-byte branch was a separate allocation. Now the leaves of
one build are slices of one array, so the cost over master is the branches, 1.6%
(about 264 KB for a million items). A list grown by pushes holds its leaves
separately and the path copies are garbage until the next collection, which is
why the push loop peaks higher.

### Bulk operations after the trie

The list performance PR (`docs/vm/17-lists.md` §17.11) against the flat array
(0f44c74, before the trie), the trie as merged (ba2bea8) and CPython 3.13.5, on
one host, 2026-10-14. The program is `lb.agc` and its twin `lb.py`: one pass
over 1,000,000 items, each operation timed once with `Time.monotonic_ms`
(median of 7 runs, the three VMs alternating; Python 5 runs). Milliseconds:

| Operation | Python | Flat | Trie | This PR |
|---|---:|---:|---:|---:|
| `sort` of the reversed range | 16 | 180 | 191 | 17 |
| `String.split(big, "")` | 7 | 42 | 85 | 9 |
| `join("")` | 10 | 20 | 20 | 16 |
| `reverse` | 8 | 9 | 23 | 23 |
| `take(n / 2)` and `drop(n / 2)` | 9 | 4 | 8 | under 1 |
| `concat` of the two halves | 7 | 32 | 8 | 26 |
| `map` (`y + 1`) | 69 | 101 | 102 | 103 |
| `filter` (`y % 2 == 0`) | 83 | 156 | 170 | 167 |
| `(0...n).to_a` | 44 | 14 | 11 | 12 |
| `for x in xs` sum | 126 | 131 | 138 | 134 |
| 20,000 pushes | 4 | 2,207 | 7 | 10 |

Read the `reverse` and `concat` rows with the next table. A collection costs
15 to 25 ms here (it scans the 60 to 100 MB of live 16-byte values), the run is
deterministic, and the collections of this program (6 on the trie and on this
PR) fall inside whichever operation allocates when the threshold is crossed. On
the trie and on this PR that is `reverse` and `concat`; on the flat array it
was another operation (36 collections, the quadratic push loop among
them). The sum of the rows is the fair figure: 728 ms (flat), 780 (trie) and
531 (this PR), 20,000 pushes left out.

To take the placement out, each operation ran 20 times in a loop next to the
same live data, and the time of a loop without the operation was subtracted
(median of 3 runs, milliseconds per operation, collections included):

| Operation | Flat | Trie | This PR |
|---|---:|---:|---:|
| `sort`, reversed range | 170 | 174 | 21 |
| `sort`, scattered ints (Python: 173) | 308 | 319 | 100 |
| `String.split(big, "")` | 52 | 65 | 15 |
| `join("")` | 20.5 | 21.6 | 17.6 |
| `reverse` | 12.5 | 11.7 | 11.6 |
| `take` and `drop` of n / 2 | 9.9 | 12.2 | 1.0 |
| `take`, `drop` and `concat` | 16.0 | 20.3 | 7.1 |
| `map` | 100 | 99 | 102 |
| `filter` | 149 | 159 | 162 |

`reverse`, `join`, `map` and `filter` are about where they were: a million-item
operation is an allocation of 16 MB plus its share of the collector (8 of the
11.6 ms of `reverse`; the same reverse into a block that needs no collection
takes 3 ms), and `map` and `filter` are 70 to 100 ns of callback per item.
`filter` moved by 2% between builds that differ only in unrelated code, which
is the noise of the link layout. `sort` of a list in order (or strictly
descending) is O(n); a scattered list is 3 times faster, mainly because the keys
are read once and compared as `uint64_t`.

`list-bulk` (size 2, median of 3 runs, two alternating rounds) takes 0.44 s on
the trie and 0.22 s here (CPython: 0.455 s); `lists`, `list-build` and `maps`
are 0.079 / 0.076, 0.105 / 0.104 and 0.29 / 0.28 s (trie / this PR), inside the
noise. Peak RSS of `list-bulk` is 66 to 83 MB on the trie and 65 to 73 MB here.

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
