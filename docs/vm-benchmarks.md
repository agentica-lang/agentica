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
  It runs only when `dist/agentica` exists, so run `make` first.
- `vm`: `dist/agentica run` on bytecode that `agentica compile` wrote. Only the
  VM run is timed.
- `python`: the CPython twin in `benchmarks/python/`.

Options: `--runs N` (timed runs, default 5), `--size N` (scales the work of
every program), `--only a,b`, `--runners exe,vm,python`, and `--no-startup` to
skip the `hello.agc` start-up check and the front-end rows (see "Front end").

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

## Unboxed numeric leaves (roadmap 8d step 3)

A list whose items are all Int, or all Float, stores 8 bytes per item and no tag
(`docs/vm/17-lists.md` §17.12). Master (88b9dbb) against this VM, and CPython
3.13.5, 2026-10-15, on the same host as above (Ryzen 5 3550H, gcc 14.2, Debian
13, load average 1 to 3 from other work). The program is `lb2.agc` and its twin
`lb2.py` (scratch files, not in the repo, like `lb.agc`): one case per process
on a list of 1,000,000 items, built outside the timing, the operation repeated
`reps` times inside one run and the total divided by `reps`. Median of 5 runs,
with the three binaries alternating and their order rotated each round.
Milliseconds per operation, and peak RSS of the whole process in MB
(`/usr/bin/time -f %M`, start-up 5.6 MB included, the base list included):

| Int list | Master ms | This VM ms | Ratio | Python ms | Master MB | This VM MB | Python MB |
|---|---:|---:|---:|---:|---:|---:|---:|
| `(0...n).to_a` | 5.8 | 4.8 | 0.82 | 56.6 | 37.6 | 30.2 | 47.9 |
| 100,000 `push` calls | 38.8 | 30.0 | 0.77 | 6.8 | 10.8 | 7.2 | 13.5 |
| `map` (`y + 1`) | 102.4 | 97.2 | 0.95 | 78.8 | 37.3 | 22.0 | 88.2 |
| `filter` | 165.2 | 149.4 | 0.90 | 81.6 | 61.6 | 53.1 | 51.9 |
| `sort`, in order | 10.7 | 8.3 | 0.77 | 15.0 | 69.2 | 45.5 | 55.5 |
| `sort`, reversed | 15.9 | 10.9 | 0.69 | 17.4 | 116.5 | 92.4 | 55.6 |
| `sort`, scattered | 100.6 | 70.6 | 0.70 | 189.0 | 115.5 | 98.7 | 61.2 |
| `for x in xs` sum | 134.6 | 133.8 | 0.99 | 48.4 | 21.8 | 13.8 | 48.0 |
| `xs[i]` for every 7th item | 23.7 | 23.6 | 1.00 | 16.8 | 21.9 | 14.0 | 47.9 |
| `take`, `drop`, `concat` | 6.6 | 2.2 | 0.33 | 18.3 | 46.4 | 32.8 | 67.0 |
| `List.repeat(7, n)` | under 0.01 | under 0.01 | | 1.7 | 5.8 | 5.9 | 17.5 |

| Float list | Master ms | This VM ms | Ratio | Python ms | Master MB | This VM MB | Python MB |
|---|---:|---:|---:|---:|---:|---:|---:|
| `map` of an Int list to Float | 111.8 | 102.4 | 0.92 | 108.6 | 37.5 | 22.0 | 88.2 |
| 100,000 `push` calls | 47.0 | 38.0 | 0.81 | 12.4 | 10.7 | 7.2 | 13.7 |
| `map` (`y * 1.5`) | 103.8 | 98.0 | 0.94 | 81.6 | 37.7 | 29.8 | 86.2 |
| `filter` | 105.4 | 104.2 | 0.99 | 44.6 | 61.1 | 68.0 | 51.8 |
| `sort`, in order | 11.5 | 9.4 | 0.81 | 16.6 | 100.0 | 67.9 | 55.6 |
| `sort`, reversed | 17.2 | 11.5 | 0.67 | 17.8 | 69.3 | 76.6 | 55.6 |
| `sort`, scattered | 104.8 | 73.4 | 0.70 | 175.6 | 100.7 | 98.8 | 61.3 |
| `for x in xs` sum | 137.6 | 93.0 | 0.68 | 31.4 | 37.4 | 22.0 | 48.0 |
| `xs[i]` for every 7th item | 18.0 | 17.5 | 0.97 | 14.1 | 37.2 | 22.0 | 48.0 |
| `take`, `drop`, `concat` | 7.1 | 2.6 | 0.36 | 18.6 | 62.4 | 30.2 | 67.0 |
| `List.repeat(2.5, n)` | under 0.01 | under 0.01 | | 4.6 | 5.9 | 5.9 | 17.4 |

