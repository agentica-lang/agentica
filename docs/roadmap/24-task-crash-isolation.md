## Phase 24: Task crash isolation

Specified in [`docs/future/37-task-crash-isolation.md` section
37](../future/37-task-crash-isolation.md#37-task-crash-isolation). Phase 24 is
VM work with a small language change: a runtime error in a task other than
`main` ends only that task. Its place in the order is row 7.1 of the
[roadmap](README.md). It has one PR, with its own tests and docs. The semantics
are a proposal for the owner to review.

- [x] **24a: crashes end only their task (§37.3 to §37.8).**
  - **VM:**
    - `agc_vm_run` (`vm/task.c`) sets the failure target once per turn; a fatal
      outcome (a crash in `main`, `RUNTIME-STEP-LIMIT`, `RUNTIME-INTERNAL`, an
      exit) ends the run as today, anything else crashes the current task;
    - the crash, in the order of §37.8: finish the turn, store and print the
      diagnostic (text, `--ai`, `--json` with `"task": true`), cancel the
      descendants (20b's `agc_task_cancel`), close the owned handles and
      channels by kind, pass on a `next_owner` turn, wake the awaiters;
    - owners on user-visible handles only (file, socket, listener, process,
      server; not the process guard or job resources); a handle passed directly
      as the `Task.spawn` argument moves to the new task (nested ones and
      channels do not; replaced in 24b by `Task.spawn_owning`); `HttpClient`
      exempt;
    - the close per kind (§37.5): mark closing and wake every lock waiter with
      the closed error; files by an `OP_CLOSE` pool job, pending while a job
      holds them (run by `agc_io_finish`, or where 20b releases a detached
      holder); sockets, listeners and TLS by `disown`; processes by
      `close_child`, never `release_proc`; servers by `close_server`;
    - the two `Task.await` entries; the `Result` entry gives
      `error("task: cancelled")` for any cancelled task; a crashed task counts
      as done for `Task.pending_count`;
    - `Task.unobserved_crash()`; a run whose `main` returns with an unobserved
      crash exits 1 with one summary line;
    - the audit of every `agc_fail` and `agc_fail_text` site in `vm/` (state
      left half-done, `malloc`'d temporaries live across the jump), and a fuzzer
      mode that runs the mutant's body in a task.
  - **Front end:** `src/lower.rkt` picks the `Task.await` entry from the
    checker's type of `R` (17a's `Task.map` items always use the `Result`
    entry); the `Task.unobserved_crash` catalog entry.
  - **`std/bdd`:** after each handler, check `Task.pending_count()` first, then
    `Task.unobserved_crash()`, and fail the step with `RUNTIME-TASK-CRASHED` and
    its text; the runner skips stderr lines with `"task": true` when it reads a
    child's last diagnostic.
  - **Migrate existing tests** (a crash in a task no longer ends the run):
    - `tests/fixtures/vm/task-preempt-fail.agc`: `main` loops forever after
      spawning a task that crashes, so it would never end. Bound the loop, then
      await the task: the run ends with `RUNTIME-TASK-CRASHED` at the await
      (exit 1), and the crash still shows the task ran while `main` looped.
    - `task-fail-unawaited.agc`: `main` now wakes after its sleep and prints
      `never`. Shorten the sleep to 10 ms and rename the line; the run exits 1
      with the crash line and the summary line on stderr.
    - `task-fail.agc` and `task-sleep-negative.agc`: their task's `R` is `Int`
      or `Void`, so `main` halts with `RUNTIME-TASK-CRASHED` at its
      `Task.await`, with the original code in the message and the crash line on
      stderr.
    - `tests/bdd-test.rkt:113` and `:122`: the "a task crashes" step spawns a
      crash and sleeps 60 s, which now meets the scenario deadline. Replace
      `Task.sleep(60000)` with `Task.sleep(0)`, which yields so the crash task
      runs; the step fails when its handler returns, and line 122 expects
      `RUNTIME-TASK-CRASHED` with `RUNTIME-DIVISION-BY-ZERO` in the message.
    - `make goldens` for the expected files of the fixtures above. Crash lines
      on stderr carry the fixture's absolute path, so the golden harness
      replaces the fixture directory with a fixed token before it compares
      stderr.
  - **New tests:** §37.11.
  - **Docs:**
    - `docs/grammar.md` (Lightweight tasks; the new code);
    - the programming skill (`references/tasks.md`, `references/diagnostics.md`,
      `references/bdd.md`);
    - `site/content/library/concurrency/task.md`;
    - `docs/vm/10-io-scheduler.md` §10.2.1 ("As built", "Cancellation");
    - the development skill (`references/vm.md`).
  - CHANGELOG: an entry under `[Unreleased]` for any user-visible change.
  - **Done.** As built:
    - `agc_vm_run` runs each turn under its own `setjmp` (`vm->turn`, used while
      `vm->in_turn`); a crash in a task other than `main` goes through `crash`
      in `vm/task.c`, in the order of §37.8. The second await entry is
      `Task.await_result`, picked by `src/lower.rkt` when the checker's type of
      the call is a `Result`.
    - Owners: `agc_own` records the task that made a file (`vm/files.c`), a
      socket or listener (`own` in `vm/tcp.c`) or a process (`vm/process.c`) and
      its close: an `OP_CLOSE` job with no task (`agc_io_detached`), pending
      while a job holds the file (`close_pending` in `vm/loop.c` runs it after
      that job's `done` or `expired`, also for a detached job); `disown`;
      `close_child`. A closing handle wakes its lock waiters, and
      `agc_handle_wait` lets them through to the closed error. Servers have no
      close yet: `close_server` comes with 20c.
    - The audit found no failure that leaves runtime state half-done: every
      failure that is not fatal (`RUNTIME-STEP-LIMIT` and `RUNTIME-INTERNAL` end
      the run) comes before the builtin changes runtime state, or after a
      finished change (`RUNTIME-PROCESS-CLOSE` after `Process.close` has closed
      the child). The `malloc`'d temporaries live across a failure only before
      `RUNTIME-INTERNAL`, which ends the run.
    - **Dropped by the owner:** the fuzzer mode that runs the mutant's body in a
      task (no new fuzzers).
    - Tests are the migrated ones above, `task-crash-result.agc` (the `Result`
      entry, `Task.unobserved_crash`, the three stderr formats),
      `task-crash-descendants.agc`, `tcp-crash-echo.agc` (the `tcp_echo` case:
      the client of the crashed connection reads
      `error("network: end of input")`, the listener and the next connection
      work), the BDD step and a crash before `BDD.run` (a file error), a
      lowering test of the two await entries, and a `tests/filesystem-test.rkt`
      case that checks a crashed task's buffered write is on disk after the run;
      `tests/process-test.rkt` ("every way a run ends") now awaits its crashing
      task and expects `RUNTIME-TASK-CRASHED`; `vm/tests/task_cancel_test.c` now
      expects a task that awaits a cancelled task to crash. These cases of
      §37.11 were left out by the owner's rule (only the tests that prove "Done
      when"): the separate stderr lines in `--ai` and plain beyond the harness
      check, a non-`Result` await from another task (that task crashes in turn),
      two awaits of one crashed task (one parked before the crash), the
      unobserved crash with `System.exit(0)`, `Task.unobserved_crash` before any
      crash, a crash in `main`, `RUNTIME-STEP-LIMIT` and `System.exit(3)` in a
      task, `RUNTIME-STACK-OVERFLOW` in a task, awaiting a cancelled descendant
      (no program can reach one yet), the handle cases other than the socket (a
      file another task holds, a struct-nested socket, a file captured by a
      block, a spawned process, an `HttpClient` used by another task), the C
      tests (the `next_owner` hand-on, the pending file close with an attached
      and a detached holder, the subtree cleanup) and the latency case with
      10,000 descendants and 1,000 files.
    - **Cost (departs from §37.8):** the cancel of the descendants and the
      closes are not charged to any turn. `agc_task_cancel` charges the task
      that calls it, here the crashed task, whose turn has already ended; the
      descendants were paid for when they were spawned.
    - One rule for every file at the end of the run (owner decision, in the
      style of Erlang's `halt` flush timeout): the end of the run
      (`agc_io_flush_files`, called by `end_run` in `vm/main.c`, §10.2.2 "End of
      run") closes each file still open with the same `OP_CLOSE` job as a
      crashed task's file (`close_files` in `vm/loop.c`), then waits for all
      file close jobs (`finish_flushes`, `uv_run` ONCE, no busy wait). The wait
      was first planned with no limit by default; the owner replaced this on
      2026-10-13, and as built the limit is always on, 30 seconds by default
      (row 7.2.1d of the roadmap); `agentica --flush-timeout MS` or
      `AGENTICA_FLUSH_TIMEOUT_MS` sets it, and when time runs out the run still
      ends with the same exit code and prints one stderr line,
      `agentica: file data may not be written: the flush took longer than MS ms`
      (`--json`:
      `{"flush_timeout_ms":MS,"warning":"file data may not be written"}`). A
      file whose own operation is still in the pool when the run ends gets no
      close job and is not waited for, as before. `File.close` from another task
      on a file whose close is pending returns `ok()` at once, as for any closed
      handle: the flush belongs to the owner's close, and the run waits for it.
    - A task that returns normally gives the handles it still owns to its parent
      (`agc_give_owned`), so a handle moved to a helper task by `Task.spawn` is
      closed if the parent crashes after the helper returned
      (`tcp-crash-delegate.agc`). (The spawn move and this give-back were
      replaced in 24b.) A timed-out file operation that took the file's state
      writes the buffer when its job is dropped (`drop` in `vm/files.c`); the
      write buffer is always empty there today, since a write moves it into the
      request before the job starts, so this is a guard. Tests: a
      `tests/filesystem-test.rkt` case for a bad `--flush-timeout` (exit 2) and
      one where the flush to a FIFO nobody reads times out.

**Done when:** a task that divides by zero gives its awaiter
`error("task crashed: ...")` while `main` goes on, an unawaited crash prints its
diagnostic and makes the run exit 1, a crash in `examples/tcp_echo.agc`'s `echo`
closes only its socket (through the explicit hand-off of 24b,
`Task.spawn_owning`; 24a did it with a spawn move), and the fixtures and the
existing latency test (`make vm-latency`) pass. The latency case of §37.11 was
dropped (see "Done").

- [x] **24b: one handle-ownership rule
  ([§14.5](../vm/14-core-invariants.md#145-handles)).** A handle belongs to the
  task that opened it; if that task ends, in any way (return, crash, cancel),
  without closing it, the handle is closed; handing it to another task is always
  explicit, through one form. It replaces three mechanisms: 24a's spawn move (a
  handle passed directly as the `Task.spawn` argument moves to the new task,
  `builtin_spawn` in `vm/task.c`), 24a's give-back (a task that ends normally
  gives its handles to its parent, `agc_give_owned` in `vm/loop.c`), and 20c's
  group registration (`HttpWire.spawn` registers each connection's socket with
  the server's group, which closes it when the connection task ends or at
  `close_server`, [§10.7.2](../vm/10-io-http.md)). The group registration
  becomes one use of the explicit hand-off: `HttpWire.spawn` hands the socket
  over with it. Its place in the order is row 7.2.1a of the
  [roadmap](README.md), after HTTP 20c, the VM layers (row 7.2.1b,
  [§15](../vm/15-layers.md#15-vm-layers), so the hand-off is a port function)
  and rows 7.2.1d to 7.2.1f, so the server's hand-off is known when the one form
  is chosen. Its close must also cover a task parked in a stepper
  (`File.each_line`, row 7.2.1h, [§4.3](../vm/03-ir-and-bytecode.md)): the
  handle is owned through `agc_own` like any other, so a cancel without a crash
  closes it, and the cancelled-reader case of `vm/tests/each_line_test.c`, which
  now expects the descriptor to stay open until `agc_io_close`, expects it
  closed at once. One PR. Decided by the owner on 2026-10-13: ownership decides
  who closes a handle, not who may use it, so shared use stays as
  [§37.5](../future/37-task-crash-isolation.md#375-handles-of-a-task-that-ends)
  "Shared handles" says, and `HttpClient` stays exempt.
  - **Spec first:** the one explicit hand-off form (for example a builtin that
    gives a handle the caller owns to a task it spawned) in §37.5, and
    `HttpWire.spawn` in `docs/vm/10-io-http.md` §10.7.2 described as a use of
    it. Behavior changes: a handle opened in a helper task and returned through
    `Task.await` is closed when the helper ends unless it is handed over; a
    cancelled task's handles are closed (today they stay open until the end of
    the run, `end_cancelled` in `vm/task.c`), which reaches `Test.run`'s
    leftovers and cancelled handlers, and an `HttpServer` whose owner is
    cancelled (today it keeps its port bound until the run ends; 20c's
    `close_server` already closes its own group's handles through
    `agc_task_drop`); and a server loop that passes a connection to `Task.spawn`
    must hand it over, or a crash in the connection task leaves its client
    waiting.
  - **VM:** one close path for every task end (return, crash, cancel) through
    `agc_close_owned`; `agc_give_owned` and the spawn move are removed;
    `HttpWire.spawn` uses the explicit hand-off.
  - **Programs:** `examples/tcp_echo.agc` (its `Task.spawn(&echo, connection)`)
    switches to the explicit form; so does `std/http`'s server through
    `HttpWire.spawn`.
  - **Docs:** §37.5, `docs/vm/10-io-http.md` §10.7.2, §10.2.1 "Owners",
    [§14.5](../vm/14-core-invariants.md#145-handles) (the target becomes as
    built), `docs/grammar.md`, the programming skill (`references/tasks.md`,
    `references/network.md`), the site page of `Task`, the development skill.
  - **Tests:** goldens for a handle left open by a task that returns (closed),
    one handed over explicitly (still open), a cancelled task's handle (closed),
    and the server's per-request connection (the existing `http-server-crash`
    and `http-server-close` fixtures cover it); `tcp-crash-echo.agc` and
    `tcp-crash-delegate.agc`, which rely on the spawn move and `agc_give_owned`,
    switch to the explicit form.
  - **Done.** As built (spec in
    [§37.5](../future/37-task-crash-isolation.md#375-handles-of-a-task-that-ends)):
    - The one hand-off is the builtin `Task.spawn_owning(&f, handle)`
      (`Task.spawn` plus the hand-off of a handle the caller owns, in one call).
      The checker accepts only a handle type as its argument (`FileHandle`,
      `Socket`, `Listener`, `Process`, `HttpServer`; `handle-types` in
      `src/builtin-types.rkt`); any other type is `CHECK-NOT-A-HANDLE` at the
      argument, with a help that names `Task.spawn`. At run time a handle that
      the caller does not own, one already handed over, and a closed one are
      `RUNTIME-HANDLE-NOT-OWNED` at the handle argument, a crash of the caller,
      before any task is made. `src/builtins.rkt` has one entry (rule
      `task-spawn-owning`, shared with `task-spawn` in `src/checker.rkt`),
      `src/lower.rkt` lists the key in `vm-builtins`, and the VM table entry is
      in `vm/task.c`.
    - One port function, `agc_task_spawn_owning` (`vm/task.c`, declared in
      `vm/port.h`), checks the owner, spawns, seeds the random generator and
      hands the handle over; `Task.spawn_owning` and `HttpWire.spawn` both call
      it. `HttpWire.spawn` no longer registers or closes the socket: its end
      hook only frees the slot.
    - Each task keeps the list of the handles it owns (`owned` in the task,
      `owned_prev` and `owned_next` in the resource), so one task's end costs
      its handles, not the size of the registry. `finish_task` calls
      `agc_close_owned(vm, t)` first for every end (return, crash, cancel).
      `agc_give_owned`, the spawn move, `drop_handles`, `mark_subtree` and
      `agc_task_drop` are gone; `close_server` cancels its group with
      `agc_task_cancel`, and each cancelled task closes what it owns.
    - Behavior changes: a handle opened in a helper task and returned through
      `Task.await` is closed when the helper ends; a cancelled task's handles
      are closed (`Test.run` leftovers, cancelled handlers, a `File.each_line`
      reader, an `HttpServer` whose owner is cancelled, which frees its port); a
      server loop that passes a connection with plain `Task.spawn` keeps it in
      the loop task.
    - Await and close (review of the PR): a regular file's owner-end close is
      async, so the ending task counts its pool close jobs (not a polled FIFO or
      pipe flush, which would hold an await for as long as the reader is idle;
      `closing` in the task, `ender` in the resource, set by `close_file`
      through the new `ender` argument of `agc_close_fn`), and `agc_task_join`
      keeps parking awaiters, also later ones, until each job's `closed` has
      called `agc_task_close_done`. The close job holds the handle
      (`agc_io_detached` takes the handle as its context), `agc_handle_wait`
      lets a closing handle through only when no job holds it, and `File.close`
      on such a handle waits for the lock and returns the close result (stored
      in the handle's `context`). `HttpWire.server` takes the listener off its
      owner's list (`agc_disown`), so a server handed over with
      `Task.spawn_owning` keeps its port and ending the server's owner closes
      both. `finish_task` computes `left_children` before it closes the handles,
      so a `Test.run` test that returns with a server listening still fails with
      `RUNTIME-TEST-PENDING-TASKS`. A close that waits behind any job that holds
      the file, such as another task's FIFO or pipe read, keeps the descriptor
      open until that job ends or times out, and awaiters do not wait for it
      (documented, not changed). `agc_task_spawn_seeded` is the one place that
      seeds a child's random generator.
    - Tests: the goldens `handle-task-return`, `handle-spawn-owning` (also the
      three `RUNTIME-HANDLE-NOT-OWNED` cases), `handle-cancel-closes`,
      `http-server-owner-cancel`, `handle-close-flushed` (200 awaits of a helper
      that wrote and returned a file, a crash, and a close from another task
      during the close job), a `tests/filesystem-test.rkt` case where an await
      returns while the flush to a FIFO is stuck, `http-server-spawn-owning` and
      `test-leftover-server`; `tcp-crash-echo`, `tcp-crash-delegate`,
      `process-close-crash`, `process-close-cancel` and
      `http-server-owner-crash` use the explicit form (the last two and the
      first would otherwise lose the move); the cancelled-reader case of
      `vm/tests/each_line_test.c` expects the descriptor closed at once; a
      checker case for `CHECK-NOT-A-HANDLE` (the argument span, and `Listener`
      and `HttpServer` accepted); a `Listener` hand-off in
      `handle-spawn-owning`; `vm/tests/task_cancel_test.c` cases where a parked
      task is cancelled without a crash and closes its handle, and where an
      awaiter of a task with a close in flight is cancelled before the close
      finishes, then a late await waits for it; a Node peer case in
      `tests/vm-tcp-test.rkt` (a crashed task's and a returned task's
      connections close); `tests/vm-tcp-test.rkt` and `tests/vm-tls-test.rkt`
      servers use `Task.spawn_owning`, and the TLS limits and exit programs keep
      their handles in the task that uses them.

- [x] **24c: a channel can have an owner
  ([§37.5](../future/37-task-crash-isolation.md#375-handles-of-a-task-that-ends),
  [§14.5](../vm/14-core-invariants.md#145-handles)).** Decided by the owner on
  2026-10-14. `Task.spawn_owning(&f, ch)` makes the spawned task the owner of a
  `Channel`. When that task ends in any way (return, crash, cancel),
  `finish_task` closes the channel through the same `agc_close_owned` path as
  the other handles: parked senders wake with the closed error, and readers
  drain the values already sent, then get the closed error at once. A consumer
  no longer waits for a timeout when its producer died; HTTP streaming (20e to
  20g) and worker pools need it. A channel never handed over stays unowned and
  is closed only by `Channel.close`, which any task may still call on an owned
  channel. Plain `Task.spawn` moves nothing. Erlang monitors and links are not
  added, and several producers on one channel keep the coordinator pattern
  (§37.7).
  - **Done.**
    - The checker accepts `Channel[T]` as the handle argument of
      `Task.spawn_owning` (`src/checker.rkt`); any other non-handle type is
      still `CHECK-NOT-A-HANDLE`.
    - `vm/channel.c` has the shared close (`shut`) for `Channel.close` and for
      the owner's end, and `agc_channel_claim`, which registers the entry (no
      native object) the first time a channel is handed over;
      `agc_task_spawn_owning` in `vm/task.c` takes the resource of a channel
      from it. A channel owned by another task, or a closed one, is
      `RUNTIME-HANDLE-NOT-OWNED`; the first hand-off of an unowned channel is
      open to any task.
    - Tests: the goldens `channel-owner-ends` (return, crash, cancel, a parked
      reader, a parked sender) and `channel-owner-handoff` (plain `Task.spawn`
      does not close, a close from a non-owner, hand-on by the owner, and the
      `RUNTIME-HANDLE-NOT-OWNED` cases); a checker case for `Channel` accepted
      and a non-handle still `CHECK-NOT-A-HANDLE`.
