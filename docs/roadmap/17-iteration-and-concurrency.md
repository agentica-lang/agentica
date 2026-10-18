## Phase 17: Iteration and concurrent collections

Specified in [`docs/future/27-iteration-and-concurrency.md` section
27](../future/27-iteration-and-concurrency.md),
with the one-way principle of §25, its table of one form for each job, and its
rule that the concurrency primitives are C builtins and higher-level helpers are
Agentica code in the compiler prelude. All items come after 7i (order 7.2) and
are VM-only. 17a is order step 7.3, after HTTP 20b, task crash isolation ([phase
24](24-task-crash-isolation.md)), unit tests ([phase 25](25-unit-tests.md)) and
HTTP 20c (order step 7.2.1), and after doc comments and digit separators (order
step 7.2a) and the semantic CLI (phase 26, order step 7.2b), before HTTP
streaming, which is built on channels, and `TlsContext` (order step 7.4), and
before default parameter values (15a) and the other items of order steps 7.5 and
7.6. 17b was moved earlier by the owner on 2026-10-13, to order row 7.2.1e: two
PRs, the spec of §27.2 first (docs only), then the implementation, because
stdout and stderr on the loop (row 7.2.1f) build on its parking mechanism. 17d
(`File.each_line`, order row 7.2.1h, which lands before 17a) adds a small
checker change for a block whose result is `Result[T]`: its last expression is
checked as a completion value, so a Void or non-Result last expression is
`CHECK-TYPE-MISMATCH` with a help that shows `ok()`. `try` in a block with a
fixed `Result` type already worked (`Test.test`); the case where `T` is inferred
from the block (§25.9) came with 17a. They land before
strict diagnostics (phase 16), so their examples, golden fixtures, tests and
site pages are written in today's forms, and each phase 16 PR counts and
migrates them (§26, "Impact on existing code"). They need neither faster lists
(8d) nor the prelude: both are C builtins, under the library rule's exception 1
(time) for 17a and exception 4 (its own memory layout) for 17b, and both park
tasks, which only the scheduler can do (§27.1 and §27.2, "Where it lives"). 17c
was planned for order step 8.2 as prelude code over channels, after the prelude
(15f) and lambdas (15e); the owner decided on 2026-10-14 to build it now as a C
builtin that returns the builtin enum `Await[T]`, so it is out of row 8.2 and
needs neither. One PR per item, in the order 17a, 17b, 17c, each with
`grammar.md`, the programming skill (`references/tasks.md`), the site pages, the
development skill's notes, the `docs/vm/` sections named in §27, and tests that
assert codes and spans (checker tests, golden VM fixtures, site examples, and
hermetic I/O tests against a Python counterpart on port 0). Section 27.4 adds
two items: 17d (`File.each_line`, row 7.2.1h) and 17e (`Stream[T]`, order step
8.2). Section 27.5 adds no item: its help hints come with 17a and 17b.