A `List[String]` is a boxed list and must not get slower. The same cases on
strings (`List.repeat("abc", n)` as the base, `upcase`, and a scattered sort of
`to_s` keys):

| String list | Master ms | This VM ms | Ratio | Python ms | Master MB | This VM MB | Python MB |
|---|---:|---:|---:|---:|---:|---:|---:|
| 100,000 `push` calls | 50.8 | 51.6 | 1.02 | 4.6 | 10.8 | 10.8 | 10.6 |
| `map` (`upcase`) | 221.0 | 211.0 | 0.95 | 115.4 | 77.8 | 77.8 | 73.0 |
| `sort`, scattered | 543.6 | 593.4 | 1.09 | 466.6 | 132.7 | 155.8 | 76.6 |
| `for x in xs`, `length` | 165.8 | 171.8 | 1.04 | 55.8 | 5.7 | 5.8 | 17.4 |
| `xs[i]` for every 7th item | 26.8 | 27.9 | 1.04 | 21.5 | 5.7 | 5.8 | 17.4 |
| `take`, `drop`, `concat` | 5.9 | 6.5 | 1.09 | 5.7 | 22.8 | 39.1 | 36.4 |
| `List.repeat("x", n)` | under 0.01 | under 0.01 | | 1.8 | 5.9 | 5.9 | 17.4 |

How to read the tables:

- The int and float rows that gain are the ones that move or compare raw words:
  `sort` (the sorted entries carry the item, so there is no second read of the
  list), `take`, `drop`, `concat` and `reverse` (half the bytes to copy), the
  pushes, and the Float `for` sum. A million-item Int list is 8 MB instead of
  16 MB, so the process that only holds one peaks 8 MB lower (`for` sum: 21.8
  to 13.8 MB, Python 48.0). `map` and `filter` are dominated by the 70 to 100 ns
  of the callback per item, and the Int `for` sum and `xs[i]` by the dispatch
  loop; they do not change. The Float `for` sum is 32% faster in every run, in
  the three probe rounds and in this one, while the Int sum is unchanged; the
  loop runs the same instructions, and no cause was found, so treat it as a
  bonus and not as a result.
- Peak RSS also depends on when the collector runs. Master and this VM make the
  same allocations in the string cases (`GC_PRINT_STATS=1` shows the same
  collections and a heap of 34 MB at the end), yet the pages the allocator
  touches differ: `take`, `drop`, `concat` shows 22.8 against 39.1 MB for
  strings, and master alone gave 39.8 MB in one of 6 runs. Read a row of RSS to
  within 15 MB or so. The 8 MB that an Int or Float list saves per million
  items is exact; the rest of a row is the heap the collector chose.
- The string rows are the boxed path, which is the old code with one more
  branch on the kind. The ratios are 0.95 to 1.09. The link layout of an
  unrelated change moves these loops by 4 to 6% (a loop of plain `while`
  arithmetic with no list ran 5% faster on this VM than on master), so the +4%
  of the `for` and `xs[i]` rows is inside what a rebuild does. `take`, `drop`,
  `concat` takes 6 ms, and master alone ranged from 2.7 to 7.1 ms in 11 runs.
  `sort` of strings is the one row that looks real: +5% in 11 alternating runs
  (539 ms for master and 566 for this VM, medians). It is a small price, and
  not chased.

The C operations (`vm/list.c` alone, 1,000,000 Int items, a loop around each
call, milliseconds per call, master against this VM): `concat` of two halves
2.3 to 0.8, `reverse` 2.7 to 1.3, 100,000 appends 27 to 12, `agc_list_get` of
every 7th item 1.0 to 0.91, a cursor scan 1.57 to 1.49, a builder run of a
million pushes 4.6 to 4.4 or 5.2.

The `benchmarks/run.py` programs (`--runs 3 --size 2 --runners vm`, the master
binary built apart from master, three invocations per binary alternating, median
of the three medians), seconds:

