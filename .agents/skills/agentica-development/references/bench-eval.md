# Benchmarks and agent evaluation

Read before running or changing `benchmarks/`, `make bench`, the HTTP benchmark,
`tests/eval/`, or before measuring a speed change.

## Benchmarks

Speed check (7g): `make bench` (or `python3 benchmarks/run.py --runs N --size S
--only NAMES --runners exe,vm,python` (`exe` is `agentica FILE.agc`, `vm` is
`agentica run` on bytecode)) times `benchmarks/programs/*.agc` on each runner
against the CPython versions in `benchmarks/python/`, checks that every runner
prints the same output, reports `LOWER-UNSUPPORTED` programs as unsupported, and
times `hello.agc` start-up apart, then the front end of `dist/agentica` (`check`
of hello, gherkin, parser and `compiler/front_end.agc`, and one small `agentica
test`; the heading prints the load average and says "measured under load" above
2; `--no-startup` skips both). For where the time goes,
`AGENTICA_VM_TRACE=profile` (`references/vm-build.md`). It is outside `make
test` and CI; `BENCH_ARGS="--runs 3 --size 2"` passes options through `make
bench`; record new numbers in `docs/vm-benchmarks.md`. `list-build` (n pushes, n
scattered `set`s and a `for` sum) is the gate of the list representation (8d):
160,000 pushes (`--size 8`) take under 1 s, doubling n costs less than 2.5 times
the time, and no other benchmark slows by more than 2%; `small-values` (the
shared small values of §34: one-character and empty Strings, empty Lists, Maps
and Sets) gained 23% over seven link layouts, so a change near those paths keeps
it as the guard; `list-bulk` (`repeat`, `to_a`, `reverse`, `take`, `drop`,
`concat`, `join`, `String.split` and `sort` of 60,000 to 500,000 items) guards
bulk builds, which must stay within 1.3 times the flat array; compare against a
VM built from master, alternating the runs, and time loop-bound programs under
more than one link layout before blaming list code. `channel-pingpong` (two
tasks on two channels) and `print-lines` guard the cost of the shared-state
locks. From PR 3c of issue #345 on (real scheduler threads; before it, no
speed comparison is asked for a multicore change), compare a change to the
locks or the scheduler against a VM built from master, and run them again with
`AGENTICA_VM_TEST_SHARED=1` to see the cost of the locks when they are on.
`deadline-pingpong` (a channel ping-pong where every send and receive has a
deadline) and `sleepers` (100 tasks that sleep 1 ms ten times, then 3,000
awaits with a long deadline that the finished task cancels) time the timed
parks; run them at `--size 8` to compare a change near the timers, under the
same rule. A new program needs `def
scale() -> Int` returning 1 (the script rewrites it for `--size`), a
deterministic checksum line, and a Python twin that takes the size as `argv[1]`.
The HTTP sanity check (20c) is apart: `python3 benchmarks/http_bench.py` (Python
3.10 or newer) compares `examples/http_server.agc serve` on `dist/agentica run`
with Node `http`, a Python asyncio server and Python's `ThreadingHTTPServer`
(servers in `benchmarks/http.js` and `--serve`), all loaded by the same Node
keep-alive client (`benchmarks/http.js client`, 4 processes), interleaved per
round, pinned with `taskset`, and each round starts only after a 5 s
`/proc/stat` sample shows `--min-idle` of all CPUs idle (repeated otherwise) and
is marked disturbed when outside CPU use during it is above `--max-outside`;
record numbers only from an idle machine, in the last section of
`docs/vm-benchmarks.md`.

## Speed work

- Profile before timing. `AGENTICA_VM_TRACE=profile` prints the report when a
  run ends (stderr, or `AGENTICA_VM_TRACE_FILE`): the `total` line (`wall_ms`,
  `steps`, `calls`, `builtin_ms`, `gc_ms`, `collections`), then the 30
  functions with most steps (`fn`, with `at=FILE:LINE`), the 12 files with most
  steps, the 30 builtins with most time (`us=`) and the `section` rows of
  `Profile.measure`; `AGENTICA_PROFILE_FORMAT=folded` writes flame graph
  stacks instead (`references/vm-build.md`). `agentica FILE.agc` prints
  two reports, the front end's and the program's; in the second, `gc_ms` and
  `collections` are still those of the whole process. `check` of a file with no
  `main` prints its report too.
- Steps are exact and repeat from run to run, so they are the main evidence.
  Wall time is supporting: a profiled run is about a third slower, so time
  without the profile, run the old and the new binary alternately (A B A B, a
  few rounds of several runs), take the median of the round medians, record the
  load average (`uptime`) and say "measured under load" above 2.
- On the development machine `perf` is blocked (`perf_event_paranoid` is 3,
  no root), and valgrind and gdb are not installed: the profiler is the tool.
- Start-up (row 8.3): a hello check is bound by memory it touches. Build
  like the release (`AGENTICA_GC=vendored AGENTICA_OPENSSL=vendored`), because
  the default links the system libgc and OpenSSL as shared libraries, and the
  start-up numbers differ. `AGENTICA_VM_TRACE=loader` prints `loader done us=`;
  `/usr/bin/time -v` prints the minor faults (about 1,860 for a hello check, at
  3.5 to 5 µs each on the development machine); a throw-away `clock_gettime`
  between the sections of `load` shows where a phase goes. Time with the
  front end's own steps unchanged (`profile` prints the same `steps=`).
- Find the structural cost before editing call sites. In the lexer, inlining
  `Source.position` at its call sites alone cut 2.1% of the steps; moving the
  per-token work (tables built once, one lookup for a keyword, a block opener
  or `end`, no closure per character) halved them (`docs/vm-benchmarks.md`,
  "Speed pass, second part").
- A change that must keep the output: `make fixed-point`, `make goldens` (it
  must leave `git status` clean), and for a front-end stage the differential
  run against master in `references/frontend.md`.

## Agent evaluation

Agent evaluation (not part of `make test`): `python3 tests/eval/run.py --help`.
Docker is the default; its image is built automatically when missing (and
rebuilt when the typed arm finds no `mypy` in it, or when it cannot run
`dist/runtime`). Allow provider credentials with repeatable `--pass-env NAME`.
Optional Firejail requires `--sandbox firejail --chroot-root PATH`. `--jobs N`
runs in parallel. `--check-references` grades every `reference.*` of
`tests/eval/tasks/` in the Docker sandbox without a model and exits 1 on a
failure; run it after any change to a task, `tests/eval/run.py`, the Dockerfile
or the VM (`make eval-references` is the same with `--jobs 8`; it is not in CI).
The arms are `skill`, `grammar`, `binary` (Agentica), `python` (untyped) and
`typed-python` (`mypy --strict`, pinned in `tests/eval/Dockerfile`; a failing
checker is a failing run, and so is a `# type: ignore` or `# mypy:` comment). A
task is `task.md`, `reference.agc`, `reference.py` (typed, passes `mypy
--strict` and is the reference of both Python arms), optional `start.agc`,
`start.py` and `start.typed.py` (the typed arm's start when `start.py` is
untyped), and `hidden/NN.in` and `NN.out`; `hidden/driver.py` (Python standard
library only, run as `python3 -I -` in the grader container with its source on
stdin, `NN.in` as its first argument and the solution command after it, its
stdout compared with `NN.out`) is the independent peer of the integration and
big-data tasks, and `hidden/timeout` raises the 10 s case limit. Containers set
`TMPDIR=/tmp` (the launcher writes its bytecode there) and the image has
`libgc1` and `libssl3t64` for `dist/agentica`. The details are in
`docs/eval.md`.