- [x] 17a `Task.map(items, limit, timeout_ms) do |x| ... end` (§27.1): bounded
  concurrency (`limit` 1 to 1024, `RUNTIME-INVALID-COUNT`), a per-item timeout
  (`RUNTIME-INVALID-DURATION` when not positive), one `Result` per item in input
  order, the block's `error` does not stop the others, and a timed-out item and
  its descendant tasks are cancelled (items are children of the caller; when a
  task ends, its running children move to its parent; a cancelled caller's group
  is marked dead, so its pending items never start). Arguments are checked
  before the empty-list shortcut. Checker: `try` in the block when `R` is
  inferred (§27.1, §25.9), which no earlier item needs: `try` in a block with a
  fixed `Result` type already worked, and 17d added only the completion-value
  check and its help. `try` works in the block even when `R` is inferred, since
  the outer type is always `Result`; this item adds it unless 15i lands first,
  and the other reuses it for the `File.open` block. A timed-out item leaks the
  handles it opened until the run ends; a connection that an HTTP request leases
  internally is closed when its detached job ends. VM: the builtin and its group
  object, and task cancellation (`agc_task_cancel`, parent and children links on
  each task; the core, for ready tasks, I/O jobs, lock waits, awaits, sleeps and
  HTTP pool waits, landed earlier in 20b for `HTTP.close_server`, [phase
  20](20-hybrid-http.md), with its C tests in `vm/tests/task_cancel_test.c`; 17a
  adds only the `Task.map` group and caller states and their C test): a
  cancelled task's I/O job is detached (it ends on its own deadline, its result
  is dropped, the handle is not closed), the task leaves lock and await queues,
  a handle lock's `next_owner` passes to the next waiter, and tasks parked in
  `Task.await` on it are woken and halt with `RUNTIME-TASK-CANCELLED` at their
  own span; a task parked as a `Task.map` caller or on a `Task.sleep` timer is
  cancelled too. That VM path, its C test and its line in
  `references/diagnostics.md` came earlier, with the cancellation core of 20b; a
  program cannot reach it before channels. Appended builtin, no format bump.
  Hints for `Task.async_stream`, `Task.async`, `Parallel.map` and `Thread.new`.
  Tests: the checker tests, golden fixtures and C tests of §27.1,
  `tests/test_vm_task_map.py`, like `tests/test_vm_latency.py` (in `PY_ALONE`
  of the Makefile, its own `make vm-task-map` target, a CI step in the `test`
  job after `make vm-latency`, a line in the Commands section of `AGENTS.md`),
  which holds every timing-dependent case of phase 17, since
  golden fixtures record step counts and run the `--max-steps` sweep and must
  not depend on timing (concurrency bound, timing with safe bounds, timeout,
  cancellation of a grandchild whose parent ended and of a nested `Task.map`
  with `limit` 1 whose pending items never print, and a detached read on a TCP
  socket shared by two items, against a Python peer on port 0) and the Python
  `http.server.ThreadingHTTPServer` counterpart (with a timed-out request that
  leaves no open socket). From 17b (decided 2026-10-14): the two
  `RUNTIME-TASK-CANCELLED` cases of §27.2 and the `Task.map` form of its
  hand-off case, in `tests/test_vm_task_map.py`. Docs: `grammar.md`
  ("Lightweight tasks", §7 hints), `references/tasks.md` (the `limit` sentence
  and the handle rules of §27.1), `site/content/library/concurrency/task.md` and
  `site/content/tour/tasks.md`, `docs/vm/10-io-scheduler.md` §10.2.1 and
  §10.2.2, `docs/vm/10-io-multicore.md` §10.2.3.
  Done (PR #316): `Task.map` in `vm/task_map.c` (core layer, a stepper like
  `File.each_line`): the caller parks in the call and, each time it wakes,
  collects the items that ended, expires the oldest item whose deadline has
  passed (cancel, slot `error("task: timed out")`), starts items up to `limit`
  (one step each, `agc_count_step`) and waits on one timer for the oldest
  deadline, in place of one timer-only job for each item: every item has the
  same timeout and starts in input order, so the deadlines grow along the
  running list. The items are children of the caller, spawned in its own turns
  (`agc_task_spawn_seeded`), so the random streams split in input order. An end
  hook on the task (`end`, `end_data`) tells the group that an item ended; a
  cancelled caller needs no `dead` flag, since it never runs again and its items
  are cancelled children-first, and the hook ignores a cancelled item. An item
  that ends after its deadline but before the caller runs keeps its result. An
  item with a file close pending is settled when the last close ends (the hook
  puts itself back and `agc_task_close_done` calls it again), as `Task.await`
  waits for it; an item that runs out of time is settled at its deadline
  without waiting for its close (its crash, if any, is marked observed). The
  result list costs one turn unit per item (`agc_charge`). The
  handles an item opened are closed when it ends or is cancelled (24b), so the
  sentence above about a leak no longer holds; the detached HTTP request closes
  its connection when it ends. Checker: `Rule.TaskMap` and the catalog row, the
  `Slot.InferResult` slot for a block whose `Result[T]` is inferred (`try` works
  in it; `R` from the expected type or the first value; a first value of
  `error(...)` needs the annotation, `CHECK-RESULT-TYPE`), the hints. Tests:
  eleven golden fixtures (`task-map-*`, one of them with files that the items
  leave open, and `step-limited/task-map-runaway`), the spec cases in
  `tests/fixtures/spec/checker-rest.json`, C cases in
  `vm/tests/task_cancel_test.c` (a parked caller cancelled; items that run out
  of time; items that end with closes pending, settled when the last close ends;
  a crash with a late close, settled as timed out and marked observed; the end
  hook of `agc_task_close_done`), and `tests/test_vm_task_map.py` in place of
  the Racket file (`PY_ALONE`, `make vm-task-map`, a CI step after `make
  vm-latency`): the bound on the items in flight, HTTP against a
  `ThreadingHTTPServer`, timeouts, a grandchild, a nested map, a detached read,
  a timed-out HTTP item with no pooled connection, `RUNTIME-TASK-CANCELLED` in
  both cases, the argument spans, `--seed`, and a hand-off case that holds the
  CPU in one sort past the deadline and checks that the item keeps the value.
  The hand-off case of §27.2 in its sketched form (the item cancelled between
  the reservation and its run) does not happen with one caller timer, since the
  item runs before the caller looks at the clock; the owner accepted this in
  review.