| Program | Master | This VM | Ratio | CPython | Master MB | This VM MB |
|---|---:|---:|---:|---:|---:|---:|
| lists | 0.076 | 0.069 | 0.91 | 0.056 | 5.9 | 5.7 |
| list-build | 0.106 | 0.087 | 0.82 | 0.043 | 8.2 | 6.5 |
| list-bulk | 0.227 | 0.147 | 0.65 | 0.446 | 65.0 | 38.6 |
| maps | 0.286 | 0.302 | 1.06 | 0.045 | 6.0 | 6.1 |
| arithmetic | 0.127 | 0.125 | 0.98 | 0.090 | 5.5 | 5.5 |

`maps` and `arithmetic` do not use numeric lists in a hot loop; their +6% and
-2% are the layout noise above. `list-bulk` is the one that sorts, reverses and
slices lists of ints: 1.5 times faster and 40% less peak memory.

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

## Sets (8b)

`Set[T]` is a map with nil values (`vm/map.c`), so it shares the HAMT, and a
member of a set costs the same as a key of a map. The numbers are from the PR of
roadmap 8b on a release build (`make vm`), 8 cores, Linux, a quiet host.

`sets` (`benchmarks/programs/sets.agc`, twin `benchmarks/python/sets.py`; the
twin keeps first-insertion order with a `dict`): 5 rounds of 6,000 `add` over
1,009 values, 6,000 `include?`, 336 `delete` calls, and a `union`,
`intersection` and `difference` with a 500-element set, then a `for` over the
result. Median of 7 runs, size 1: 0.101 s on the VM and 0.041 s in CPython, 6.1
MB peak (`maps`, the same shape of work, in the same run: 0.160 s against 0.033
s). At size 10, 0.854 s against 0.170 s.

The operation cost against the map call that does the same work is measured by a
throwaway program (not committed) that adds 100,000 distinct keys, then looks up
400,000 keys with 40,002 hits, one structure per VM run so that the collector
sees the same heap; ns per call, rounds two and three of three (the first round
pays for the heap growth):

| Operation | Map | Set |
|---|---:|---:|
| Int keys, `put` / `add` | 4,200 to 4,750 | 3,800 to 4,770 |
| Int keys, `has_key?` / `include?` | 466 to 474 | 493 to 526 |
| String keys, `put` / `add` | 5,050 to 5,340 | 5,270 to 5,730 |
| String keys, `has_key?` / `include?` | 922 to 950 | 912 to 995 |

`Set.add` of a member allocates nothing (`agc_map_add_hash` returns the same
map), while `Map.put` of an existing key copies its path. A first version that
looked the key up before the `put` made `add` 10% to 35% slower than `put` when
every key was new; the single pass removed that cost.

`intersection` and `difference` first count the elements they keep with lookups
only, and return the first set itself when none is dropped. On a 300,000-element
set this took 3,455 ms when it built a copy that nothing needed; the count pass
takes about 150 ms (an `intersection` of two equal sets) or 19 ms (a `difference`
with an empty set). When half the elements go, the second pass builds the
result: about 1.8 s for 150,000 puts. `Test.eq` and `subset?` on two equal
sets of 300,000 take about 145 ms.

## Struct update (15c)

`value.with(f: x)` lowers to one `STRUCT_WITH` instruction that copies the
struct and writes the given fields. The first plan was the constructor
(`FIELD` for each field that stays, then `STRUCT`, no VM change), so both were
built and measured by throwaway programs (not committed) on a release build,
8 cores, Linux, a quiet host. Each program updates a struct 1,000,000 times in
a `while` loop; the table is the best of 7 wall times in ms, and the empty
loop alone takes 108 to 111 ms.

| Struct and update | Constructor | `STRUCT_WITH` |
|---|---:|---:|
| 2 fields, 1 changed | 197 | 212 |
| 4 fields, 1 changed | 289 | 240 |
| 8 fields (one `String`), 1 changed | 380 | 280 |
| 8 fields, 2 changed | 443 | 368 |
| 16 fields, 1 changed | 567 | 373 |
| 8 fields, `step(s.with(...))` as a tail call, 1M iterations | 570 | 485 |

The constructor needs one instruction for each field that stays, so its cost
grows with the field count; `STRUCT_WITH` is one `memcpy` of the fields and one
store for each changed field, and it charges the copy by size as `CONCAT` does
(the first measurement, 206 and 273 ms for 2 and 8 fields, was before the
charge; it costs 3% to 5%). For two fields the two have the same instruction
count and the new handler costs about 8% more. The instruction stayed because
the case it is for, a lexer or parser state of 4 to 16 fields in a
tail-recursive `step`, is 15% to 34% faster.

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

