## 28. VM metrics

Issue #992 (one issue per phase). A tool inside the VM (`agentica run`) for
operators, like VM tracing (`docs/vm/08-loader-and-cli.md` §9) is for VM
developers: the VM exports numbers about itself (the GC, tasks, the scheduler,
I/O, processes, TCP) in the Prometheus text format, so Prometheus can scrape
them and Grafana can graph them. It is not a language feature: no grammar
change, no builtin, nothing in the programming skill. It is VM-only. Only the
env names are reserved today (`metrics_env` in `vm/process.c`, matched by the
whole name, so a child VM or a BDD runner never fights for the port or file;
`System.env` still shows them).

- **18a, metrics from state the VM already keeps, written to a file** (28.3,
  28.5): `AGENTICA_VM_METRICS_FILE` for node_exporter's textfile collector.
- **18b, the scrape endpoint** (28.5): `AGENTICA_VM_METRICS=[IP:]PORT` serves
  `GET /metrics` from its own thread.
- **18c, enabled-only hooks** (28.3): the counters and the one histogram that
  need a hook at an event, turned on at the first scrape, with the overhead
  check.
- **18d, memory diagnosis** (28.8), decided by the owner on 2026-10-13.

Two constraints: Boehm has no per-collection callback with user data (it would
need a mutable global, which `vm/` forbids), and the metrics thread must start
with the stop signals blocked (`docs/vm/10-io-scheduler.md` §10.2.2).

### 28.2 Rules

The same rules as tracing, plus one about cost:

1. **It never changes what the program sees.** Exit code, stdout, stderr (except
   the one-line start-up warnings, only when the setting is wrong), step counts,
   `--max-steps` outcomes and task order stay the same with metrics on. Metrics
   code allocates no GC memory, charges no steps and no turn cost, and never
   makes a task switch happen earlier or later.
2. **It never crashes the VM or changes the exit code.** Every failure (a port
   in use, a full disk, a client that sends garbage or never reads) is ignored
   or reported with one `agc-metrics` line, and the run goes on. Metrics code
   never calls Boehm from another thread and never touches GC memory outside
   the scheduler thread.
3. **It never keeps the VM alive.** When `main` ends, the run ends, scraped or
   not. There is no "wait for a last scrape" option: it would let monitoring
   change when a program ends.
4. **No cost while nobody asks.** Prefer a metric **derived at scrape** time
   from state the VM already keeps: no counter, no branch, no hook. A metric
   that needs an **enabled-only hook** uses one that exists only while metrics
   are on and someone has asked, sits at an existing trace point and shares its
   one test, and is a plain increment of a scheduler field (no atomic, no lock,
   no allocation). A metric that would need work on the hot path even when
   nobody scrapes is dropped; per-instruction counts are never metrics. With
   `make METRICS=0` the code is not compiled at all.
5. **Lazy start of hooks.** The hooks start at the first request for a
   snapshot, not at start-up (with the file, at start-up, since its consumer
   always asks). Hook counters start at 0 at the first scrape, which
   Prometheus's `rate()` and `increase()` treat like a process restart.
6. **Strict, one way.** A long-running process is scraped at its endpoint; a run
   that ends leaves its last numbers in a file. No options for the format, the
   path, the label set or the file interval.
7. **Linux first.** Elsewhere the VM ignores both variables and writes one line
   `agc-metrics not supported on this system`.

### 28.3 What is measured

Names follow the Prometheus rules: `agentica_vm_` prefix, base units, `_total`
for counters. Label values come only from fixed lists in the C code, so there
are about 30 names and at most about 80 series. "Derived" means read at scrape;
"hook" means an enabled-only hook (18c).

- **Build and process:** `agentica_vm_build_info` (gauge, always 1; labels
  `version`, `libgc`, `libuv`, `yyjson`, `trace`), `process_start_time_seconds`,
  `process_cpu_seconds_total` (from `/proc/self/stat`: near 1 per second means
  the scheduler is busy), `process_resident_memory_bytes`, `process_open_fds`
  and `process_max_fds`. The `process_*` names are the standard ones, so
  ready-made Grafana panels work.