- [x] 17b `Channel[T]` (§27.2), order row 7.2.1e. Decided (2026-10-14): the
  cases that need `Task.map` move to 17a's PR, where `Task.map` exists: the two
  `RUNTIME-TASK-CANCELLED` cases and the `Task.map` form of the hand-off case.
  17b keeps the deterministic C test of the hand-off, and its socket case goes
  in its own file, `tests/test_vm_channel.py`. `Channel.new(capacity)`,
  `send(value, timeout_ms) -> Result[Void]`, `recv(timeout_ms) -> Result[T]`,
  `close`, `closed?` (closed, buffer empty, no reservation outstanding); bounded
  only (capacity 1 to 1,048,576), FIFO, required timeouts (0 means do not wait),
  waiters served in order with a reserved hand-off, no lost values under
  cancellation, and `close` revokes the slot reservations of senders that have
  not run yet; a `recv` on a closed channel waits while a reservation is
  outstanding. The producer closes on every path (`result = send_all(jobs)`,
  `jobs.close`, `return result`), since a receive loop whose producer never
  closes polls forever. New codes: `CHECK-EXPECTED-TYPE` for `Channel.new`
  without an expected type, and `RUNTIME-TASK-AWAIT-CYCLE`: `Task.await` follows
  the target's await chain and halts on a cycle, which channels make possible
  (§27.1, "Await cycles"). Breaking change: `Channel` becomes a reserved name
  (`CHECK-REDEFINED-NAME`). VM: `vm/channel.c` (ring buffer, wait FIFOs with
  reservations, park with retry on a timer-only job, as the handle lock does);
  cancelled waiters hand their reservation on; appended builtins, no format
  bump. Hints for `Enumerator.new`, `Fiber.new`, `xs.lazy`, `Agent`, `Mutex.new`
  and `SizedQueue.new` (§27.5). Tests: the checker tests, golden fixtures and C
  tests of §27.2, including the await-cycle fixtures, a crash-based
  `RUNTIME-TASK-CANCELLED` fixture (a crashed task's child, whose handle reached
  `main` over a channel), the channel-waiter case in
  `vm/tests/task_cancel_test.c`, the deterministic C test of the hand-off (a
  woken receiver is cancelled and the next one is still served), the C tests of
  the two late-reservation races with `close`, and, in
  `tests/test_vm_channel.py`, a socket handed to a worker against a Python TCP
  counterpart on port 0. Docs: `grammar.md` (channels, reserved names, §7
  hints), `references/tasks.md` (the canonical receive loop, pipeline, fan-in (a
  coordinator awaits all sources, then closes) and owner-task patterns, and the
  close-on-every-path rule) and `references/diagnostics.md`
  (`CHECK-EXPECTED-TYPE`, `RUNTIME-TASK-AWAIT-CYCLE`, `RUNTIME-TASK-CANCELLED`,
  which 17b makes reachable: its "no program can reach it yet" text in
  `diagnostics.md` and `tasks.md` changes here), the site's task pages (or a new
  `site/content/library/concurrency/channel.md`), `docs/vm/10-io-scheduler.md`
  §10.2.1 (stall check, await-cycle check) and §10.2.2,
  `docs/vm/10-io-multicore.md` §10.2.3; `docs/future/08-concurrency.md` then
  keeps only its open questions. Done: `vm/channel.c`, the checker and catalog
  rules, `CHECK-EXPECTED-TYPE` and `RUNTIME-TASK-AWAIT-CYCLE`, the hints, nine
  golden fixtures, `vm/tests/channel_test.c` and the channel case of
  `task_cancel_test.c`, `tests/test_vm_channel.py`, and
  `site/content/library/concurrency/channel.md`. A value that goes back to a
  full ring may make it hold more than its capacity until receivers take values;
  a waiter whose timer fired still takes a value that reached the ring before it
  re-ran.