Results are not recorded yet. They need an idle-machine run (roadmap
[20c-bench](roadmap/20-hybrid-http.md)), and the script marks any round that ran
on a busy machine. The table below fills in after that run.

| Connections | Server | Requests/s | Min to max | p50 ms | p99 ms | Server CPU | Max client CPU |
|---:|---|---:|---|---:|---:|---:|---:|

## Front end (post-bootstrap row 3)

With the `exe` runner, `benchmarks/run.py` also times the front end inside
`dist/agentica` (§35.2): `check` of `examples/hello.agc`, of
`stdlib/bdd/gherkin.agc` and of `compiler/parser.agc` (both have no `main`, so
`check` ends with `CHECK-MAIN`, exit 1, after lexing, parsing, linking and
registering the declarations), of a three-line `main` that imports gherkin (the
full check of its bodies), and of `compiler/front_end.agc` (the whole front
end), and one `agentica test` of a one-test file. The heading of the table
prints the load average, and says "measured under load" when the one-minute
load is above 2. CI does not gate on these times.

```sh
python3 benchmarks/run.py --runs 11 --only calls --runners exe
```

### Speed pass, first part

Before is master (34724435), after is this PR (the profiler, and the BDD runner
and the default steps carried by the binary). Both binaries ran alternately
(A B A B, 5 rounds of 5 runs, the median of the round medians), on an AMD Ryzen
5 3550H (4 cores, 8 threads), Debian 13, gcc 14.2; the load average was 0.5 to
1.5 (not under load). The resident sizes did not change (hello 14.7 MB,
gherkin 21 MB, parser 34 MB, `front_end.agc` 89 MB).

| command | before s | after s |
|---|---:|---:|
| `check examples/hello.agc` | 0.0266 | 0.0264 |
| `check stdlib/bdd/gherkin.agc` | 0.131 | 0.129 |
| `check compiler/parser.agc` | 0.420 | 0.414 |
| `test` of a file with one unit test | 0.868 | 0.051 |
| `test` of a feature with two scenarios | 0.930 | 0.112 |

The only change in this part that touches a run is the last two rows: `agentica
test` used to compile `std/test/runner` (15,346,072 VM steps, 0.73 s) and the
default step program `std/bdd` (2,859,782 steps, 0.15 s) on every run. The
compiles are done when the binary is built. The VM benchmarks (`b-*.agcb` at scale 10,
alternating, medians) moved between 0.85 and 1.04 times the old binary, which
is the link-layout noise of this file (the padding experiments above), not a
cost of the profiler: the profile hooks live in a second copy of the turn loop
that only a run with `AGENTICA_VM_TRACE=profile` enters.

### Where the front end spends its time

`AGENTICA_VM_TRACE=profile agentica check FILE` counts steps and calls per
function and the time per builtin (a profiled run is about a third slower; the
counts do not change from run to run). Totals:

| command | steps | calls | builtin calls | GC runs |
|---|---:|---:|---:|---:|
| `check examples/hello.agc` | 27,946 | 1,843 | 2,263 | 7 |
| `check stdlib/bdd/gherkin.agc` | 2,833,726 | 145,025 | 139,844 | 12 |
| `check compiler/parser.agc` | 11,153,906 | 565,139 | 551,692 | 16 |
| `check compiler/front_end.agc` | 76,512,688 | 4,402,340 | 3,880,861 | 38 |

For `front_end.agc`, the lexer is 51% of the steps (`lexer.agc` 38.9 M, then
`parser.agc` 12.7 M, `parse_base.agc` 5.9 M, `check_expr.agc` 3.3 M,
`source.agc` 3.2 M, `types.agc` 2.7 M). The functions with most steps: `lex`
9.3 M (91 calls), `skip_in` 5.0 M (75,866 calls), `scan_name` 3.3 M,
`Source.position` 3.2 M (356,264 calls), `skip_until` 3.1 M, the closure that
makes the character codes in `new_input` 2.4 M (811,496 calls, one per source
character), `skip_blanks` 2.1 M, then `check_expression`, `parse_postfix`,
`scan_operator`, `expect`, `operator_lexeme`, `parse_climb`. The builtins that
took the most time (profiled run): `List.set` 109 ms (44,404 calls), `Map.put`
105 ms (24,793), `Set.include?` 101 ms (768,275), `List.append` 97 ms
(283,996), `ok` 86 ms (622,089), `String.slice` 57 ms, `String.split` 55 ms,
`Map.get` 52 ms, `String.code` 43 ms (830,135). Collections cost 437 ms of
4.06 s.

