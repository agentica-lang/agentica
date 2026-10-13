## 37. Task crash isolation

**Status:** planned (roadmap [phase 24](../roadmap/24-task-crash-isolation.md)). The order was decided by the owner on 2026-10-13: after HTTP 20b (the task cancellation core, which this section needs) and before unit tests (§36), HTTP 20c and 20d, and 7i (§37.9). The semantics below are a proposal for the owner to review.

The idea in one paragraph, in the style of Erlang: a runtime error in a task other than `main` ends only that task. Its awaiters get an error `Result`, its descendants are cancelled, the handles it owns are closed, and the rest of the program goes on. A crash in `main` still ends the program, and a crash nobody handles still prints its diagnostic and makes the run fail at the end, so nothing fails silently. Links, monitors and supervisors are later work, written in Agentica on top of this (§37.10).

### 37.1 Today

Checked at `099daa3`:

- Any runtime diagnostic in any task ends the whole run. `agc_fail` (`vm/interp.c:18-27`) stores the outcome in the runtime and `longjmp`s to the one `setjmp` of the run, in `agc_vm_run` (`vm/task.c:134-170`). `System.exit` (`agc_exit`, `vm/interp.c:40-44`) takes the same path. `docs/vm/10-io-scheduler.md` §10.2.1 ("As built", "Cancellation") records it.
- `Task.await(task: Task[R]) -> R` returns the task's result; there is no error path (`builtin_await`, `vm/task.c:183-190`).
- The programming skill says "Any task diagnostic terminates the evaluation with its original code and span, even when unawaited" (`references/tasks.md`). §27.1 (`Task.map`) and §25.9 (`File.open` with a block) repeat it.
- A task records no parent and no children (`struct agc_task`, `vm/agc.h:333-350`). Handles belong to the scheduler's resource registry, not to a task; they all close at the end of the run (§10.2).
- HTTP 20b ([roadmap](../roadmap/20-hybrid-http.md), [§30.6](30-hybrid-http.md#306-server-tasks-close_server-and-task-cancellation)) plans the parent and children links and `agc_task_cancel`, with no public API.

### 37.2 Why this is safe in Agentica

- **Values are immutable.** A crashed task cannot leave a shared value half-updated: every value it built is either complete and visible, or never visible.
- **Mutable state lives only in handles:** files, sockets, processes, servers, the HTTP pool, and later channels (§27.2). So the only state a crash can leave behind is in a handle, and §37.5 gives a rule for each kind.
- **The runtime's own state is the risk.** Today a failure can leave C state half-done, because the run ends anyway. After this section it must not. Phase 24 audits every `agc_fail` site in `vm/` (§37.8).

### 37.3 What a crash is, and what still ends the program

A **crash** is a runtime diagnostic raised while a task other than `main` runs: `RUNTIME-DIVISION-BY-ZERO`, `RUNTIME-INDEX-OUT-OF-RANGE`, `RUNTIME-UNWRAP-ERROR`, `RUNTIME-STACK-OVERFLOW` (the depth limit is per task), `RUNTIME-TASK-CANCELLED` at an await, and the rest. It ends only that task.

These still end the whole program, as today:

- a crash in `main`;
- `--max-steps` exhaustion (`RUNTIME-STEP-LIMIT`): the budget is global (§10.2.1, "Quotas"), so no task can go on once it is spent;
- out of memory: the VM aborts (`docs/vm/05-values-execution-builtins.md`);
- internal VM errors (`RUNTIME-INTERNAL`), including a failed write to stdout or stderr and the stall check;
- `System.exit` in any task. It is not a crash: the program asked to end.

### 37.4 What the program sees

- **`Task.await` on a crashed task.** `Task.await` keeps its type, `Task[R] -> R`, so the rule depends on `R`:
  - When `R` is `Result[T]`, the await returns `error(text)`. One level, as in `Task.map` (§27.1): a crash and the task's own `error(...)` are both one `error`. A task that can fail should return a `Result`, and then its crash is a value the caller can handle.
  - Otherwise there is no value to return, so the awaiter halts with the new code **`RUNTIME-TASK-CRASHED`** at its own `Task.await` span. That is itself a crash of the awaiter, so it ends only the awaiter (or the program, when the awaiter is `main`). The crash moves up through awaits, like an Erlang link to the task that waits.
  - Every await, the parked ones and later ones, sees the same outcome.
- **The text** is the crash diagnostic on one line: `task crashed: CODE at FILE:LINE:COLUMN: MESSAGE`, for example `task crashed: RUNTIME-DIVISION-BY-ZERO at math.agc:2:13: division by zero`. The code, the start of the span and the message are all there; the format is stable and pinned by golden fixtures. `RUNTIME-TASK-CRASHED` uses the same text as its message.
- **Stderr.** Every crash prints its diagnostic on stderr when it happens, awaited or not: the VM cannot know whether an await will come later. The text form is the normal diagnostic with ` in a task` after the header (`math.agc:2:13 error[RUNTIME-DIVISION-BY-ZERO] in a task`). With `--json` it is the normal JSON object plus `"task": true`, so a reader that takes "the last stderr line" as the run's diagnostic (the BDD runner, §31.5) skips it.
- **Exit code.** A crash is **observed** when an await returns its `error` or halts with `RUNTIME-TASK-CRASHED`. When `main` returns and some crash was never observed, the run exits 1 instead of 0. So a fire-and-forget task that crashes still fails CI. `System.exit(n)` keeps `n`: the program chose it. A fatal outcome keeps its own code, as today.
- **`Task.crashed_count() -> Int`** (new builtin): the number of crashes of this run that no await has observed. It is runtime state, like `Task.pending_count` (§31.9), and serves the same users: `std/bdd` checks it after each step handler next to `Task.pending_count()`, and fails the step with `RUNTIME-TASK-CRASHED` when it grew, so a task that crashes in a step still fails that step, as today. Unit tests (§36) do the same in C.

```agentica
def parse(text: String) -> Result[Int]
  n = text.to_i!
  return ok(100 / n)
end

def main() -> Void
  task = Task.spawn(&parse, "0")
  case Task.await(task)
    ok(n) -> puts(n)
    error(e) -> puts("failed: #{e}")
  end
  puts("still running")
end
```

This prints `failed: task crashed: RUNTIME-DIVISION-BY-ZERO at parse.agc:3:17: division by zero`, then `still running`, and exits 0: the crash was observed. Its diagnostic is also on stderr.

### 37.5 Handles of a crashed task

A handle is **owned** by the task that opened it: `File.open`, `TCP.connect`, `TCP.listen`, `TLS.*`, `Process.spawn` and `spawn_captured`, `HTTP.client`, the `std/http` server. The resource registry records the owner when the handle is made. A handle passed to another task keeps its owner.

- **Owned handles are closed.** The VM closes each one as if its owner had called the close builtin at the moment of the crash: a file closes, a socket closes, a process is stopped and reaped as at the end of a run (`SIGKILL`, or `SIGTERM` first for a captured child, §31.9), a server is closed as by `close_server` (20c), and its handlers are cancelled. The close takes the handle's lock in turn, so an operation another task has in flight on it ends first; later calls by other tasks get the normal "closed" error `Result`. This is Erlang's rule for ports: a port closes when its owner dies. A program that wants a handle to outlive a task opens it in the long-lived task (the owner-task pattern of §27.5).
- **A handle lock passes on.** A crash happens while the task runs, so it holds no lock for an I/O job. But it may crash inside a builtin's retry while it is the `next_owner` of a lock, or while it holds one. Then ownership passes to the head waiter, which is woken, as at a release (§10.2.2), with 20b's code.
- **A reserved pool slot passes on.** A slot of an `HttpClient` pool reserved for the crashed task goes to the next waiter, or becomes free, as for a cancel (20b). A pooled connection the crashed task had checked out inside a builtin is closed, not put back, because its state is unknown.
- **Later channels (§27.2):** a reservation the task held passes to the next waiter. 17b adds that case; the rule is the same.

### 37.6 Children: a crash cancels the descendants

Today (after 20b) a task that ends moves its running children to its parent. Erlang would instead end the processes linked to the one that died. This section takes the Erlang side for crashes: **a crash cancels the crashed task's running descendants**, with 20b's `agc_task_cancel`, and only then closes its handles.

- A task's children are its work. A crashed task can no longer await them, use their results or stop them, so they would run on for nothing, still printing and spending the shared step budget.
- It is the rule §27.1 already uses for a `Task.map` item that times out, and 20c for `close_server`: a task that ends abnormally takes its descendants with it; a task that ends normally hands them to its parent. One rule for every abnormal end is easier to learn and to test.
- Moving them to the parent would hand the parent tasks it never started and may not know about, in the middle of a failure.
- A program that wants work to outlive a task that may crash starts that work from a task that does not crash (its parent, or a long-lived owner task).

The cancelled descendants follow 20b: their I/O jobs are detached, and tasks parked in `Task.await` on one of them halt with `RUNTIME-TASK-CANCELLED`, which is a crash of each such awaiter under this section. Handles owned by the cancelled descendants are closed too, each after its detached job ends, so the whole subtree leaves nothing open. (Whether a timeout or `close_server` should also close the handles of the tasks it cancels stays the open question of §8; the owner field of §37.5 would make it a small change.)

### 37.7 Effect on other sections

- **`Task.map` (§27.1).** A crash in an item ends only the item: its slot gets `error(text)` (the block returns a `Result`), its descendants are cancelled, and the other items go on. This replaces "a runtime diagnostic in an item ends the whole run". Phase 24 lands before 17a, so 17a builds on it.
- **`File.open` with a block (§25.9)** and every other sentence of `docs/future/` that says a diagnostic "ends the whole run" mean, after this section, "ends the task", which is the whole run only in `main`.
- **HTTP server (20c).** A handler runs inside its connection task, so a handler crash ends that connection: the socket is closed (it is owned by the connection task) and the client sees the connection close with no response; the server goes on. Answering 500 instead would need the handler in its own task; that is a later choice for `std/http`.
- **BDD (§31).** `std/bdd` checks `Task.crashed_count()` after each handler (§37.4). The runner ignores stderr lines with `"task": true` when it reads a child's last diagnostic. A crash in the handler itself (in `main`'s task in the scenario child) still ends the child, as today.
- **The evaluator** is frozen and keeps "any crash ends the run" for the programs it still runs (the builtin `HTTP` module until 20d). `Task.crashed_count` is VM-only: the driver refuses it on an evaluator path with `LOWER-UNSUPPORTED`, through `vm-only-builtins` (§31.9).

### 37.8 VM design

- **One `setjmp` per turn.** `agc_vm_run` sets the failure target before each turn, not once per run. When `agc_fail` jumps there, the scheduler reads the outcome: a fatal code (§37.3), an exit, or a failure in `main` ends the run as today; anything else crashes the current task. A `setjmp` costs a few nanoseconds against a turn of 2,000 steps; `make bench` checks it.
- **Crashing a task:** store the diagnostic (code, message, span) on the task and mark it done and crashed; print it on stderr (§37.4); cancel its running descendants with `agc_task_cancel`; close its owned handles (§37.5); pass on any lock or pool slot it holds; wake its awaiters, which re-run their `Task.await` and see the crash. The task's registers and frames are dropped, as for a task that returns.
- **The audit.** After this section, a failure no longer ends the run, so no builtin may fail while it leaves runtime state half-done: a lock taken but not recorded, a half-built registry entry, a task half-parked, a job without its owner. Phase 24 checks every `agc_fail` and `agc_fail_text` site in `vm/` (and the `on_limit` jump of `vm/value.c`) and moves each failure before the state change, or undoes the change first. The fuzzer (`make vm-fuzz`) gets a mode that spawns the mutant's `main` body in a task, so its crashes go down the new path.
- **Cost of the cleanup.** Cancelling descendants and closing handles is O(descendants + handles). It runs between turns and charges the turn cost of the scheduler's next turn, never `--max-steps`, as 20b's cancel does.
- **Multicore** (§10.2.3, if it lands): crash cleanup uses the same cancel flag and wake as 20b; nothing here depends on N=1.

### 37.9 Order

Decided by the owner on 2026-10-13: 7i (first item, the VM as the default backend, done) → 20b → §37 (phase 24) → §36 (phase 25) → 20c → 22 → 23, with 20d and the deletion of the evaluator after 20c, as before (roadmap order step 7.1).

- §37 needs 20b: the parent and children links and `agc_task_cancel`.
- Unit tests (§36) come right after, because they use it for isolation inside a test file.
- HTTP 20c does not depend on §37 or §36 and could go before them; the owner chose to put them first.
- §37 is VM-only and lands before the evaluator is deleted, like HTTP 20a to 20d: an exception to "new features come after 7i", listed in the roadmap rules.

### 37.10 Later, in Agentica on top of this

Not in this section. Each needs its own spec and must pass the one-way test of §25:

- **Links and monitors** in the Erlang sense: be told when another task crashes, without awaiting it. They need channels (§27.2) to carry the message.
- **Supervisors and restart strategies** (one for one, one for all), written in Agentica (a `std/` module or the prelude) over spawn, await, crash results and channels.
- **Handle transfer** (Erlang's `port_connect`): give a handle a new owner.

### 37.11 Tests

Golden fixtures in `tests/fixtures/vm/` for each case (no timing, so their step counts are fixed and the `--max-steps` sweep holds):

- a crash in a task whose `R` is a `Result`: the await gets `error(text)`, `main` goes on, exit 0; the stderr line;
- a crash in a task whose `R` is not a `Result`: the awaiter halts with `RUNTIME-TASK-CRASHED` at its own span; from `main`, the run ends with exit 1; from another task, that task crashes in turn;
- two awaits of the same crashed task, one parked before the crash and one after;
- an unawaited crash: stderr line, `main` goes on, exit 1; the same with `System.exit(0)` at the end exits 0;
- `Task.crashed_count()` before and after a crash and after the await that observes it;
- a crash in `main`, `RUNTIME-STEP-LIMIT` in a task, and `System.exit(3)` in a task still end the run with their own outcome;
- `RUNTIME-STACK-OVERFLOW` in a task ends only that task;
- descendants: a child and a grandchild of the crashed task never print again; a task awaiting a cancelled descendant crashes with `RUNTIME-TASK-CANCELLED`;
- handles: a file the crashed task opened is closed, and another task that holds it gets the closed error; a process it spawned is gone; a file opened by `main` and passed to the task stays open;
- the `--json` stderr line carries `"task": true`.

C tests in `vm/tests/task_cancel_test.c` (20b's file): a crash while `next_owner` of a handle lock passes the lock on; a crash with a reserved pool slot passes the slot on; the crash cleanup of a subtree.

Invariants, in the existing timing tests:

- **Latency** (`tests/vm-latency-test.rkt`): while one task crashes with 10,000 running descendants and 1,000 open files, a `Task.sleep(10)` wake in another task stays within the limit of the 7h latency test.
- **Step budget:** a crash spends no steps of its own and gives none back; a golden fixture with a crash records the same step count on every run, and `RUNTIME-STEP-LIMIT` from a task still ends the whole run.

**Docs** (in phase 24): `docs/grammar.md` (Lightweight tasks: crashes, the await rule, the exit code, `Task.crashed_count`; the new code), the programming skill (`references/tasks.md`, `references/diagnostics.md`, `references/bdd.md`), `site/content/library/task.md`, `docs/vm/10-io-scheduler.md` §10.2.1 ("As built", "Cancellation"), and the sentences of §25.9 and §27.1 that §37.7 lists.