- [x] 17c `Task.await(task, timeout_ms) -> Await[T]` (§27.3), decided by the
  owner on 2026-10-14 (it replaced the prelude plan of 2026-10-12: prelude code
  in `stdlib/prelude/task.agc` with a helper task, a capacity-1 channel and the
  prelude-only builtins `__task_settled?` and `__task_wait`, returning
  `Result[T]`). A C builtin in `vm/task.c` and a new builtin generic enum,
  `Await[T]`, with `Await.Done(value)` and `Await.TimedOut`, matched with `case`
  and checked for exhaustiveness like a user enum. A timeout does not cancel the
  target and does not halt the caller; the target keeps running and a later
  await (with or without a timeout) returns its cached outcome; a settled task
  never times out (checked before the wait and again when the timer fires);
  `timeout_ms` must be positive (`RUNTIME-INVALID-DURATION` at the argument); a
  crashed or cancelled target behaves as in the plain await
  (`Await.Done(error(...))` for a `Result` task, `RUNTIME-TASK-CRASHED` and
  `RUNTIME-TASK-CANCELLED` otherwise), and the timed form takes no part in the
  await-cycle check (a task that timed-awaits its own handle gets
  `Await.TimedOut`; a plain await skips a task that waits with a timeout).
  `Task[Void]` gives `Await[Void]`, matched as `Await.Done(_)`, as
  `Result.Ok(_)` is. `Await` is a reserved name (`CHECK-REDEFINED-NAME`), which
  is a breaking change; `try` does not apply to it. Reuse of the user-enum
  machinery, with no special case per site: `builtin-enums` in
  `src/builtin-types.rkt` seeds the checker's enum table and its reserved names,
  the module linker keeps the name unmangled, and lowering appends the enum to
  the program's enum table when the program uses it, as it does for the builtin
  structs; no new opcode. VM: the wait parks with retry on the target's waiter
  list and starts a timer job (`agc_wait_io`), the first wake wins and the
  winner cleans up the other side; a cancelled caller leaves through
  `unlink_task`; the entries `Task.await` and `Task.await_result` gain a second
  arity, and `agc_builtin_variant` finds the `Await` variants by name. Appended
  entries, no format bump. Done: the checker rule and catalog row, `vm/task.c`,
  `vm/builtins.c`, `vm/text.c` (prints `Await.Done()` for a `Void` payload),
  seven golden fixtures (`await-timeout`, `-void`, `-crash`, `-late-crash`,
  `-invalid`, `-cancelled`, `-cycle`), the rows in `tests/checker-test.rkt`,
  `tests/modules-test.rkt`, `tests/parser-test.rkt` and
  `tests/bytecode-test.rkt`, and the two timed-await cases of
  `vm/tests/task_cancel_test.c`. Docs: `grammar.md` (builtins, reserved names,
  "Lightweight tasks"), `references/tasks.md` and `references/diagnostics.md`,
  `site/content/library/concurrency/task.md` and `tour/tasks.md`,
  `docs/vm/10-io-scheduler.md` §10.2.1, the development skill's notes. No
  timing-dependent test was needed: the goldens decide each outcome by program
  order (a target that waits on a channel nobody has sent to, or a 10-second
  timeout), not by the clock.