Start-up is a large part of a small `check`: `agentica --version` takes 6 ms,
and `agentica help` takes 28 ms. The difference is the loader, which reads and
checks the 3.6 MB `stage2` (1,336 functions, 87,333 spans) in 15 to 16 ms
(`AGENTICA_VM_TRACE=loader` prints `loader done us=15140`; five runs), and
about 5 ms for the run of the front end itself (`check examples/hello.agc` is
27,946 steps). Against the target of 100 ms for gherkin (§35.2), 130 ms then,
the lexer is 58% of the steps of that check and the loader is 12% of its
time, so the lexer comes first, then the loader.

### Speed pass, second part: the lexer

Before is master (2b5f3f3e, with the profiler of the first part), after is this
PR, which changes `compiler/lexer.agc` only (the files checked are the ones of
the merged tree, so both binaries lex and check the same text). Both binaries
ran alternately (A B A B, 5 rounds of 7 to 9 runs for `hello` and gherkin,
5 rounds of 3 for `parser.agc`, 3 rounds of 3 for `front_end.agc`, the median
of the round medians) on an AMD Ryzen 5 3550H (4 cores, 8 threads), Debian 13,
gcc 14.2.
**Measured under load**: the load average was 2.1 to 2.5, because another job
was building on the machine. The steps do not depend on the load. An earlier
run of gherkin at load 1.0 gave 127.0 and 98.5 ms. The resident size went down
(`front_end.agc` 100.5 to 92.0 MB, gherkin 21.4 to 21.1 MB, `hello` 15.0 to
14.8 MB).

| command | steps before | steps after | `lexer.agc` steps before | after | s before | s after |
|---|---:|---:|---:|---:|---:|---:|
| `check examples/hello.agc` | 27,946 | 26,172 | 11,127 | 9,511 | 0.0272 | 0.0279 |
| `check stdlib/bdd/gherkin.agc` | 2,833,726 | 1,923,661 | 1,647,836 | 867,097 | 0.1264 | 0.0993 |
| `check compiler/parser.agc` | 11,153,906 | 7,420,483 | 6,682,444 | 3,431,804 | 0.401 | 0.304 |
| `check compiler/front_end.agc` | 77,669,291 | 54,796,784 | 39,430,947 | 19,570,418 | 3.137 | 2.413 |

The lexer no longer calls `Source.position` (`source.agc`, 3.2 M steps in
`front_end.agc`), so the lexer part of `front_end.agc` is 42.7 M steps before
and 19.6 M after, 54% fewer, and the whole check has 29% fewer. The lexer is
36% of the steps of `front_end.agc` now, against 51%. The gherkin check takes
99 ms, which meets the target of 100 ms (§35.2) on this machine, under load;
`hello` is the start-up cost (the loader, 15 to 16 ms, and 4 ms of
`agentica --version`), which this PR does not touch, and it moved by less than
1% (the tables are built when the program starts).

The lexer alone, on the 112 files of `compiler/` and `stdlib/` (989,891
characters), a program that calls `Lexer.lex` on each text:

| | steps | best of 3, ms | steps per character |
|---|---:|---:|---:|
| before | 51,620,728 | 1,482 | 52 |
| after | 24,106,051 | 752 | 24 |

Where the steps went, `check compiler/front_end.agc` (functions with most
steps, in millions): before `lex` 9.3, `skip_in` 5.0, `scan_name` 3.3,
`Source.position` 3.2, `skip_until` 3.2, the closure that makes the codes 2.5,
`skip_blanks` 2.1, `scan_operator` 1.8, `operator_lexeme` 1.6, `name_suffix`
1.4, `blank?` 1.1, `word_kind` 0.9, `track_block` 0.8, `scan_closing` 0.6;
after `lex` 14.2, `type_name_token` 1.6, `skip_until` 0.8 (now only the
strings), `operator_token` 0.7 (the brackets), `scan_string` 0.6. Builtins:
`String.code` (837,231 calls) is gone, `Set.new` goes from 3,290 calls to the
constants, `Set.include?`
went from 773,952 calls to 529,813, `Map.put` from 24,899 to 13,413 (the class
table was built again by every `lex` call), `String.slice` from 235,815 to
101,577.

