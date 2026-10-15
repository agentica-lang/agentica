## 28. VM metrics

**Status:** planned (roadmap phase 18). A tool inside `agentica-vm` for
operators, like VM tracing (§24.4) is for VM developers: the VM exports numbers
about itself (the GC, tasks, the scheduler, I/O, processes, TCP) in the
Prometheus text format, so Prometheus can scrape them and Grafana can graph
them. It is not a language feature: no grammar change, no builtin, nothing in
the programming skill. It is VM-only and comes after 7i. Three small PRs, and a
fourth after 17b:

- 18a, **metrics from state the VM already keeps, written to a file** (28.3,
  28.5): `vm/metrics.h` and `vm/metrics.c`, the snapshot taken by the scheduler
  (28.4), the text format, and `AGENTICA_VM_METRICS_FILE` for node_exporter's
  textfile collector.
- 18b, **the scrape endpoint** (28.5): `AGENTICA_VM_METRICS=[IP:]PORT` serves
  `GET /metrics` from its own thread.
- 18c, **enabled-only hooks** (28.3, 28.4): the counters and the one histogram
  that need a hook at an event, turned on at the first scrape, with the overhead
  check of 28.8.
- 18d, **memory diagnosis** (28.12): per-task allocation counters and an
  on-demand dump of the tasks that hold the most. Decided by the owner on
  2026-10-13, after 17b.

### 28.1 Today

Checked at `12df0f8`:

- The VM has no metrics. VM tracing (`AGENTICA_VM_TRACE`, 14a, as built in
  `docs/vm/08-loader-and-cli.md` §9) writes one line per event, and its `gc`
  category writes `collect at=turn|end count= heap= free= since=` from Boehm's
  getters (`agc_gc_stats` in `vm/value.c`). Tracing is for one run that a
  developer reads; it has no totals and nothing a dashboard can poll.