- [x] 17d `File.each_line(path, buffer_bytes, timeout_ms) do |line| ... end`
  (§27.4, step 1), order row 7.2.1h, decided by the owner on 2026-10-14. A C
  builtin with no new type: it reads the file in blocks of at most
  `buffer_bytes` (1,024 to 16,777,216; otherwise `RUNTIME-INVALID-COUNT` at the
  argument) and calls the block once per line, in order; a line whose line end
  is longer than the buffer ends the call with
  `error("filesystem: line exceeds buffer_bytes")`; LF or CRLF is removed, a
  last line without a newline is passed, and the text is strict UTF-8.
  `timeout_ms` bounds each read, the open and the close, not the whole call; 0
  or less is the `error` result that file calls give today (`vm/files.c`,
  `bad_timeout`), not a diagnostic. The block returns `Result[Void]`: `error`
  stops the call and is returned; `try` works in the block, as in a `Test.test`
  block, since its type is a fixed `Result[Void]`; this item adds only the
  completion-value check (a Void or non-Result last expression is
  `CHECK-TYPE-MISMATCH` with a help that shows `ok()`), and the inferred-`T`
  case of §25.9 comes with the first of 17a and 15i. The file is closed on every
  return path. Reads follow §14.1 (a pool job for a regular file, the loop for a
  FIFO, pipe or device that can wait), and the call is a resumable builtin
  (`docs/vm/03-ir-and-bytecode.md` §4.3). Effects: `filesystem`. VM only, no
  format bump. Tests: golden fixtures (a small file; no final newline; CRLF; an
  empty file; a block that stops early with `error`; a block with `try`; the
  capacity errors at the argument span); a Racket test on a 10 MB file of short
  lines with `buffer_bytes` 4096 (the line count, and about size over buffer
  reads); a line longer than the buffer; invalid UTF-8; a FIFO fed by a Python
  stdlib peer; the file closed after an early stop and after a timeout. Docs:
  `grammar.md` (builtins and files), `references/files.md`,
  `site/content/library/io-and-system/files.md` with a runnable example,
  `docs/vm/03-ir-and-bytecode.md` §4.3 and `docs/vm/10-io-scheduler.md` §10.2.1
  and §10.2.2. Done: `File.each_line` in `vm/files.c` as a new kind of resumable
  builtin, the stepper (`agc_task_stepper`, `AGC_NATIVE_STEPPER` in
  `vm/interp.c`, `agc_step` in `vm/port.h`): the builtin checks its arguments
  and installs a step function, and the interpreter asks it for the next action
  (call the block, park for a read or the close, or end), so the core still
  calls no service. One `OP_READ_BLOCK` job reads at most `buffer_bytes` bytes
  into a buffer made once (`buffer_bytes + 1` bytes, so a last line of exactly
  `buffer_bytes` bytes without a terminator fits); every complete line in it
  goes to the block before the next read. The buffer range is checked first,
  then the timeout, then the path. Each block call costs one step plus the turn
  cost of its bytes, so `--max-steps` ends a long file. `try` in the block
  worked before this item, through the known `Result[Void]` of the block type;
  the checker change is only that the last expression of such a block is checked
  as a completion value, so a Void or non-Result last expression is
  `CHECK-TYPE-MISMATCH` with the help
  `give a Result with ok() or error("message")` (a `Test.test` block with a Void
  last expression changes from `CHECK-VOID-VALUE` to this, and the help shows
  for any mismatch with an expected `Result`, such as `x: Result[Int] = 5`).
  Four golden fixtures (`file-each-line`, `-stop`, `-limits`, `-crash`),
  `vm/tests/each_line_test.c`, a checker test, `tests/test_vm_file_lines.py`
  with `tests/fixtures/lines-peer.py`, and the files page of the site. The
  inferred-`T` form of `try` in a block is not built: no builtin needs it yet,
  so 17a (`Task.map`) or 15i (`File.open` block) adds it with its first test. A
  task that is cancelled without a crash while it waits in `File.each_line` (a
  `Test.run` leftover, a later `Task.map` timeout) leaves the file open until
  the end of the run, as a `File.open` handle does, until 24b; a crash of the
  task or of an ancestor closes it.
- [ ] 17e `Stream[T]` (§27.4, step 2), order step 8.2, after 15f (the prelude)
  and 17d. A builtin opaque generic and an immutable recipe: sources
  `Stream.lines(path, buffer_bytes, timeout_ms)` (the block buffer of 17d) and
  `Stream.iterate(seed, f)`; lazy `map`, `filter`, `take(n)` and `take_while`;
  terminals `to_list(max)`, `each` and `reduce`, which return a `Result`. Steps
  are methods (`s.filter(f)`), and `|>` only takes the path into `Stream.lines`;
  `s |> Stream.filter(f)` is `CHECK-PIPE-METHOD` (§25.14). A file source closes
  on every terminal path, as `File.open` with a block does. Written in the
  prelude (§25.6), so it waits for faster lists (8d). The checker and VM rules
  are added to §27.4 before the code lands. Tests: checker tests for the
  methods, the pipe rule and the terminals' types; golden fixtures without
  timing (a pipeline over a small file, an early `take`, a `try` failure,
  `to_list` over its limit, the step count). Docs: `grammar.md` (builtins),
  `references/files.md` and `references/builtins.md`, a new
  `site/content/library/data-structures/stream.md` with a runnable example, the
  development skill's notes (the prelude's `Stream` bodies).
- Not in this phase: a public `Task.cancel` (open in §8), `select` over several
  channels (§27.2, "Left out"), and other prelude helpers such as "the first of
  several tasks" or "all settled" (each needs its own spec, §27). CPU speed-ups
  from `Task.map` come only with the multicore schedulers (7h item, gated at
  order step 11); a CPU-bound `Task.map` program joins round 2 of the benchmarks
  (phase 12) as evidence for that decision.

**Done when:** the site examples of all three items run on the VM; the
`http.server` test shows `Task.map` running 8 delayed requests in about the time
of one, and a timed-out HTTP item leaves no open socket; a timed-out item leaves
no task running and closes no shared handle; a producer, workers and collector
pipeline runs with fixed output; an await cycle halts with
`RUNTIME-TASK-AWAIT-CYCLE`; a timed `Task.await` returns `Await.TimedOut` and
the task's result is still there for the next await; and an evaluation round
shows agents pick `Task.map` for list fan-out and channels for pipelines, with
the hints of §27.5 leading them away from generators, `Agent` and locks.