- **GC** (not under `AGC_NO_GC`): `agentica_vm_gc_collections_total`,
  `_gc_heap_bytes`, `_gc_free_bytes`, `_gc_allocated_since_collection_bytes`,
  `_gc_allocated_bytes_total` (all derived from `GC_get_*`) and
  `_gc_pause_seconds_total` (hook: `GC_start_performance_measurement` at the
  lazy start). A pause histogram is not planned: Boehm has no callback with user
  data, so it would be one documented exception to the no-globals rule.
- **Tasks and scheduler:** `agentica_vm_tasks_spawned_total` and
  `_tasks_finished_total` (existing counters; spawned minus finished is the live
  count, main included), `agentica_vm_tasks{state="ready|parked"}` (derived),
  `_steps_total` (existing counter), `_turns_total{end="yield|park|done"}` and
  `_turn_cost_units_total` (hooks at the `sched turn` trace point), and
  `agentica_vm_run_queue_delay_seconds` (histogram, hook at the dequeue point:
  how long a ready task waits for its turn, the production form of the 250 ms
  latency rule of `docs/vm/10-io-scheduler.md` §10.2.1).
- **I/O, processes, TCP:** `agentica_vm_resources_open{kind}` (derived from the
  resource registry; a line that only grows is a leak),
  `_io_jobs_finished_total{kind,result}` and `_io_bytes_total{kind,direction}`
  (hooks in `trace_finish`), `_processes_spawned_total`,
  `_process_spawn_failures_total`,
  `_processes_exited_total{exit="zero|nonzero|signal"}`,
  `_tcp_connections_total{side}` and `_tcp_errors_total{op}`. Bytes written to
  stdout and stderr are not counted (no trace point; a test there would put a
  branch on the output path). Later TLS, HTTP and UDP metrics arrive with their
  PR (HTTP: requests by method class and status class, never by path).
- **End of run** (only in the last file write): `agentica_vm_exit_code` (the
  main alert of a batch job), `agentica_vm_end_time_seconds` and
  `agentica_vm_runtime_errors_total{code}` (one series when the run failed).

Not measured: anything per function, per instruction, per task id, per path, per
host or per program value; message text; the step limit.

### 28.4 How a snapshot is taken

Each **scheduler thread** owns the VM state and its hook counters; the
**metrics thread** owns the sockets, the file and the text format, and runs no
Agentica code, never allocates GC memory and never calls Boehm. Neither reads
the other's plain data: the metrics thread asks, and each scheduler answers
between turns, only while someone asks, so the stall check and the end of the
run are as without metrics. A late snapshot is never served as current (a
`503`; file mode skips that write). The end of the run waits for the last file
only for a bounded time: the exit code and output are right, but the last file
may be missing or old. A run killed by a signal or by the out-of-memory handler
writes no last file; the periodic writes cover it.

### 28.5 How it is exported

| Way | Decision |
| --- | --- |
| (a) Pull endpoint: the VM serves `GET /metrics` | Planned (18b): the normal Prometheus way for servers and workers |
| (b) Textfile for node_exporter's textfile collector | Planned (18a), first, since it needs no socket: batch jobs that end before any scrape |
| (c) Push to a Pushgateway | Not planned: needs an HTTP client in C; (b) covers batch jobs |
| (d) OpenTelemetry (OTLP) | Not planned: a large dependency for the same numbers; the OTel Collector can scrape (a) |

(a) and (b) may both be set; they share the snapshot and the text format. The
format is the Prometheus text exposition format 0.0.4 (`# HELP`, `# TYPE`,
samples; `Content-Type: text/plain; version=0.0.4; charset=utf-8`), not
OpenMetrics, no protobuf, no gzip.

**(a) `AGENTICA_VM_METRICS=[IP:]PORT`.** `9464` means `127.0.0.1:9464`; an IPv4
literal or `[IPv6]:PORT` binds that address (`0.0.0.0:9464` is how a container
exposes it); no host names; port 0 picks a free port, for tests; there is no
default port. `vm/launch.c` binds before the run, so a bind error is seen at
once: one line `agc-metrics cannot listen VALUE` and the run goes on without the
endpoint. The chosen address is written as a trace line (`metrics listen
host=... port=...`), which is how tests find a port-0 endpoint. The responder is
not the HTTP stack and shares no code with it: it reads at most 8 KiB up to the
first `\r\n\r\n`, accepts only `GET /metrics HTTP/1.1` or `HTTP/1.0`, and
answers 200, 404 (another target), 405 with `Allow: GET`, 400, 431 or 503, with
`Content-Length` and `Connection: close`. Each connection has one 5-second
deadline from accept to close, and at most 4 are open. The listener lives on the
metrics thread's own loop, so it never delays the stall check. A run that ends
before the first scrape is never seen at the endpoint; use the file.