- The VM already keeps, for its own work, most of what an operator wants to see:
  Boehm's `GC_get_gc_no`, `GC_get_heap_size`, `GC_get_free_bytes`,
  `GC_get_bytes_since_gc` and `GC_get_total_bytes` (Boehm 8.2.12, in the
  `vm/third_party/bdwgc` submodule); `next_task_id` (an `_Atomic uint64_t` in
  `agc_runtime`, main is 1) and `tasks_done` (in `agc_vm`, which counts every
  finished task except main: when main's turn ends with `done`, the run loop in
  `vm/task.c` breaks out before `finish_task`, and `pending_tasks()` relies on
  that); `steps_left` (an `_Atomic int64_t`, counting down from `--max-steps` or
  `INT64_MAX`); the run queue; the resource registry (`vm/loop.c`), which holds
  every open file handle, process, job and, with TCP (PR #106, open), socket and
  listener.
- Trace points sit at every event an operator would count (spawn, turn end, job
  start and done, poll, process spawn and exit, and, with PR #106, `tcp_accept`,
  `tcp_connected`, `tcp_connect_error`, `tcp_accept_error`). Each costs one test
  of the trace mask when tracing is off (`AGC_TRACE_ON`, `vm/trace.h`).
  `make vm TRACE=0` compiles them out.
- I/O job kinds are named in their `agc_io_kind`: `file`, `lock`, `process`,
  `sleep`, `stdin` (and `tcp` with PR #106). `lock` jobs are the timers of tasks
  waiting for a handle's lock or on a channel, not I/O; `trace_finish`
  (`vm/loop.c`) skips them, and also returns early when the job has no start
  time (it is saved only while `io` tracing is on). A job's result is `ok`,
  `error` or `value` (a builtin that returns a plain value, not a `Result`).
- The run loop (`agc_vm_run` in `vm/task.c`): `dequeue`; if the queue is empty,
  `agc_io_poll(vm, true)` (or the stall check) and back to `dequeue`; else run a
  turn, `trace_turn`, `trace_gc`, then `finish_task` or `enqueue`, then
  `agc_io_poll(vm, false)`, and back to `dequeue`. `agc_io_poll` returns at once
  when the loop is not alive, so code inside it does not run on every turn.
- Boehm can time collections itself: `GC_start_performance_measurement()` and
  `GC_get_full_gc_total_time()` (milliseconds, all full collections; the VM
  never turns on incremental mode, so every collection is full). It has no
  per-collection callback with user data: `GC_set_on_collection_event` takes a
  plain function, so timing each collection would need a mutable global, which
  `vm/` forbids (`docs/vm/10-io-multicore.md` §10.2.3, enforced by
  `make vm-lint`).
- `vm/main.c` ignores `SIGPIPE`. The libuv thread-pool threads start with
  `SIGINT`, `SIGTERM` and `SIGHUP` blocked (`vm/loop.c`); Boehm's marker threads
  do not, so the stop handler may run on any thread and only sets lock-free
  atomics (§10.2.2, Stop signals). A metrics thread must start with them blocked
  too (`agc_io_block_stop`).

### 28.2 Rules

The same rules as tracing (§24.4), plus one about cost:

1. **It never changes what the program sees.** Exit code, stdout, stderr (except
   the one-line start-up warnings of 28.5, only when the setting is wrong), step
   counts, `--max-steps` outcomes and task order stay the same with metrics on.
   Metrics code allocates no GC memory, charges no steps and no turn cost, and
   never makes a task switch happen earlier or later.
2. **It never crashes the VM or changes the exit code.** Every failure (a port
   in use, a full disk, `malloc` failing, a client that sends garbage or never
   reads) is ignored or reported with one `agc-metrics` line, and the run goes
   on. Metrics code never calls `abort`, never calls Boehm from another thread,
   and never touches GC memory outside the scheduler thread.
3. **It never keeps the VM alive.** When `main` ends, the run ends, scraped or
   not (28.5).
4. **No cost while nobody asks.** This is the rule that picks how each metric is
   made:
   - Prefer a metric **derived at scrape** time from state the VM already keeps
     (the list in 28.1). It costs nothing between scrapes: no counter, no
     branch, no hook.
   - A metric that needs a hook at an event (an **enabled-only hook**) uses a
     hook that exists only while metrics are on and someone has asked (lazy
     start, below). It sits at an existing trace point and shares that point's
     one test, so turning metrics off adds no branch on any path that runs per
     turn or per event (28.4). The only new test is at the dequeue point after a
     blocking poll, a path that runs only when the scheduler has just been idle.
     The hook is a plain increment of a field of the scheduler that runs the
     event: no atomic, no lock, no allocation. It reads the clock only where a
     histogram needs it.
   - A metric that would need work on the hot path even when nobody scrapes is
     dropped. Per-instruction counts are never metrics.
   - With metrics off, the cost is zero: derived metrics need no code between
     scrapes, and hooks share the trace tests, so the turn path and the event
     paths have the same tests as today (the one new test runs only after an
     idle wait, 28.4). With `make vm METRICS=0`, the metrics code is not
     compiled at all.
5. **Lazy start of hooks.** Decided: the enabled-only hooks start at the first
   request for a snapshot, not at start-up. With the endpoint that is the first
   scrape; with the file (28.5) it is start-up, since the file is always written
   at the end, so its consumer always asks. Until then, "enabled, never scraped"
   costs the same as off, plus one flag load per turn (28.4). Hook counters
   start at 0 at the first scrape; Prometheus's `rate()` and `increase()` treat
   that like a process restart, so nothing is lost but the events before the
   first scrape. Gauges and derived counters are always whole, since they are
   read from the VM's own state.
6. **Strict, one way.** Each need has one way: a long-running process is scraped
   at its endpoint; a run that ends (a batch job, a cron script) leaves its last
   numbers in a file. There are no options for the format, the path of the
   endpoint, the label set or the file interval.
7. **Linux first.** On other systems the VM ignores both variables and writes
   one line `agc-metrics not supported on this system`; the code sits under
   `#ifdef __linux__`, like other untested platform code (AGENTS.md).

### 28.3 What is measured

Names follow the Prometheus rules: `agentica_vm_` prefix, base units (seconds,
bytes), `_total` for counters, `_info` for a constant with labels. Label values
come only from fixed lists in the C code. "How" says how each one is made:
**derived** (read at scrape from state the VM already keeps), **existing
counter** (a counter the VM already keeps for itself, read at scrape), or
**hook** (enabled-only hook at the named trace point, from the first scrape on,
18c). Every metric is in the endpoint and the file, except the end-of-run ones,
which only the last file write has.

**Build and process**

| Name | Type | Labels | How | Why |
|---|---|---|---|---|
| `agentica_vm_build_info` | gauge, always 1 | `version`, `libgc` (`none` on a sanitizer build), `libuv`, `yyjson`, `trace` (`on`/`off`) | derived (the `--version` data) | Join a dashboard to the VM version; see a change of version on a graph |
| `process_start_time_seconds` | gauge | none | derived (wall clock read once when metrics start) | Uptime is `time() - process_start_time_seconds`; Prometheus prefers a start time to an uptime gauge |
| `process_cpu_seconds_total` | counter | none | derived (`/proc/self/stat`, on the metrics thread) | CPU use; close to 1 per second means the scheduler is busy, near 0 means it waits. It replaces a "time blocked in the loop" counter, which would need clock reads around every poll |
| `process_resident_memory_bytes` | gauge | none | derived (`/proc/self/statm`) | RSS; Boehm's heap is not the same as what the OS gives |
| `process_open_fds`, `process_max_fds` | gauge | none | derived (`/proc/self/fd`, `getrlimit`) | Descriptor leaks and limits, for servers |

The `process_*` names are the standard ones from Prometheus client libraries, so
ready-made Grafana panels work. They are read by the metrics thread, which
touches no VM state for them.

**GC** (left out under `AGC_NO_GC`, the sanitizer build, which has no collector)

| Name | Type | How | Why |
|---|---|---|---|
| `agentica_vm_gc_collections_total` | counter | derived (`GC_get_gc_no`) | When collections happen: `increase()` per scrape interval shows them on a graph. The exact moment of each one is the `gc` trace category's job |
| `agentica_vm_gc_heap_bytes` | gauge | derived (`GC_get_heap_size`) | Heap growth, leaks |
| `agentica_vm_gc_free_bytes` | gauge | derived (`GC_get_free_bytes`) | How much of the heap is unused |
| `agentica_vm_gc_allocated_since_collection_bytes` | gauge | derived (`GC_get_bytes_since_gc`) | How close the next collection is |
| `agentica_vm_gc_allocated_bytes_total` | counter | derived (`GC_get_total_bytes`) | Allocation rate with `rate()`; a sawtooth gauge alone samples badly |
| `agentica_vm_gc_pause_seconds_total` | counter | hook: `GC_start_performance_measurement()` called at the lazy start; read with `GC_get_full_gc_total_time()` | Time the program was stopped by the GC; the mean pause is `rate(pause) / rate(collections)`. Millisecond steps, so a short run shows 0 |

A pause **histogram** is not planned: Boehm has no collection callback with user
data, so it would need a mutable global set under the GC lock, an exception to
the rule of §10.2.3. To evaluate later, if the server measurement (7j) shows
that single long pauses matter. Then it would be one documented `NOLINT`
exception, registered only at the lazy start.

**Tasks and the scheduler**

| Name | Type | Labels | How | Why |
|---|---|---|---|---|
| `agentica_vm_tasks_spawned_total` | counter | none | existing counter (`next_task_id - 1`, main included) | Spawn rate |
| `agentica_vm_tasks_finished_total` | counter | none | existing counter: `tasks_done` while the run goes on (main is never in it, 28.1), and `tasks_done + 1` in the end-of-run snapshot, once the run's outcome is known. "Finished" means the run is over for that task: main counts as finished at the end however the run ended (main returned, a child failed, or a task called `System.exit`) | Finish rate. While the run goes on, spawned minus finished is the live count, and it includes main while main runs, so it is at least 1 at every scrape. At the end, spawned minus finished is the number of tasks the run cut off: the ready and parked tasks cancelled when the run ended, plus the child whose failure or `System.exit` ended the run, since such a task never reaches `finish_task` and so is not in `tasks_done` either |
| `agentica_vm_tasks` | gauge | `state`: `ready`, `parked` | derived: `ready` walks the run queue at the snapshot; `parked` is live (spawned minus finished, main included) minus ready (the snapshot is taken between turns, so no task is running) | Backlog: many ready tasks mean CPU contention; many parked tasks mean waiting on I/O |
| `agentica_vm_steps_total` | counter | none | existing counter (`--max-steps` start value minus `steps_left`; exact to one step batch) | Interpreter work rate |
| `agentica_vm_turns_total` | counter | `end`: `yield`, `park`, `done` | hook at the `sched turn` trace point | How often tasks are preempted (`yield`) against how often they wait (`park`) |
| `agentica_vm_turn_cost_units_total` | counter | none | hook at the `sched turn` trace point (`turn_cost_used`) | How much long builtins (sorts, big joins, JSON) weigh on fairness |
| `agentica_vm_run_queue_delay_seconds` | histogram | buckets 0.0001, 0.001, 0.005, 0.01, 0.05, 0.1, 0.25, 1, `+Inf` | hook at one point only, the dequeue point (28.4): one clock read per `dequeue`. Tasks queued after a turn's code ended (await waiters woken by `finish_task`, the task put back after a `yield`, wakes from the poll after the turn or from a blocking poll) are stamped with that read; only tasks spawned or woken inside a turn keep the earlier stamp (the time the turn started), and their wait is real: they waited at least the rest of that turn | The latency a server's tasks see: how long a ready task waits for its turn. It is the production form of the 250 ms latency rule of `docs/vm/10-io-scheduler.md` §10.2.1 |

**I/O, processes, TCP**

| Name | Type | Labels | How | Why |
|---|---|---|---|---|
| `agentica_vm_resources_open` | gauge | `kind`: `file`, `process`, `job`, `tcp_socket`, `tcp_listener` | derived: one walk of the resource registry at the snapshot; `lock` jobs (timers of tasks waiting for a handle's lock or on a channel, not I/O) are skipped, as in `agentica_vm_io_jobs_finished_total` | Open handles by kind; a leak shows as a line that only grows |
| `agentica_vm_io_jobs_finished_total` | counter | `kind` (the `agc_io_kind` names except `lock`: `file`, `process`, `sleep`, `stdin`, `tcp`); `result`: `ok`, `error`, `timeout` (a plain `value` result counts as `ok`) | hook in `trace_finish` (`vm/loop.c`, the `io done` and `io timeout` trace points), placed after its one combined test and before its trace-only early returns (no start time, a `lock` job), so it counts jobs whether `io` tracing is on or not; `lock` jobs are skipped | I/O rate and error rate by kind. Jobs in flight are in `agentica_vm_resources_open{kind="job"}`, derived, so no start counter |
| `agentica_vm_io_bytes_total` | counter | `kind`: `file`, `stdin`, `process`, `tcp`; `direction`: `read`, `write` | hook in `trace_finish` next to the jobs counter (before its early returns), for every kind, TCP included (with PR #106, TCP reads and writes are `tcp_io` external jobs that finish through `agc_io_finish` → `trace_finish`). One mechanism: each kind keeps its byte count in its own `data` struct, written next to the system call (in `work`, or in the libuv callback for an external kind); `done` reports it through a new out-parameter, `agc_value (*done)(agc_vm *vm, void *data, agc_value context, agc_io_bytes *out)` (`agc_io_bytes` holds the count and the direction; a kind that moves no bytes leaves it zero); `agc_io_finish` copies it onto the job before `trace_finish` runs, since `data` is freed by then. Cost with metrics off: one store per I/O job in the kind's data, next to the system call it reports, and no branch | Throughput |
| `agentica_vm_processes_spawned_total` | counter | none | hook at `proc spawn` | Child process rate |
| `agentica_vm_process_spawn_failures_total` | counter | none | hook at `proc spawn_failed` | Missing executables, limits |
| `agentica_vm_processes_exited_total` | counter | `exit`: `zero`, `nonzero`, `signal` | hook at `proc exit` | Failing children; three values instead of the exit code, so the label set stays fixed |
| `agentica_vm_tcp_connections_total` | counter | `side`: `accepted`, `connected` | hook at `tcp_accept` and `tcp_connected` | Connection rate of a server and of a client |
| `agentica_vm_tcp_errors_total` | counter | `op`: `accept`, `connect` | hook at `tcp_accept_error` and `tcp_connect_error` | Failed connections |

Bytes written to stdout and stderr are not counted: they go through `agc_write`,
which has no trace point, and adding a test there would put a branch on the
output path. Later PRs (TLS, HTTP, UDP) add their metrics in the same PR, at
their own trace points, under these rules (for HTTP: requests by method class
and status class, never by path).

**End of run** (only in the last file write, 28.5; the endpoint is closed by
then)

| Name | Type | Labels | How | Why |
|---|---|---|---|---|
| `agentica_vm_exit_code` | gauge | none | derived (the code `vm/main.c` returns) | The main alert of a batch job |
| `agentica_vm_end_time_seconds` | gauge | none | derived (wall clock at the last write) | Alert when a cron job has not run for a day |
| `agentica_vm_runtime_errors_total` | counter | `code`: a `RUNTIME-` code | derived (the outcome); one series with value 1 when the run failed, none otherwise | Which runtime error ended the run; codes are a fixed list, messages are never exported |

Not measured: anything per function, per instruction, per task id, per path, per
host or per program value; message text; the step limit. Task ids, paths and
hosts stay in trace lines.

About 30 metric names and at most about 80 series (the histogram's 11 included),
fixed by the C lists, so a scrape is a few kilobytes.

### 28.4 How a snapshot is taken

Metrics come from two threads: the **scheduler thread** (each scheduler, with
N>1) owns the VM state and the hook counters; the **metrics thread** owns the
sockets, the file and the text format. Neither reads the other's plain data.

**The observe word.** Each scheduler gets one `unsigned observe` word that joins
the trace categories (from `AGENTICA_VM_TRACE`) and the metric bits. It lives in
an `agc_observe` block together with the scheduler's hook counters
(`agc_metrics_counts`, below). The block is `malloc`'d, never GC memory, so a
pointer to it may sit in a native's `malloc`'d state
(`docs/vm/10-io-scheduler.md` §10.2.2 forbids GC pointers there, and `agc_vm` is
GC memory). The scheduler reaches it through `vm->obs`: two loads, the same as
today's `vm->rt->trace.mask`. Every trace point that also carries a hook tests
the two together:

```c
#define AGC_OBSERVE(vm, trace_bits, metric_bits) \
  ((((AGC_TRACE_BUILD ? (trace_bits) : 0u) | (AGC_METRICS_BUILD ? (metric_bits) : 0u))) & (vm)->obs->observe)
```

so a trace point with a hook is still two loads and one test, the same as
today's `vm->rt->trace.mask`. The trace bits are copied into the observe word
once at start-up, from `agc_trace.mask`, and never change. Trace points with no
hook keep testing `agc_trace.mask` as today: the loader, `vm/main.c`, the
process guard's copy (`vm/process.c`, `struct guard`) and the trace-only points
of `proc` (`struct proc`). The metric bits are set only at the lazy start (28.2
rule 5), by the scheduler that owns the word, so before the first scrape they
are 0 and every hook behaves as if it were not there. Code that today keeps a
copy of the trace struct because libuv callbacks have no runtime pointer
(`proc`, the process guard, the TCP natives of PR #106) also keeps a pointer to
its scheduler's `agc_observe` block (next to its trace copy, which its
trace-only points still use), so a callback with a hook (`proc` exit, and the
TCP `tcp_connected`, `tcp_connect_error` and `tcp_accept_error` callbacks of PR
#106; `tcp_accept` runs in a builtin, which has the scheduler) sees the lazy
start in `observe` and counts into `agc_metrics_counts`. The callbacks run on
the loop thread of the scheduler that owns the native, so the counts stay
single-writer. One more bit, `AGC_METRICS_SERVE`, is set from start-up while
metrics are on; only the dequeue point tests it.

**The dequeue point.** The snapshot check and the run-queue delay hook must run
after the scheduler's bookkeeping (`finish_task` or `enqueue`, and the poll's
wakes), so a snapshot never sees a task in no list. That is the place right
before `dequeue`, at the two `agc_io_poll` call sites of the run loop (28.1):
after `agc_io_poll(vm, false)` at the end of a turn, and after
`agc_io_poll(vm, true)` when the queue was empty. The check is at the call
sites, not inside `agc_io_poll`, which returns early when the loop is not alive
(a CPU-only program). After a turn, the point takes over `trace_gc`'s turn-end
test: one test of
`observe & (AGC_TRACE_GC | AGC_METRICS_SERVE | AGC_METRICS_QUEUE)` replaces the
`gc` test that runs on every turn today, so the turn path has the same number of
tests as now, and the `gc collect at=turn` line moves to after the bookkeeping
(no test reads the order of trace lines). After a blocking poll the test is new,
but that path runs only when the thread has just been idle, never in a loop of
turns. With metrics off and `gc` tracing off, the test fails and nothing else
runs.

**Hook counters** are plain `uint64_t` fields in the `agc_metrics_counts` part
of the scheduler's `agc_observe` block, written only by that scheduler's thread.
The run-queue delay hook (bit `AGC_METRICS_QUEUE`, set at the lazy start) works
like this, with one clock read per dequeue:

- **Inside a turn**, a task that is spawned or woken gets the scheduler's last
  dequeue time (the start of this turn) as its queue time, with no clock read,
  at the `sched spawn` and `sched wake` trace points, which share their test
  with the hook. `enqueue` itself is not touched, so with metrics off nothing on
  the queue path changes.
- **Right after `agc_turn_finish`**, at the `sched turn` trace point (same
  shared test), the scheduler remembers the run queue's tail. The tail is an
  `agc_task *`, GC memory, so it is kept in `agc_vm` (the scheduler, itself GC
  memory), never in the `malloc`'d `agc_observe` block. Everything queued after
  that is queued after the turn's code ended: await waiters woken by
  `finish_task`, the task put back after a `yield`, and the wakes of the
  `agc_io_poll(vm, false)` that follows.
- **At the dequeue point**, the hook reads the clock once, stamps every task
  after the remembered tail with that value (a walk over just those tasks),
  records the delay of the task at the head of the queue (the next to run), and
  keeps the value as the last dequeue time. After a blocking poll the queue was
  empty before the wait, so the remembered tail is empty and every task in the
  queue, all woken by that poll, gets the value just read.

So only tasks spawned or woken inside a turn keep the earlier stamp, and their
wait is real: they waited at least the rest of that turn. A task woken right
after a long turn is not charged for that turn.

This hook is built for one scheduler (N=1) and is revisited with the multicore
schedulers (`docs/vm/10-io-multicore.md` §10.2.3): there is one global run queue
(`docs/vm/16-architecture.md` §16.3), and the I/O thread and the other
schedulers push into it at any time, so "the tasks after the remembered tail" no
longer covers every task queued since the turn ended.

**A request.** The metrics thread needs numbers (a scrape, or a file write is
due). It increments its request number and stores it in each scheduler's
`_Atomic uint64_t snapshot_seq` (release), then calls `uv_async_send` on that
scheduler's metrics async handle, which only wakes a scheduler blocked in
`uv_run(UV_RUN_ONCE)`; its callback does nothing. The scheduler sees a new
request at the dequeue point (above), through `AGC_METRICS_SERVE`: one relaxed
load per dequeue while metrics are on (`snapshot_seq` against the number it last
answered), nothing new while they are off. It then fills its part of the
snapshot, a `malloc`'d plain struct (no GC pointers): its hook counts, its
run-queue length and histogram buckets, its registry walk; scheduler 0 also
reads the GC getters, `next_task_id`, `tasks_done` and `steps_left`. It records
the request number it answered in the part, publishes it as `answered_seq`
(release) and calls `uv_async_send` on the metrics thread's loop. The thread
takes a part only when its `answered_seq` equals the request it is waiting for
(acquire), so an answer to a request that already timed out (28.5, `503`) is
ignored. Each scheduler has one part buffer, allocated at start-up and written
only by that scheduler; the thread never reuses or frees it while a request may
still be filling it: it sends a new request only after it has copied the last
part or given up on it, and the buffers are freed only after the end-of-run join
succeeds (on a join timeout the VM ends with `_exit` and frees nothing). The
first request also does the lazy start: it reads the clock once, sets the
scheduler's last dequeue time to that value and stamps every task already in the
run queue with it as its queue time (one walk, done once), so no task is
measured from a queue time of 0 and the first observations are not "since boot";
then it sets the metric bits and calls `GC_start_performance_measurement`. In
file mode the lazy start is done by main before `agc_vm_run`, together with the
start-up write (28.5): it reads the clock once and sets the scheduler's last
dequeue time to that value (main's first turn starts at a plain `dequeue`, with
no dequeue point before it, so without this the tasks spawned in that turn would
get a queue time of 0), then sets the metric bits and calls
`GC_start_performance_measurement`; no stamp walk is needed, since the queue is
still empty. (The lazy start's call sites, the first request and main before
`agc_vm_run` in file mode, come with 18a and do nothing until 18c fills them:
the stamps and `GC_start_performance_measurement` belong to the hooks.) With N>1
the metrics thread waits for every part and sums them: per-thread counters
summed at scrape, with no lock and no atomic add on the hot path.

- **Cost on the program's thread:** only while someone asks, a few dozen loads
  and copies plus the queue and registry walks, O(ready tasks + open resources),
  at a safe point between turns. It charges no steps and no turn cost (it is not
  program code), so `--max-steps` outcomes and step counts do not change; it
  delays the next turn by a few microseconds of wall time, as a page fault
  would.
- **The async handle is `uv_unref`'d,** so it never counts in `uv_loop_alive`:
  the stall check and the end of the run see the loop exactly as without
  metrics. With metrics on, the scheduler's loop is created at start-up instead
  of at the first I/O call, which no program can see.
- **A scheduler that does not answer in 4 seconds** (the budget; a test-only
  switch shrinks it, 28.8) (one builtin running that long, say a sort of a huge
  list) gets a `503` for that scrape. The snapshot wait has its own budget of 4
  seconds, shorter than the connection's 5-second deadline (28.5), so the `503`
  is always sent before the deadline closes the connection. The scheduler
  answers that request late, and the thread ignores the answer because its
  number is old; the next scrape sends a new number and gets fresh numbers. A
  late snapshot is never served as a current one. In file mode a late snapshot
  skips that periodic write.
- **Why the scheduler takes it, not the metrics thread:** Boehm is built without
  thread support (until §10.2.3), and its getters are unsynchronized; the run
  queue and the registry are plain data of the scheduler. Reading them from
  another thread would be a data race. Asking the owner keeps every hook a plain
  increment and every derived metric free, which is rule 4.

**The metrics thread** is started by `vm/main.c` before the run, only when one
of the two variables is set and valid. It runs its own `uv_loop_t`, separate
from the program's loop (with N > 1, the one loop of the I/O thread,
`docs/vm/16-architecture.md` §16.2), so a slow or hostile client never runs on
the program's thread and never touches the program's loop. It starts with every
asynchronous signal blocked (like the pool threads), never allocates GC memory,
never calls Boehm, and reads `/proc/self` for the `process_*` metrics itself. It
runs no Agentica code and no Agentica-visible task.

**The metrics thread's own I/O** uses plain POSIX calls (`open`, `write`,
`rename`, `read` of `/proc/self`), never `uv_fs_*`: the libuv thread pool is
shared with the program's file and stdin jobs, and four slow metrics writes
would delay them. Its sockets use its own loop, which never queues pool work.

**Stopping the requests.** Main must close the scheduler's metrics async handle
at the end, and the metrics thread must never call `uv_async_send` on it after
that. A small `pthread_mutex_t` in the metrics struct guards a plain
`bool stop`: the thread sends each request as lock,
`if (!stop) uv_async_send(...)`, unlock; main sets `stop` as lock,
`stop = true`, unlock. The mutex is taken only per request (a scrape or a file
write), never on the program's paths. Async sends the other way, from a
scheduler or main to the thread's own loop, are always safe: only the thread
closes its handles, and only after its last message (below).

**End of run,** in `vm/main.c`. The normal end sequence of the VM does not
change; metrics fit around it:

1. `agc_vm_run` returns. Main, which is the scheduler thread with N=1, fills the
   end-of-run snapshot from the state as the run ended (the derived metrics and
   its hook counts); with N>1 each scheduler fills its part as it stops.
2. Main sets `stop` under the mutex (above). From then on the thread sends no
   request; a scrape that waits for a snapshot gets a `503`. Main closes the
   scheduler's metrics async handle.
3. The normal end sequence runs unchanged: `end_run` in `vm/main.c` (§14.4: kill
   and reap the children, flush stdout, stderr and the files, the
   `fflush(stdout)` check that can turn the outcome into `RUNTIME-INTERNAL`, the
   diagnostic, and the exit code). It ends with `_exit`, so steps 4 and 5 below
   go inside `end_run`, before that call.
4. In `end_run` (`vm/main.c`), right after `code` is computed and before the
   final `_exit`: main adds the end-of-run metrics (the exit code, the
   `RUNTIME-` code, `tasks_done + 1`) to the snapshot and sends it to the thread
   with its "final" async. The thread writes the last file (when file mode is
   on) with the same temp-and-rename steps as the periodic writes, closes the
   listener and every client connection (a pending `uv_write` is cancelled),
   closes its own handles and leaves its loop. All file writes happen on the
   thread, in order, so the last write is always the last one.
5. Still before `_exit`, main waits for the thread with a timeout of 1 second
   (`pthread_timedjoin_np` on Linux). The thread never blocks on a socket, but a
   file write can block on a slow or stuck disk. On a timeout main goes on to
   `_exit(code)` without it, which never joins the thread. The exit code and the
   program's output are right; the limit, stated plainly: the last file may be
   missing, or older, when the disk does not take the write within a second.

A run killed by a signal, or ended by the out-of-memory handler (exit 70, which
may only `write(2)` fixed text), writes no last file; the periodic writes cover
it.

### 28.5 How it is exported

**Compared:**

| Way | Fits | Cost and risk | Decision |
|---|---|---|---|
| (a) Pull endpoint: the VM serves `GET /metrics` | Long-running programs (servers, workers); the normal Prometheus way | A listener and a tiny HTTP responder; must never keep the VM alive; a run that ends before a scrape is never seen | **Planned (18b)** |
| (b) Textfile for node_exporter's textfile collector | Batch jobs and scripts, which end before any scrape; hosts that already run node_exporter | One atomic file write every 15 seconds and at the end; file safety rules | **Planned (18a)**, first, since it needs no socket |
| (c) Push to a Pushgateway | Batch jobs | Needs an HTTP client in C, retries, a reachable gateway; Prometheus advises it only for batch jobs, which (b) covers | Not planned |
| (d) OpenTelemetry (OTLP) | Shops on OTel | Protobuf over HTTP or gRPC in C; a large dependency for the same numbers. The OTel Collector's Prometheus receiver can scrape (a) | Not planned; to evaluate later only if a user needs push to OTLP |

(a) and (b) answer different needs (a process that runs, a run that ended), and
both may be set at once; they share the snapshot and the text format.

**The format** is the Prometheus text exposition format 0.0.4: `# HELP` and
`# TYPE` lines, then samples, with
`Content-Type: text/plain; version=0.0.4; charset=utf-8`. Not OpenMetrics, not
protobuf, no gzip: Prometheus reads 0.0.4 everywhere, and it is the one format.
Label values are fixed C strings that need no escaping; the version strings in
`agentica_vm_build_info` are checked at build time to contain no `"`, `\` or
newline.

**(a) The endpoint: `AGENTICA_VM_METRICS=[IP:]PORT`.**

- `9464` means `127.0.0.1:9464`. `IP:PORT` with an IPv4 literal, or
  `[IPv6]:PORT`, binds that address; `0.0.0.0:9464` is how a container exposes
  it, and it must be written out. No host names (no DNS at start-up). Port 0
  picks a free port, for tests. 9464 is the port OpenTelemetry's Prometheus
  exporter uses; it is only an example, there is no default port.
- `vm/main.c` binds and listens before the run, on the metrics thread's loop
  (made on the main thread, then run on the metrics thread), so the bound port
  is known before the program starts and a bind error is seen at once. A bad
  value, or a failed bind, writes one line `agc-metrics cannot listen VALUE`
  (with the reason) to stderr and the run goes on without the endpoint, as
  `AGENTICA_VM_TRACE_FILE` does with `cannot open`. The chosen address and port
  are written as a trace line `metrics listen host=127.0.0.1 port=41234` (the
  `metrics` trace category, added in 18a for the file writes), which is how
  tests find a port-0 endpoint: they set `AGENTICA_VM_TRACE_FILE`, so the line
  goes to a file and stderr does not change.
- **The responder is not the HTTP stack.** It reads at most 8 KiB, until the
  first `\r\n\r\n`; then it looks only at the request line, which must be
  exactly `GET /metrics HTTP/1.1` or `GET /metrics HTTP/1.0`. Headers are
  ignored and a request body is never read. Replies: 200 with the metrics; 404
  for another target (query strings included); 405 with `Allow: GET` for another
  method; 400 for a request line of another shape; 431 when 8 KiB pass without
  the end of the head; 503 when the snapshot does not come within its own budget
  of 4 seconds (28.4). Every reply has `Content-Length` and `Connection: close`,
  and the connection is closed after the write. Each connection has one
  deadline, 5 seconds from accept to close, covering the read of the head, the
  wait for the snapshot (at most 4 seconds of it, then `503`) and the write of
  the reply; at the deadline the connection is closed, whatever it is doing. It
  is not an idle timeout, so a client that sends one byte a second still ends at
  5 seconds. At most 4 connections are open at once; more are accepted and
  closed at once. It does not use picohttpparser or the HTTP PR's code, so it
  does not wait for HTTP on the VM, and a bug in it cannot reach the program's
  HTTP server.
- **It never keeps the VM alive.** The listener lives on the metrics thread's
  own loop, not on the program's loop (with N > 1, the I/O thread's), so it is
  never in `uv_loop_alive` of the program and never delays the stall check. When
  `main` ends, the VM stops and joins the thread (28.4) and exits, even while a
  client is connected or a scrape is in flight. There is no "wait for a last
  scrape" option: it would let monitoring change when a program ends.
- **A short run** that ends before the first scrape is never seen at the
  endpoint; Prometheus records the target as down. That is expected: use the
  file for runs that end.
- **Children.** `Process.spawn` removes `AGENTICA_VM_METRICS` and
  `AGENTICA_VM_METRICS_FILE` from the environment a child inherits, as the VM
  already edits a child's environment for `UV_USE_IO_URING` (`drop_uring_env`).
  `child_env()` in `vm/process.c` becomes `child_env(bool drop_uring)` and runs
  when `drop_uring_env` is set or either metrics variable is present. It removes
  `UV_USE_IO_URING=` only when `drop_uring` is true (the VM set it itself; a
  value the user set is passed on as today), and removes `AGENTICA_VM_METRICS=`
  and `AGENTICA_VM_METRICS_FILE=` whenever they are present, also when the value
  is empty or invalid (the parent ignored it, but a child VM would print its own
  warning). Each name is matched with its `=`, so `AGENTICA_VM_METRICS=` never
  catches `AGENTICA_VM_METRICS_FILE=`. Otherwise a child VM would fight for the
  port (and print `cannot listen` into the program's stderr) or overwrite the
  parent's file. `Process.spawn` has no environment parameter
  (`src/builtins.rkt`: command, arguments, timeout), so a program that wants
  metrics from a child VM runs it through `env`, with another port or file:
  `Process.spawn("env", ["AGENTICA_VM_METRICS=9465", "agentica-vm", "--", "child.agcb"], 5000)`.
  No environment parameter is planned here. This differs from tracing on
  purpose: a child's trace lines append to the same file safely; a port and a
  file cannot be shared.
- **VMs started by a driver.** By phase 18, `agentica test` runs a runner VM
  that starts a child VM per scenario, and those children start the programs
  under test (phase 21, `docs/bdd.md`, "How a run works"); all of them would
  inherit the variables too. `src/bdd-driver.rkt` removes `AGENTICA_VM_METRICS`
  and `AGENTICA_VM_METRICS_FILE` from the runner VM's environment when it starts
  it (`docs/bdd.md`, "How a run works"), so every VM below it inherits the
  cleaned environment; 18a checks that this holds (a test that runs
  `agentica test` with both variables set and finds no listener and no file),
  and the runner needs no code of its own.

**(b) The file: `AGENTICA_VM_METRICS_FILE=path`.**

- The path must end in `.prom` (node_exporter's textfile collector reads only
  those, so another name would be a silent no-op) and its directory must exist.
  Before each `rename` the writer calls `lstat` on the path: if something is
  there, it must be a regular file (not a symlink, not a directory or FIFO)
  owned by the VM's user; otherwise the write is skipped. This check is new: the
  trace file is opened and then checked with `fstat` on the open descriptor,
  which does not fit a file that is replaced by `rename`. The check guards
  against replacing a file that belongs to someone else; it is not what keeps
  the write safe, since `rename` never writes through a symlink (below). At
  start-up a failed check writes one line `agc-metrics cannot write PATH` and
  turns file output off; later a failed check skips that write and is reported
  on the `metrics` trace category.
- **Atomic rewrite:** the metrics thread writes the whole text to
  `DIR/.NAME.PID.RANDOM.tmp`, opened with
  `O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC` and mode 0644, then `rename`s
  it over the path. `RANDOM` is 16 hex digits from the OS entropy source the VM
  already uses for its seeds (`getrandom`), read for each write, so a name
  cannot be guessed and a temp file left by a killed run, or planted by someone
  else, never blocks the write: on `EEXIST` the writer draws a new name and
  tries again, up to 4 times, and only then skips that write. After the open it
  calls `fchmod(fd, 0644)`, so a strict umask (for example `UMask=0077` in a
  systemd unit) cannot hide the file from node_exporter, which runs as another
  user; metrics hold no program data (28.7). A reader sees the old file or the
  new one, never half of one. `rename` replaces a symlink planted at the path
  instead of writing through it. The temp name starts with `.` and does not end
  in `.prom`, so the collector never reads it; a failed write removes it. No
  `fsync`: the file is a view of a running process, not a record.
- **Old temp files.** A run killed during a write leaves its temp file. At
  start-up, the writer removes the temp files of its own path left by earlier
  runs: names that match `.NAME.*.tmp` in the path's directory, and only those
  that `lstat` shows to be a regular file owned by the VM's user and last
  changed more than 1 hour ago (no write takes that long, so it never removes a
  file another VM is writing). Anything else is left alone. So leftover files
  never pile up for long.
- **When:** once at start-up, every 15 seconds while the program runs (fixed;
  node_exporter is scraped about that often, and a knob would be a second way to
  tune the same thing), and once at the end with the end-of-run metrics. The
  start-up write comes as soon as the path checks pass, before `agc_vm_run`:
  main does the file-mode lazy start (28.4), fills a snapshot without end-of-run
  metrics, and hands it to the metrics thread, which writes it. It replaces the
  previous run's file, so a run that dies before its first periodic write
  (killed, out of memory) leaves a file with no `agentica_vm_exit_code`, and a
  dashboard or alert sees that the last run did not end cleanly instead of the
  previous run's `0`. The periodic writes go through a snapshot request like a
  scrape, and the hooks start at start-up in this mode (28.2 rule 5). A failed
  write is reported once on the `metrics` trace category and retried at the next
  interval; it never ends the run.

**Scraping cost is not the program's.** Accepting, reading, formatting and
writing happen on the metrics thread. The scheduler's share (28.4) charges no
steps and no turn cost.

### 28.6 Program-level metrics

Should a program define its own counters, gauges and histograms, served on the
same endpoint (a `Metrics` builtin module or `std/metrics`)?

**Decided: not in phase 18; to evaluate later**, after shared tables (phase 9)
and HTTP on the VM. Reasons:

- A counter is shared mutable state. Agentica values are immutable. Apart from
  the logger registry (§24.2), the language has no shared mutable state: shared
  tables (`docs/future/13-ats.md` §13, phase 9) are the planned way, on demand.
  A `Metrics` builtin with hidden mutable state would be a second special form
  for sharing state between tasks, against the one-way rule, next to the logger
  registry.
- The std-first rule (roadmap README): rendering the Prometheus text format is
  pure computation, so it belongs in a `std/` module, not in a builtin. Only the
  hidden state would need C, and that is the part that should not exist on its
  own.
- Program data in labels is how secrets and unbounded label sets leak (28.7).
  The VM's endpoint is safe because every label value is a fixed C string;
  mixing in program labels would lose that.
- A program that needs its own metrics can already serve them: once HTTP runs on
  the VM, `HTTP.listen` on its own port with a `/metrics` route, building the
  text itself. Prometheus scrapes two targets (the VM's port and the program's
  port); that is normal.

When evaluated, the candidate is a `std/metrics` module that only renders the
text format from values the program holds (in a shared table, or in the state of
a task that owns them), served by the program's own HTTP listener: pure
Agentica, no builtin, no link to the VM's endpoint.

### 28.7 Security

- **Localhost by default.** A bare port binds `127.0.0.1`. Any other address
  must be written out. There is no authentication and no TLS: when the endpoint
  must be reached from outside the host, put it behind the network's own
  controls (a firewall, a Kubernetes network policy, a reverse proxy with TLS).
  Do not expose it to the internet.
- **No program data.** No label or value comes from the program: no paths,
  hosts, function names, task ids, messages, arguments, environment or input.
  Label values are fixed C strings; the only free text is the build versions. So
  the file can be world-readable (0644) and the endpoint leaks only how busy the
  VM is and how much memory it uses.
- **Bounded label sets.** At most about 80 series, fixed at compile time; a
  program cannot add one.
- **Bounded work per client:** 8 KiB of head, a total of 5 seconds from accept
  to close, 4 connections, one reply, then close. No request body is read. A
  flood of connections costs the metrics thread, never the program's thread.
- **The file** must be a regular file owned by the VM's user, checked with
  `lstat` before each `rename` (28.5), and is replaced by `rename`, never
  written in place. The temp name has a random part, so another user cannot
  block it or predict it.

### 28.8 Tests

All hermetic: localhost, port 0, temporary directories, no external service.
Expected values come from fixtures whose numbers are known.

- **C tests** (`vm/tests/metrics_test.c`): the renderer against a fixed snapshot
  (exact text), the `[IP:]PORT` parser (good and bad values), the request-line
  check (each reply code), the path checks of the file. The path check takes the
  expected owner's uid as a parameter, the same way the writer takes its random
  source, so the test checks that a file owned by another uid is refused without
  needing a second user.
- **A test-only switch for times:**
  `AGENTICA_VM_TEST_METRICS_TIMES=budget_ms,deadline_ms`, read once at start-up
  into the runtime config like `AGENTICA_VM_TEST_NO_TURN_COST`, replaces the
  4-second snapshot budget and the 5-second connection deadline, so the 503 and
  deadline tests do not depend on machine speed and run fast. It is for tests
  only and is documented next to `AGENTICA_VM_TEST_NO_TURN_COST`.
- **The format is read by an independent parser:** a small parser of the text
  format in Python's standard library, in the test file (one `# TYPE` per name
  before its samples, names and label names match the Prometheus patterns,
  `_total` only on counters, histogram buckets non-decreasing with `le="+Inf"`
  equal to `_count`). Python is a required tool for these tests (the parser, the
  HTTP client, the file reader): CI installs it and the tests fail when it is
  missing. The Python parser is the independent check; no other tool (such as
  `promtool`) is used, since a new tool needs the user's approval.
- **Known numbers** (`tests/vm-metrics-test.rkt`): a fixture that spawns 10
  tasks and awaits them gives `agentica_vm_tasks_spawned_total 11` and
  `agentica_vm_tasks_finished_total 11` in the last file (10 from `tasks_done`,
  plus main once the outcome is known), and a scrape while main waits shows
  spawned minus finished of at least 1; an allocation-heavy fixture
  (`map-large`) gives `agentica_vm_gc_collections_total` above 0 (not on a
  sanitizer build); a fixture that spawns a child that exits 3 gives
  `agentica_vm_processes_exited_total{exit="nonzero"} 1`; a failing fixture
  gives `agentica_vm_exit_code 1` and its `RUNTIME-` code.
- **Nothing changes for the program:** a set of golden fixtures (tasks, files
  and stdin, processes with a child that writes to stderr, a runtime failure, a
  `--max-steps` stop) runs with the endpoint on (and scraped every 100 ms by a
  Python client during the run) and with the file on; exit code, stdout and
  stderr must be byte for byte the goldens, and the `--max-steps` fixture must
  stop at the same place.
- **Timing-sensitive cases go in their own file,**
  `tests/vm-metrics-timing-test.rkt`, listed in `test-omit-paths` in
  `tests/info.rkt` next to `vm-latency-test.rkt`, so `make test`'s parallel
  batch never runs them. A `make vm-metrics-timing` target runs it alone, and CI
  runs it in its own step right after `make vm-latency`. They are the cases
  marked *(timing file)* below; the rest go in `tests/vm-metrics-test.rkt`.
  Their bounds leave room for a loaded runner: each says what must happen, with
  a limit several times the expected time.
- **The endpoint never keeps the VM alive** *(timing file)*: a program that ends
  at once exits with the endpoint on; a program that ends while a Python client
  holds a connection open, or has sent half a request, exits within 5 seconds of
  `main` ending (it takes about the 1-second join at most).
- **The endpoint's replies:** 200 with a parsable body; 404, 405, 400, 431 (in
  `tests/vm-metrics-test.rkt`). *(Timing file:)* 503 with
  `AGENTICA_VM_TEST_METRICS_TIMES=1,300`: a fixture runs a few long turns in a
  row (sorts of a list that takes well over 1 ms on any machine), the test
  scrapes during them and gets `503` and not a closed connection, and a scrape
  after the sorts end gets 200; and the close at the 300 ms deadline, both for a
  silent client and for one that sends one byte every 50 ms: the connection must
  close after at least 300 ms and within 3 seconds; a fifth connection is closed
  at once. The port comes from the `metrics listen` trace line, read from the
  file named by `AGENTICA_VM_TRACE_FILE` (with `AGENTICA_VM_TRACE=metrics`), so
  the program's stderr stays the golden stderr.
- **File mode:** *(the reader loop is in the timing file)* a reader loop in
  Python reads the file while a 3-second program runs and must always find a
  whole, parsable file (atomic rename); a symlink at the path gives the
  `cannot write` line and no output (another user's file is the C test above);
  other files in the directory with temp-like names do not stop the write; the
  file has mode 0644 even under `umask 077`; the VM's own temp file is gone
  after the run. Old temp files: one of the path's temp names changed 2 hours
  ago is removed at start-up, one changed 10 minutes ago is kept, and a symlink
  with a temp name is kept.
- **The `EEXIST` retry** is tested in `vm/tests/metrics_test.c`: the writer
  takes its random source as a parameter, so the test passes one that returns a
  fixed sequence, plants files under the first names, and checks that the write
  lands on the next free name, and that it skips the write after 4 taken names.
- **Start-up write** *(timing file)*: the path holds a previous run's file with
  `agentica_vm_exit_code 0`; a program that sleeps runs, the test waits for the
  `metrics write` trace line of the start-up write in the trace file, kills the
  VM with `SIGKILL` (well before 15 seconds), and the file then has no
  `agentica_vm_exit_code`.
- **Lazy start** *(timing file, 18c)*: a program keeps CPU tasks ready for 3
  seconds before the first scrape; in that scrape the run-queue histogram has
  the same count at `le="1"` as at `le="+Inf"`, so no task was measured from
  boot.
- **Children:** a `Process.spawn` child that prints its environment does not see
  the two metrics variables, sees a `UV_USE_IO_URING` value the user set, and
  does not see one the VM set; with only `AGENTICA_VM_METRICS_FILE` set,
  `AGENTICA_VM_METRICS_FILE` is removed and nothing else. A scenario run by
  `agentica test` does not see the metrics variables either.
- **File-mode start** *(timing file, 18c)*: in file mode, main spawns tasks in
  its first turn and they wait behind a CPU task; the last file has the same
  count at `le="1"` as at `le="+Inf"` (no delay measured from 0).
- **Off means off:** the Makefile `unexport`s `AGENTICA_VM_METRICS`,
  `AGENTICA_VM_METRICS_FILE` and `AGENTICA_VM_TEST_METRICS_TIMES` next to the
  trace variables, and every test file that removes `AGENTICA_VM_TRACE` removes
  all three too when it loads (today `tests/bytecode-test.rkt`,
  `tests/cli-in-process.rkt`, `tests/modules-test.rkt`,
  `tests/process-test.rkt`, `tests/stdlib-distribution-test.rkt`,
  `tests/vm-diff-common.rkt`, `tests/vm-latency-test.rkt` and
  `tests/vm-trace-test.rkt`), so a developer's setting cannot change expected
  output. The `vm-sanitizers` CI job also builds `make vm vm-test METRICS=0`,
  and `agentica-vm --version` says `metrics off` there.
- **Overhead check** (manual, like `make bench`; not in `make test` or CI, where
  timing is noisy): a CPU-heavy program from `benchmarks/programs/` (`calls` and
  `knight-tour`, with `--size` set so a run takes at least 10 seconds) runs
  three ways: metrics off; the endpoint on with no scraper; the endpoint on with
  a Python scraper every second. Expected median wall-time overhead against
  "off": about 0 (the same code path); about 0 (one flag load per turn of about
  2000 steps); below 2% (the hooks, including one clock read per dequeue for the
  run-queue histogram, and a snapshot per second). A run that goes over the
  bound blocks the PR until the hook is made cheaper or dropped.
  `benchmarks/run.py` gets a `--metrics-overhead` mode for it, and the numbers
  go in `docs/vm-benchmarks.md` with the 18b and 18c PRs.

### 28.9 Where the code goes

- `vm/metrics.h`: the `agc_metrics` settings (address, file path), the
  `agc_observe` block of a scheduler (`malloc`'d: the observe word and
  `agc_metrics_counts`), the snapshot struct, the metric bits of the observe
  word, `AGC_METRICS_BUILD`. `vm/metrics.c`: the variable parsing, the snapshot
  fill (scheduler side), the renderer, the file writer, the metrics thread and
  its responder. Both under the C rules of the development skill (file order, no
  static prototypes, `agc_` names, no mutable globals: all state is in the
  runtime, the scheduler and the thread's own `malloc`'d struct).
- `vm/trace.h`: the observe word and `AGC_OBSERVE`, shared by trace points and
  hooks; the new `metrics` category in `vm/trace.c` (18a, with its `write`
  lines; 18b adds `listen` and scrape lines), and `metrics` in the category
  regex of `tests/vm-trace-test.rkt`.
- `vm/main.c`: one `start_observe` reads the trace and metrics variables
  together before loading; it starts the metrics thread, and at the end sets
  `stop`, hands the final snapshot to the thread, and joins it with the 1-second
  timeout (28.4). The `.prom` path check (`lstat` before `rename`) is new code
  in `vm/metrics.c`, apart from the trace file's `fstat` check.
- `vm/task.c`, `vm/loop.c`, `vm/process.c`, `vm/tcp.c`: the hooks, each at an
  existing trace point, and the dequeue point at the two `agc_io_poll` call
  sites of the run loop (28.4).
- `vm/port.h`: the `agc_io_bytes` struct and the new out-parameter of
  `agc_io_kind.done`; `vm/loop.c` (`agc_io_finish` copies the count onto the
  job); and each kind's file, `vm/files.c`, `vm/input.c`, `vm/process.c` and
  `vm/tcp.c`, which keep the count in their `data` next to the system call and
  report it from `done` (18c).
- `tests/info.rkt` (the timing file in `test-omit-paths`), the Makefile
  (`vm-metrics-timing`), and a CI step in `.github/workflows/ci.yml` after
  `make vm-latency`.
- The Makefile: `METRICS=0` passes `-DAGC_METRICS_BUILD=0` and goes in the
  `build/vm/flags` stamp like `TRACE` and `SANITIZE`; the `unexport` line. `vm/`
  is already in the `ci.yml` path list.
- Multicore (`docs/vm/10-io-multicore.md` §10.2.3): the snapshot design stays;
  the run-queue delay hook is revisited then (28.4: pushes from the I/O thread
  and from other schedulers into the global run queue break the "after the
  remembered tail" rule). Each scheduler has its own counts, observe word and
  snapshot part; the metrics thread sums the parts. An idle scheduler waits on
  the run queue's condvar, not in `uv_run` (§16.3), so how a request wakes it
  changes then. Scheduler 0 reads the GC (with Boehm's thread support on,
  through `GC_get_prof_stats`, which takes the GC lock) and the shared atomics.
  No lock and no atomic add on the hot path.
- Docs with each PR: `docs/vm/08-loader-and-cli.md` §9 (the variables, as
  built), `docs/vm/10-io-scheduler.md` (the snapshot point and the unref'd
  async), the development skill, and a short operator page. Not `grammar.md` or
  the programming skill: programs do not see metrics.

### 28.10 Tracing and metrics

Tracing (§24.4) and metrics share the rules (never crash, never change the
program, environment variables read once at start-up, compiled out by a build
flag, removed in tests), the owner rule for files (each with its own check:
`fstat` after open for the trace file, `lstat` before `rename` for the `.prom`
file) and the observe word, so a point that has both still costs one test. They
answer different questions: a trace is every event of one run, read by a
developer after the fact; metrics are a few totals and gauges of a running VM,
polled by Prometheus and graphed over days. Metrics never write per-event lines,
and tracing never keeps totals. To see why a number on a graph moved, turn on
the matching trace category.

### 28.11 Not planned

- Push to a Pushgateway, OTLP export, OpenMetrics or protobuf formats, gzip, TLS
  or authentication on the endpoint, a configurable path, port or file interval.
- Keeping the VM alive for a last scrape.
- A GC pause histogram (to evaluate later, 28.3), per-function or
  per-instruction metrics, labels from program data.
- Metrics defined by programs (to evaluate later, 28.6).
- Metrics on platforms other than Linux, until those platforms are tested again.

### 28.12 Memory diagnosis (18d)

**Status:** planned by the owner on 2026-10-13, as the fourth PR of phase 18,
after 17b. KISS. A program grows in memory and the gauges of 28.3 show it, but
not which task did it. This section adds the least that answers that. It follows
the rules of 28.2, except as noted under "Cost".

**In v1:**

- **Per-task counters.** Two numbers for each task. Bytes allocated by the task:
  counted at the central allocation path (`agc_alloc` and `agc_alloc_atomic` in
  `vm/value.c`) into the running task's counter, with a plain add and no atomic,
  since only the thread that runs the task writes it. It is bytes allocated in
  total, not bytes alive: Boehm does not say who holds an object. Bytes of C
  buffers held by the task's handles: exact, because a handle has one owner (the
  rule of 14.5, row 7.2.1a, 24b); each handle's `malloc`'d bytes are counted
  where it allocates and frees them, and they are added up by owner.
- **Global numbers.** What Boehm already gives (the heap, the free bytes and the
  total allocated, `agentica_vm_gc_*` of 28.3) next to the process RSS
  (`process_resident_memory_bytes`). Nothing new is measured.
- **An on-demand dump of the top N tasks** by the numbers above, each with its
  entry function, its parent and its age. How it is asked for is open. Options:
  a path on the metrics endpoint (18b); a signal; a variable that writes the
  dump at the end of the run. N is a small constant set in the 18d spec.

**Not in v1:** a per-category heap walk; hooks into libuv's and OpenSSL's
allocators; heap snapshots; per-task Prometheus labels (task ids stay out of
labels, 28.3).

**Cost.** Rule 4 of 28.2 drops any metric that needs work on the hot path while
nobody asks. The per-task add is that work: one non-atomic add per allocation.
The 18d PR must show that it passes the overhead check of 28.8, or change rule 4
first, with the reason (as 14 asks of its rules).

**Open.** How the allocation path finds the running task's counter: `agc_alloc`
takes no scheduler, and `vm/` has no mutable globals
(`docs/vm/10-io-multicore.md` §10.2.3). Options: a new parameter on the
allocation functions (every caller changes); a thread-local variable (one
documented exception to the no-globals rule); or counting in the callers that
have the scheduler (builtins and opcodes), which misses allocations made deeper
in helpers.
