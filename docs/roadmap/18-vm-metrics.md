## Phase 18: VM metrics

Specified in [`docs/future/28-vm-metrics.md` section
28](../future/28-vm-metrics.md#28-vm-metrics). Three small PRs, and a fourth
(18d) after 17b, on the VM only, in order step 7.7: a new VM-only feature after
7i, before the server measurement (7j), which reads its GC and run-queue
numbers. No grammar change and no builtin: it is a tool of `agentica-vm`, like
VM tracing (14a). The endpoint does not use the HTTP stack, so it does not wait
for anything but 7i. Every metric is derived at scrape time from state the VM
already keeps, or comes from an enabled-only hook at an existing trace point
that starts at the first scrape; with metrics off the cost is zero, and
`make vm METRICS=0` compiles them out (§28.2).

- [ ] 18a Metrics from the VM's own state, written to a file
  (`docs/future/28-vm-metrics.md` §28.3 to §28.5): `vm/metrics.h` and
  `vm/metrics.c`; the observe word shared with the trace points; the metrics
  thread and the snapshot the scheduler fills on request at the dequeue point,
  the two `agc_io_poll` call sites of the run loop, after its bookkeeping
  (unref'd async handle, no steps, no turn cost; the dequeue point takes over
  `trace_gc`'s turn-end test); the Prometheus text format 0.0.4; the derived and
  existing-counter metrics (build info, `process_*` from `/proc`, GC, tasks,
  steps, open resources, end of run); `AGENTICA_VM_METRICS_FILE` (a `.prom`
  path; atomic rewrite every 15 seconds and at the end through a temp file with
  a random name, retried on `EEXIST`, and `fchmod` 0644; a new `lstat` check
  before each `rename`: a regular file owned by the VM's user); the metrics
  thread's file and `/proc` I/O in plain POSIX calls, never the libuv pool; the
  end of run (`stop` set under a small mutex that guards every `uv_async_send`
  to a scheduler, the async closed, the VM's normal end sequence unchanged, then
  the thread writes the last file once the exit code is known, and a 1-second
  join that falls back to the existing `_exit(code)` path); start-up removal of
  the path's own temp files older than 1 hour (regular, owned by the VM's user);
  a start-up write as soon as the path checks pass, so a run that dies early
  leaves no `agentica_vm_exit_code`; `child_env(bool drop_uring)` runs when
  `drop_uring_env` is set or either variable is present: it removes
  `UV_USE_IO_URING=` only when the VM set it, and both metrics variables
  (matched with their `=`) whenever present, invalid values too;
  `src/bdd-driver.rkt` (phase 21) removes the metrics variables from the runner
  VM it starts, so the scenario VMs and programs under test inherit the cleaned
  environment (`docs/bdd.md`, "How a run works"), with a test; the `metrics`
  trace category in `vm/trace.c` (its `write` lines) and `metrics` in the
  category regex of `tests/vm-trace-test.rkt`; the lazy start's call sites (the
  first request, and main before `agc_vm_run` in file mode), which do nothing
  until 18c; request numbers (`snapshot_seq` and `answered_seq`, one part buffer
  per scheduler freed only after the join) so an answer to a timed-out request
  is ignored; the final handoff and the 1-second join between computing `code`
  and `if (!settled)`; `lock` jobs skipped in `resources_open{kind="job"}`;
  `tasks_finished_total` as `tasks_done`, plus main in the end-of-run snapshot;
  `Process.spawn` removes the variables from a child's environment;
  `make vm METRICS=0` (built in the `vm-sanitizers` job) and `metrics off` in
  `--version`; the Makefile and the test runners remove the variables. Tests: C
  tests of the renderer and the path checks, an independent Python parser of the
  format, known numbers from fixtures, golden fixtures unchanged with metrics
  on, a reader that always finds a whole file, other temp-like files that do not
  stop the write, the removal of old temp files, the `EEXIST` retry and another
  user's file in `vm/tests/metrics_test.c` with an injected random source and
  owner uid, mode 0644 under `umask 077`, a `SIGKILL`ed run that leaves the
  start-up file with no exit code, the child environment cases (a user's
  `UV_USE_IO_URING` is kept). Every test file that removes `AGENTICA_VM_TRACE`
  removes the metrics variables too. Python is required for these tests in CI
  and is the only outside tool. Timing-sensitive cases go in
  `tests/vm-metrics-timing-test.rkt`, listed in `test-omit-paths` in
  `tests/info.rkt`, run by `make vm-metrics-timing` and by a CI step after
  `make vm-latency`, with bounds that leave room for a loaded runner. Docs:
  `docs/vm/` and the development skill.
- [ ] 18b The endpoint (§28.5): `AGENTICA_VM_METRICS=[IP:]PORT` (a bare port
  binds `127.0.0.1`; port 0 for tests, reported by the `metrics listen` trace
  line), `GET /metrics` only, with 404, 405, 400, 431 and 503 (the snapshot wait
  has its own 4-second budget inside the connection's deadline); the test-only
  `AGENTICA_VM_TEST_METRICS_TIMES=budget_ms,deadline_ms` shrinks both limits;
  the `listen` and scrape lines of the `metrics` trace category;
  `Connection: close`, 8 KiB, a total deadline of 5 seconds from accept to
  close, and 4 connections; the listener lives on the metrics thread's own loop,
  so it never keeps the VM alive. Tests: replies from a Python client (the port
  read from `AGENTICA_VM_TRACE_FILE`, so stderr stays golden), 503 during a few
  long turns with a 1 ms budget and 200 after them, deadline tests with a 300 ms
  deadline that take well under a second, the VM ends while a client is
  connected, golden fixtures unchanged while scraped every 100 ms, and the first
  overhead numbers in `docs/vm-benchmarks.md` (§28.8).
- [ ] 18c Enabled-only hooks (§28.3, §28.4): turns by end, turn-cost units, the
  run-queue delay histogram, I/O jobs by kind and result, I/O bytes (all kinds,
  TCP included, in `trace_finish`: each kind keeps its count in its `data` next
  to the system call, `done` reports it through a new `agc_io_bytes *out`
  parameter in `vm/port.h`, and `agc_io_finish` copies it onto the job;
  `vm/files.c`, `vm/input.c`, `vm/process.c`, `vm/tcp.c`), processes, TCP
  connections and errors, and the GC pause total
  (`GC_start_performance_measurement`); each at an existing trace point and
  sharing its test (the I/O hooks in `trace_finish` before its early returns,
  `lock` jobs skipped), and the run-queue delay at the dequeue point, with one
  clock read per dequeue (tasks queued after a turn's code, behind the tail
  remembered right after `agc_turn_finish`, are stamped with that read); the
  lazy start's work at the call sites 18a added: it reads the clock, sets the
  last dequeue time, stamps every queued task (one walk, once; no walk in file
  mode, where the queue is empty), sets the metric bits and calls
  `GC_start_performance_measurement`, and hook state lives in the scheduler's
  `malloc`'d `agc_observe` block, which libuv callbacks reach through a pointer
  in their native state (the remembered queue tail, a GC pointer, stays in
  `agc_vm`); the run-queue hook is revisited with the multicore schedulers;
  started at the first snapshot request (at start-up in file mode). Tests: known
  counts from fixtures; the first scrape after 3 seconds of ready tasks has no
  observation above 1 second; in file mode, tasks spawned in main's first turn
  give no observation above 1 second; the overhead check
  (`benchmarks/run.py --metrics-overhead` on `calls` and `knight-tour`: off, on
  with no scraper, on with a scraper every second; about 0, about 0, below 2%),
  recorded in `docs/vm-benchmarks.md`.


- [ ] 18d Memory diagnosis (§28.12), decided by the owner on 2026-10-13, KISS,
  after 17b (order row 7.2.1e); the exact handle bytes need the one-owner rule
  of 24b (row 7.2.1a). Per-task counters: bytes allocated by each task, counted
  at the central allocation path into the running task's counter with a plain
  add and no atomic, and the bytes of C buffers held by the task's handles,
  exact through the one-owner rule. The global numbers Boehm already gives
  (heap, free, total allocated) next to RSS. An on-demand dump of the top N
  tasks (entry function, parent, age); how it is asked for is open (§28.12). The
  per-task add breaks rule 4 of §28.2 (no work on a hot path while nobody asks),
  so the PR must pass the overhead check of §28.8 or change the rule first. Not
  in v1: a per-category heap walk, hooks into libuv's and OpenSSL's allocators,
  heap snapshots, per-task Prometheus labels.

To evaluate later, not in this phase: a GC pause histogram (needs a documented
exception to the no-globals rule) and metrics defined by programs (after shared
tables, phase 9, and HTTP on the VM; a `std/metrics` renderer, never a builtin,
§28.6).

**Done when:** a Prometheus server scrapes a running Agentica server on the VM
and Grafana graphs its GC, tasks, run-queue delay and I/O; a cron script leaves
its exit code and totals in a `.prom` file; and the golden fixtures give the
same output with metrics on.
