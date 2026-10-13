## Phase 24: Task crash isolation

Specified in [`docs/future/37-task-crash-isolation.md` section 37](../future/37-task-crash-isolation.md#37-task-crash-isolation). Phase 24 is VM work with a small language change: a runtime error in a task other than `main` ends only that task. Its place in the order is row 7.1 of the [roadmap](README.md). It has one PR, with its own tests and docs. The semantics are a proposal for the owner to review.

- [ ] **24a: crashes end only their task (§37.3 to §37.8).**
  - **VM:**
    - `agc_vm_run` (`vm/task.c`) sets the failure target once per turn; a fatal outcome (a crash in `main`, `RUNTIME-STEP-LIMIT`, `RUNTIME-INTERNAL`, an exit) ends the run as today, anything else crashes the current task;
    - the crash, in the order of §37.8: finish the turn, store and print the diagnostic (text, `--ai`, `--json` with `"task": true`), cancel the descendants (20b's `agc_task_cancel`), close the owned handles and channels by kind, pass on a `next_owner` turn, wake the awaiters;
    - owners on user-visible handles only (file, socket, listener, process, server; not the process guard or job resources); a handle passed directly as the `Task.spawn` argument moves to the new task (nested ones and channels do not); `HttpClient` exempt;
    - the close per kind (§37.5): mark closing and wake every lock waiter with the closed error; files by an `OP_CLOSE` pool job, pending while a job holds them (run by `agc_io_finish`, or where 20b releases a detached holder); sockets, listeners and TLS by `disown`; processes by `close_proc`, never `release_proc`; servers by `close_server`;
    - the two `Task.await` entries; the `Result` entry gives `error("task: cancelled")` for any cancelled task; a crashed task counts as done for `Task.pending_count`;
    - `Task.unobserved_crash()`; a run whose `main` returns with an unobserved crash exits 1 with one summary line;
    - the audit of every `agc_fail` and `agc_fail_text` site in `vm/` (state left half-done, `malloc`'d temporaries live across the jump), and a fuzzer mode that runs the mutant's body in a task.
  - **Front end:** `src/lower.rkt` picks the `Task.await` entry from the checker's type of `R` (17a's `Task.map` items always use the `Result` entry); the `Task.unobserved_crash` catalog entry.
  - **`std/bdd`:** after each handler, check `Task.pending_count()` first, then `Task.unobserved_crash()`, and fail the step with `RUNTIME-TASK-CRASHED` and its text; the runner skips stderr lines with `"task": true` when it reads a child's last diagnostic.
  - **Migrate existing tests** (a crash in a task no longer ends the run):
    - `tests/fixtures/vm/task-preempt-fail.agc`: `main` loops forever after spawning a task that crashes, so it would never end. Bound the loop, then await the task: the run ends with `RUNTIME-TASK-CRASHED` at the await (exit 1), and the crash still shows the task ran while `main` looped.
    - `task-fail-unawaited.agc`: `main` now wakes after its sleep and prints `never`. Shorten the sleep to 10 ms and rename the line; the run exits 1 with the crash line and the summary line on stderr.
    - `task-fail.agc` and `task-sleep-negative.agc`: their task's `R` is `Int` or `Void`, so `main` halts with `RUNTIME-TASK-CRASHED` at its `Task.await`, with the original code in the message and the crash line on stderr.
    - `tests/bdd-test.rkt:113` and `:122`: the "a task crashes" step spawns a crash and sleeps 60 s, which now meets the scenario deadline. Replace `Task.sleep(60000)` with `Task.sleep(0)`, which yields so the crash task runs; the step fails when its handler returns, and line 122 expects `RUNTIME-TASK-CRASHED` with `RUNTIME-DIVISION-BY-ZERO` in the message.
    - `make goldens` for the expected files of the fixtures above. Crash lines on stderr carry the fixture's absolute path, so the golden harness replaces the fixture directory with a fixed token before it compares stderr.
  - **New tests:** §37.11.
  - **Docs:**
    - `docs/grammar.md` (Lightweight tasks; the new code);
    - the programming skill (`references/tasks.md`, `references/diagnostics.md`, `references/bdd.md`);
    - `site/content/library/task.md`;
    - `docs/vm/10-io-scheduler.md` §10.2.1 ("As built", "Cancellation");
    - the development skill (`references/vm.md`).
  - No CHANGELOG: the project adds none in the private alpha.

**Done when:** a task that divides by zero gives its awaiter `error("task crashed: ...")` while `main` goes on, an unawaited crash prints its diagnostic and makes the run exit 1, a crash in `examples/tcp_echo.agc`'s `echo` closes only its socket, and the fixtures and the latency case pass.