The cost was not in one place: the lexer made a token every 5 characters or
so, and each token cost 150 to 200 steps. The VM costs behind that (measured
with `AGENTICA_VM_TRACE=profile` on 100,000 repeats of one form): a call
costs several steps, `Source.Position(...)` 9 steps (7 when the column is a
sum, not `offset - line_start + 1`), a whole `Token` with its two positions,
span and value about 36, `xs.push(x)` 4, `Map.get` 5, and a scan loop
`while set.include?(chars[i])` 9 steps for each character, which is the
floor: `chars[i] == "a"` costs 9 too, a table indexed by code with a guard
against codes above 127 costs 15, and unrolling the loop by two gives 8.5.
That is why the gain came from fewer tokens' worth of calls, not from a faster
scan.

Changes, in the order they were made, with the steps of the lexer alone after
each:

1. **Tables are module constants** (`CLASSES`, `NAME_CHARS`, `WORD_ACTIONS`,
   `SINGLE_OPS`, `PAIR_OPS`, ...). `new_input` built eight tables on every
   `lex` call (128 `Map.put` and `classify` calls among them), and `Input`
   carried them to every `scan_*` function. This is the lexer part of §44.9
   (44b). The main loop does the work of names, operators, brackets and line
   breaks in place, with no call per token: one lookup in `WORD_ACTIONS` tells
   a keyword, a block opener and `end` in one step, an operator is one `Op`
   with its kind and token value ready, and the text ends with sentinels, so no
   scan or look-ahead tests `index < size`. 51.6 M to 33.0 M steps.
2. The blank after a token is skipped in the same iteration, and the operator
   characters are one class: 33.0 M to 32.9 M (small, 0.4%).
3. **Characters, not codes.** `text.split("")` is used as it is: the closure
   that made `String.code` of each character (3 steps and a builtin call per
   character) is gone, and `Set[String]` tests cost the same as `Set[Int]`
   (177 and 184 ms for 1,000,000 tests). A comment or a doc line ends at the
   length of its line (`text.split("\n")`, when the text has no CR), not by a
   scan of its characters, and a line break is handled in place. 32.9 M to
   26.1 M.
4. Trims of the name path (one `if` for the words that are not keywords, the
   character after the name read once): 26.1 M to 25.7 M. The column of a
   position is `index + column_base` (`column_base = 1 - line_start`, changed
   where `line_start` is): 25.7 M to 25.1 M.
5. The stack of open brackets and blocks keeps its last frame and its size in
   two locals, so a bracket or a line break reads no list: 25.1 M to 24.3 M.
   The name loop of `type_name_token` is in place, and the character after a
   name or operator is read once: 24.3 M to 24.1 M.

The output is the same: `make fixed-point` (stage2 equals stage3), `make
goldens` rewrites nothing, and the tokens of 1,131 files (the repository's
`.agc` files and the lexer fixtures), of the 1,725 inputs of the frozen corpus
(the slow tier compares them to a manifest) and of 15,000 generated texts, with
CRLF, bare CR, non-ASCII characters, bad escapes, bad numbers and unclosed
brackets, match the lexer of master byte for byte, diagnostics included. The
nested-file budget of `tests/test_frontend_lexer.py` is 3,000 steps for each
line; a file of 3,000 `if x` lines and 3,000 `end` lines takes 1.4 M steps (240
for each line).

Tried and dropped:

- Inlining `Source.position` alone cut 2.1% of the steps (PR #315 note). Only
  the structure above moved the number.
- A `List[Bool]` table indexed by the code, with a guard for codes above 127,
  for the name scan: 15 steps for each character against 9 for the `Set`.
- Unrolling the name scan by two characters: 8.5 steps for each character
  against 9, for more code.
- `&String.code` as the function of the map that makes the codes: a builtin is
  not a `&name` (`CHECK-UNKNOWN-NAME`).

Counted, not built:

- Lexing by pieces: mark every punctuation character with a marker character
  that the text does not hold, `split` on the marker, and take one piece for
  each punctuation character with the name that follows it. By count it
  reaches about 22 M steps, and it needs the marker, a slow path for texts that
  have every candidate marker, and a rewrite of strings, docs and numbers.
- Lexing line by line, with the characters of a line made only when the line is
  not a comment: by count the cost of a line (about 60 steps) is more than the
  comments save.
