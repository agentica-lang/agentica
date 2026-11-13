# Benchmarks and agent evaluation

Read before running or changing `benchmarks/`, `make bench`, the HTTP benchmark,
`tests/eval/`, or before measuring a speed change.

## Benchmarks

`make bench` (options: `BENCH_ARGS="--runs 3 --size 2"`; `python3
benchmarks/run.py --help` lists the rest) times `benchmarks/programs/*.agc` on
each runner (`exe` is `agentica FILE.agc`, `vm` is `agentica run` on bytecode)
against the CPython twins in `benchmarks/python/`, checks that every runner
prints the same output, and times start-up and the front end of `dist/agentica`
apart. It is outside `make test` and CI. `AGENTICA_JIT=off` in the environment
sets the JIT mode of every run (`on` by default); new numbers go in the PR
body. For where the time goes, `AGENTICA_VM_TRACE=profile`
(`references/vm-build.md`).

Guards for a change near their paths (compare against a VM built from master,
alternating the runs, and time loop-bound programs under more than one link
layout before blaming list code):

- `list-build` is the gate of the list representation, in both JIT modes:
  160,000 pushes (`--size 8`) take under 1 s, doubling n costs less than 2.5
  times the time, and no other benchmark slows by more than 2%.
- `small-values` guards the shared small values
  (`docs/vm/05-values-execution-builtins.md` §5.4); `list-bulk` guards bulk
  builds, which must stay within 1.3 times the flat array.
- `channel-pingpong` and `print-lines` guard the cost of the shared-state locks;
  run them again with `AGENTICA_VM_TEST_SHARED=1` to see the cost with the locks
  on. `deadline-pingpong` and `sleepers` time the timed parks (`--size 8`).

`make bench-native` (`benchmarks/native/run.py`) times one native call, a
short call of a native module against an extern `def`, a `compute def` and a
plain call, and 1000 structs from one module call against 1000 extern calls, in
ns per call with the loop included; it builds
`tests/fixtures/native/module_demo.c` with the system compiler.

A new program needs `def scale() -> Int` returning 1 (the script rewrites it for
`--size`), a deterministic checksum line, and a Python twin that takes the size
as `argv[1]`. The HTTP sanity check is apart:
`python3 benchmarks/http_bench.py`; record numbers only from an idle machine
(`docs/vm-benchmarks.md`, "HTTP sanity check").
`python3 benchmarks/websocket_broadcast.py` compares the GC time of a WebSocket
broadcast sent as `Text` and as `HTTP.prepare`.

## Speed work

- Profile before timing. `AGENTICA_VM_TRACE=profile` prints the report when a
  run ends; its rows, options and the costs in steps are in
  `agentica-programming` `references/performance.md`. The `events`, `op` and
  `pair` rows at its end (`docs/vm/08-loader-and-cli.md` §9) say what to fuse
  or open-code.
- Profile CPU time with `perf` when the steps do not explain the wall time:
  `System.Profile` and the step report do not count time inside builtins. Use a
  local `make` build of `dist/agentica`, since release archives are stripped.
  Common entries:
  - `GC_malloc_kind` and other libgc symbols: allocation.
  - `__tls_get_addr`: libgc linked as a shared library (thread-local lookups).
  - `__snprintf_chk`: number to text.
  - `caught`, `__sigsetjmp`: a `setjmp` per builtin call.
- Steps are exact and repeat from run to run, so they are the main evidence.
  Wall time is supporting: a profiled run is slower (up to 15 times on cheap
  builtin calls, each of which it times), so time
  without the profile, run the old and the new binary alternately (A B A B, a
  few rounds of several runs), take the median of the round medians, record the
  load average (`uptime`) and say "measured under load" above 2.
- Start-up: a hello check is bound by memory it touches. Build
  like the release (`AGENTICA_GC=vendored AGENTICA_OPENSSL=vendored`), because
  the default links the system libgc and OpenSSL as shared libraries, and the
  start-up numbers differ. `AGENTICA_VM_TRACE=loader` prints `loader done us=`;
  `/usr/bin/time -v` prints the minor faults; a throw-away `clock_gettime`
  between the sections of `load` shows where a phase goes. Time with the
  front end's own steps unchanged (`profile` prints the same `steps=`).
- Find the structural cost before editing call sites: in the lexer, moving the
  per-token work (tables built once, one lookup for a keyword, a block opener
  or `end`, no closure per character) beat inlining one call
  (`docs/vm-benchmarks.md`, "Tried and dropped", "The lexer").
- A change that must keep the output: `make fixed-point`, `make goldens` (it
  must leave `git status` clean), and for a front-end stage the differential
  run against master in `references/frontend.md`.

## Agent evaluation

Not part of `make test`; the arms, the task layout and the sandboxes are in
`docs/eval.md`. After any change to a task, `tests/eval/run.py`, the Dockerfile
or the VM, run `make eval-references` (`run.py --check-references --jobs 8`: it
grades every `reference.*` in the Docker sandbox without a model and exits 1 on
a failure; not in CI).