**(b) `AGENTICA_VM_METRICS_FILE=path`.** The path must end in `.prom` and its
directory must exist. Before each `rename` the writer `lstat`s the path: if
something is there it must be a regular file owned by the VM's user, otherwise
the write is skipped. The write is atomic: the whole text goes to
`DIR/.NAME.PID.RANDOM.tmp` (`O_EXCL|O_NOFOLLOW`, mode 0644), then `rename`
replaces the path (a symlink there is replaced, not followed). The temp name
does not end in `.prom`, so the collector never reads it, and temp files of
killed runs older than 1 hour are removed at start-up. No `fsync`. It writes at
start-up (so a run that dies early leaves a file without `agentica_vm_exit_code`
instead of the previous run's `0`), every 15 seconds (fixed), and at the end
with the end-of-run metrics. A failed write is reported once on the `metrics`
trace category and retried at the next interval.

`Process.spawn` removes both variables from a child's environment; to get
metrics from a child VM, run it through `env` with another port or file.

### 28.6 Program-level metrics

Should a program define its own counters on the same endpoint (a `Metrics`
builtin or `std/metrics`)? **Decided: not now.** A counter is shared mutable
state, and the one way to share it is the `ATS` tables; a builtin with hidden
state would be a second special form next to the logger registry. Program data
in labels is how secrets and unbounded label sets leak; the VM's endpoint is
safe because every label value is a fixed C string. A program can serve its own
metrics with `HTTP.serve` on its own port. The candidate is a pure
`std/metrics` module that renders the text format from values the program holds,
with no link to the VM's endpoint.

### 28.7 Security

Localhost by default; no authentication and no TLS (put it behind a firewall, a
network policy or a reverse proxy; never expose it to the internet). No program
data in any label or value, so the file can be world-readable and the endpoint
leaks only how busy the VM is and how much memory it uses. At most about 80
series, fixed at compile time. Bounded work per client (8 KiB of head, 5
seconds, 4 connections, no request body): a flood costs the metrics thread,
never the program's thread.

### 28.8 Memory diagnosis (18d)

A program grows in memory and the gauges show it, but not which task did it. v1,
KISS:

- **Per-task counters:** bytes allocated by the task (a plain add at the central
  allocation path, `agc_alloc` and `agc_alloc_atomic`, into the running task's
  counter; total bytes allocated, not bytes alive, since Boehm does not say who
  holds an object) and bytes of C buffers held by the task's handles (exact,
  because a handle has one owner).
- **Global numbers:** what Boehm already gives next to the process RSS.
- **An on-demand dump of the top N tasks** by those numbers, each with its entry
  function, its parent and its age. How it is asked for is open: a path on the
  endpoint, a signal, or a variable that writes it at the end of the run.

Not in v1: a per-category heap walk, hooks into libuv's and OpenSSL's
allocators, heap snapshots, per-task Prometheus labels.

**Cost.** The per-task add is hot-path work that rule 4 drops: it must pass the
overhead gate (a CPU-heavy program of at least 10
seconds with metrics off, the endpoint idle, and the endpoint scraped every
second; expected overhead about 0, about 0 and below 2%), or change rule 4
first, with the reason. **Open:** how the allocation path finds the running
task's counter (`agc_alloc` takes no scheduler, and `vm/` has no mutable
globals): a new parameter on the allocation functions, a thread-local variable
(one documented exception), or counting in the callers that have the scheduler,
which misses allocations made deeper in helpers.

### 28.9 Tracing and metrics

Tracing and metrics share the rules and the observe word but answer different
questions: a trace is every event of one run, read after the fact; metrics are a
few totals and gauges of a running VM. Metrics never write per-event lines and
tracing never keeps totals.

### 28.10 Not planned

Push to a Pushgateway, OTLP, OpenMetrics or protobuf formats, gzip, TLS or
authentication on the endpoint, a configurable path, port or file interval;
keeping the VM alive for a last scrape; a GC pause histogram (to evaluate if the
server measurement shows single long pauses matter); per-function or
per-instruction metrics; labels from program data; metrics defined by programs;
metrics on platforms other than Linux until those platforms are tested again.
