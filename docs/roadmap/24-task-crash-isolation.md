## Phase 24: Task crash isolation

Specified in [`docs/future/37-task-crash-isolation.md` section 37](../future/37-task-crash-isolation.md#37-task-crash-isolation). Phase 24 is VM work with a small language change: a runtime error in a task other than `main` ends only that task. It comes after 7i and needs HTTP 20b (the task cancellation core), so it comes right after 20b, before unit tests (phase 25) and HTTP 20c (order step 7.1, decided by the owner on 2026-10-13). It is VM-only, like every feature after 7i. It has one PR, with its own tests and docs. The semantics are a proposal for the owner to review.

- [ ] **24a: crashes end only their task (§37.3 to §37.8).**
  - **VM:**
    - `agc_vm_run` (`vm/task.c`) sets the failure target once per turn; a fatal outcome (a crash in `main`, `RUNTIME-STEP-LIMIT`, `RUNTIME-INTERNAL`, an exit) ends the run as today, anything else crashes the current task;
    - the crash: store the diagnostic on the task, print it on stderr (` in a task`; `"task": true` with `--json`), cancel its running descendants (20b's `agc_task_cancel`), close the handles it and its cancelled descendants own, pass on a lock, a `next_owner` turn or a reserved pool slot, wake its awaiters;
    - the resource registry records each handle's owner task;
    - `Task.await` of a crashed task: `error(text)` when `R` is a `Result`, else `RUNTIME-TASK-CRASHED` at the await span; the crash is then observed;
    - `Task.crashed_count()`, a new builtin; a run whose `main` returns with an unobserved crash exits 1;
    - the audit of every `agc_fail`, `agc_fail_text` and `on_limit` site in `vm/`, so no failure leaves runtime state half-done, and a fuzzer mode that runs the mutant's body in a task.
  - **Front end:** the `Task.crashed_count` catalog entry.
  - **`std/bdd`:** check `Task.crashed_count()` after each handler (`RUNTIME-TASK-CRASHED`); the runner skips stderr lines with `"task": true` when it reads a child's last diagnostic.
  - **Tests:** the golden fixtures of §37.11; the C cases in `vm/tests/task_cancel_test.c` (lock, `next_owner`, pool slot, subtree cleanup); the latency case in `tests/vm-latency-test.rkt`; a BDD case where a task crashes unawaited in a step; `make bench` within noise.
  - **Docs:**
    - `docs/grammar.md` (Lightweight tasks; the new code);
    - the programming skill (`references/tasks.md`, `references/diagnostics.md`, `references/bdd.md`);
    - `site/content/library/task.md`;
    - `docs/vm/10-io-scheduler.md` §10.2.1 ("As built", "Cancellation");
    - `docs/future/27-iteration-and-concurrency.md` §27.1 and `docs/future/25-ruby-typed-idioms.md` §25.9 (§37.7);
    - the development skill (`references/vm.md`).
  - No CHANGELOG: the project adds none in the private alpha.

**Done when:** a task that divides by zero gives its awaiter `error("task crashed: ...")` while `main` goes on, an unawaited crash prints its diagnostic and makes the run exit 1, and the fixtures and the latency case pass.
