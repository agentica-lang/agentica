## 37. Task crash isolation

**Status:** done in roadmap [phase 24](../roadmap/24-task-crash-isolation.md) (order in §37.9), except `close_server` (20c), channels (17b) and `Test.run` (§36), which come with their phases. The fuzzer mode of §37.8 was dropped by the owner.

In the style of Erlang: a runtime error in a task other than `main` ends only that task. Its awaiters get an error `Result`, its descendants are cancelled, the handles and channels it owns are closed, and the rest of the program goes on. A crash in `main` still ends the program, and a crash nobody handles still prints its diagnostic and fails the run at the end.

### 37.1 Today

Checked at `099daa3`:

- Any runtime diagnostic in any task ends the whole run. `agc_fail` (`vm/interp.c:18-27`) stores the outcome in the runtime and `longjmp`s to the one `setjmp` of the run, in `agc_vm_run` (`vm/task.c:134-170`). `System.exit` (`agc_exit`, `vm/interp.c:40-44`) takes the same path. `docs/vm/10-io-scheduler.md` §10.2.1 ("As built", "Cancellation") records it.
- `Task.await(task: Task[R]) -> R` returns the task's result; there is no error path (`builtin_await`, `vm/task.c:183-190`).
- A task records no parent and no children (`struct agc_task`, `vm/agc.h:333-350`). Handles belong to the scheduler's resource registry, not to a task; they all close at the end of the run (§10.2).
- HTTP 20b ([roadmap](../roadmap/20-hybrid-http.md), [§30.6](30-hybrid-http.md#306-server-tasks-close_server-and-task-cancellation)) plans the parent and children links and `agc_task_cancel`, with no public API.

### 37.2 Why this is safe in Agentica

- **Values are immutable,** so a crashed task cannot leave a shared value half-updated.
- **Mutable state lives only in handles** (files, sockets, listeners, processes, servers, the HTTP pool, later channels); §37.5 gives a rule for each kind.
- **The runtime's own C state is the risk:** today a failure may leave it half-done because the run ends anyway. The audit of §37.8 removes that.

### 37.3 What a crash is, and what still ends the program

A **crash** is a runtime diagnostic raised while a task other than `main` runs: `RUNTIME-DIVISION-BY-ZERO`, `RUNTIME-INDEX-OUT-OF-RANGE`, `RUNTIME-UNWRAP-ERROR`, `RUNTIME-STACK-OVERFLOW` (the depth limit is per task), `RUNTIME-TASK-CANCELLED` at an await, and the rest. It ends only that task.

These still end the whole program, as today:

- a crash in `main`;
- `--max-steps` exhaustion (`RUNTIME-STEP-LIMIT`): the budget is global (§10.2.1, "Quotas");
- out of memory: the VM aborts (`docs/vm/05-values-execution-builtins.md`);
- internal VM errors (`RUNTIME-INTERNAL`), including a failed write to stdout or stderr and the stall check;
- `System.exit` in any task: the program asked to end.

### 37.4 What the program sees

- **`Task.await` on a crashed task.** `Task.await` keeps its type, `Task[R] -> R`, so the rule depends on `R`:
  - When `R` is `Result[T]`, the await returns `error(text)`. One level, as in `Task.map` (§27.1): a crash and the task's own `error(...)` are both one `error`.
  - Otherwise there is no value to return, so the awaiter halts with the new code **`RUNTIME-TASK-CRASHED`** at its own `Task.await` span. That is a crash of the awaiter, so the crash moves up through awaits, like an Erlang link.
  - Every await, the parked ones and later ones, sees the same outcome.
  - The VM cannot tell whether `R` is a `Result`: values carry no static type. Lowering knows it from the checker and picks one of two builtin entries for `Task.await` (§37.8).
- **The text** is the crash diagnostic on one line: `task crashed: CODE at FILE:LINE:COLUMN: MESSAGE`, for example `task crashed: RUNTIME-DIVISION-BY-ZERO at math.agc:2:13: division by zero`. The format is stable and pinned by golden fixtures; `RUNTIME-TASK-CRASHED` uses it as its message.
- **A cancelled task**, whatever the cause (a crash of its parent, a `Task.map` timeout, `close_server`): the `Result` await entry returns `error("task: cancelled")`, as `Task.map` gives `error("task: timed out")`, and the other entry halts with `RUNTIME-TASK-CANCELLED` at the await (20b's rule). One rule for every cancel, so no cancel reason is stored.
- **Stderr.** Every crash prints its diagnostic on stderr when it happens, awaited or not: the VM cannot know whether an await will come later.
  - Text: the normal diagnostic with ` in a task` after the header (`math.agc:2:13 error[RUNTIME-DIVISION-BY-ZERO] in a task`).
  - `--ai`: the normal block with ` in a task` after the code (`[RUNTIME-DIVISION-BY-ZERO] in a task`, then `message:`, `at:` and `source:`).
  - `--json`: the normal JSON object plus `"task": true`, so a reader that takes "the last stderr line" as the run's diagnostic (the BDD runner, §31.5) skips it.
- **Exit code.** A crash is **observed** when an await returns its `error` or halts with `RUNTIME-TASK-CRASHED`, when `Task.map` writes it into an item's slot, or when `Test.run` reports it (§36.3). When `main` returns and some crash was never observed, the run exits 1 instead of 0, and prints one summary line on stderr: `2 task crashes were not observed; first: task crashed: ...` (with `--json`: `{"unobserved_crashes": 2, "first": "task crashed: ..."}`). `System.exit(n)` keeps `n`; a fatal outcome keeps its own code.
- **`Task.unobserved_crash() -> Result[String]`** (new builtin): `ok(text)` with the first crash of this run that no await has observed, in the form above, or `error("no unobserved crash")`. Calling it does not observe the crash. Like `Task.pending_count` (§31.9), it serves `std/bdd`, which calls it after each step handler, after `Task.pending_count()`, and fails the step with `RUNTIME-TASK-CRASHED` and that text, so the crash's code and span stay in the report. `Test.run` (§36) does the same in C, and its report does observe the crash, so the next tests of the file do not fail with it again.
- **`Task.pending_count`** counts a crashed task as done.

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

- **Owners.** A user-visible handle is **owned** by the task that opened it: a file, a socket (`TCP`, `TLS`), a listener, a process (`Process.spawn`, `spawn_captured`) and a `std/http` server. The resource registry records the owner when the handle is made. Run-wide internals (the process guard, `guard_of` in `vm/process.c:481-483`) and job resources record no owner.
- **Moved at spawn.** A handle passed directly as the top-level `Task.spawn` argument moves to the new task when the spawning task owns it. So the usual server loop (`examples/tcp_echo.agc`: `main` accepts and spawns `echo` with the socket) gives each connection task its own socket: a crash in `echo` closes that socket, and the client sees the connection close instead of waiting. A handle nested in the argument (in a struct, list or closure capture) does not move, so a shared value passed inside a `Job(...)` struct stays with its owner. Channels never move.
- **Shared handles.** A handle that several tasks use belongs to one of them. When that owner crashes, the handle closes, and the others get the closed error on their next call. Programs that share a handle open it in a task that does not crash (`main` or a long-lived owner task, §27.5); the `references/tasks.md` note of phase 24 says so.
- **Given back at return.** When a task returns normally, the handles it still owns go to its parent (the nearest running ancestor). So a handle moved to a helper task, or opened there and returned in its result, is closed when the parent crashes later.
- **Owned handles are closed**, each by its kind's own close, as the program would close it (Erlang closes a port when its owner dies). Every kind is first marked closing, which wakes all its lock waiters; `agc_handle_wait` (or each builtin's `blocked` path) returns the closed error for a closing handle, and so does every later call.
  - **Files:** an `OP_CLOSE` pool job, as `File.close` does (`vm/files.c:923-935`), so the flush never runs on the loop thread. If a job holds the file (another task's operation in flight), the close is pending: `agc_io_finish` runs it when that job ends, instead of handing the lock on, and so does the place where 20b releases a detached holder's hold (the `sweep` path, `vm/loop.c:134`), since `agc_io_finish` never runs for a detached job. As built, a file still open at the end of the run closes through the same job, and the run waits for all of them: with no limit by default, or at most `--flush-timeout MS`, after which one warning line says that file data may not be written (§10.2.1 of `docs/vm/10-io-scheduler.md`).
  - **Sockets, listeners and TLS:** `disown` on the loop thread (`vm/tcp.c:197`). It does not block, and `shut_one` already wakes in-flight readers, writers and accepts.
  - **Processes:** `close_proc` (`vm/process.c:257`), as `Process.close` does (`SIGKILL`, or `SIGTERM` first for a captured child, §31.9). Never `release_proc`, which kills every child of the run (`close_children`) and then blocks in `outlast`.
  - **Servers:** `close_server` (20c), which cancels its handlers.
- **`HttpClient` is exempt.** A client is usually shared by many tasks, and closing it would abort their calls. It closes at the end of the run, as today.
- **A handle lock passes on.** A crash happens while the task runs, so it holds no lock for an I/O job. But it may crash in a builtin's retry while it is the `next_owner` of a lock. Then ownership passes to the head waiter, which is woken, as at a release (§10.2.2), with 20b's code.
- **Channels (§27.2)** belong to the task that created them and never move. A crash closes only those. 17b adds this case.

### 37.6 Children: a crash cancels the descendants

After 20b, a task that ends moves its running children to its parent. For crashes this section takes Erlang's side instead: **a crash cancels the crashed task's running descendants** with `agc_task_cancel`, then closes the handles it owns.

- A task's children are its work. A crashed task can no longer await them or stop them, so they would run on for nothing, still printing and spending the shared step budget.
- It is the rule §27.1 uses for a `Task.map` item that times out, and 20c for `close_server`: a task that ends abnormally takes its descendants with it.

The cancelled descendants follow 20b: their I/O jobs are detached. Handles they own are closed too, as above, so the whole subtree leaves nothing open. (Whether a timeout or `close_server` should also close the handles of the tasks it cancels stays the open question of §8.)

### 37.7 Effect on other sections

- **`Task.map` (§27.1).** A crash in an item ends only the item: its slot gets `error(text)`, its descendants are cancelled, and the other items go on. The block always returns a `Result`, so 17a uses the `Result` entry of §37.8 for its items. §27.1's rule that awaiting a cancelled task halts with `RUNTIME-TASK-CANCELLED` now holds only for the non-`Result` entry (§37.4). Phase 24 lands before 17a, so 17a builds on it.
- **Channels (§27.2).** A crash closes the channels the crashed task created (§37.5). The pattern for a channel with producers: each producer returns a `Result`, and the coordinator awaits them all and then closes the channel. A crashed producer gives the coordinator an `error`, so the close still happens. A diagnostic in `main` still ends the whole run.
- **`File.open` with a block (§25.9).** A crash inside the block ends the task, and the handle, owned by the task, is closed as in §37.5.
- **HTTP server (20c).** `HttpWire.spawn` applies the same move to its socket argument, so the socket belongs to the connection task (§37.5). A crash counts as the connection task ending under 20c's rule (its socket closes, its slot is freed, a waiting `accept` wakes). A handler runs inside its connection task, so a handler crash ends that connection: the client sees the connection close with no response; the server goes on. Answering 500 instead would need the handler in its own task; that is a later choice for `std/http`.
- **BDD (§31).** After each handler, `std/bdd` checks `Task.pending_count()` first, then `Task.unobserved_crash()`. A task that crashes in a step fails that step when its handler returns, or at the scenario deadline (`RUNTIME-BDD-TIMEOUT`) if the handler waits on the crashed task in a way that never ends. The runner ignores stderr lines with `"task": true` when it reads a child's last diagnostic. A crash in the handler itself (in `main`'s task) still ends the child, as today.

### 37.8 VM design

- **One `setjmp` per turn.** `agc_vm_run` sets the failure target before each turn, not once per run. When `agc_fail` jumps there, the scheduler reads the outcome: a fatal code (§37.3), an exit, or a failure in `main` ends the run as today; anything else crashes the current task. A `setjmp` costs a few nanoseconds against a turn of 2,000 steps; `make bench` checks it.
- **Two await entries.** Lowering emits `Task.await` as one of two builtin table entries, chosen by the checker's type of `R`: one returns `error(text)` for a crash, the other halts with `RUNTIME-TASK-CRASHED`. No opcode changes; the second entry is appended to the table.
- **Crashing a task**, in this order: `agc_turn_finish` and `trace_turn`, as for any turn's end; store the diagnostic (code, message, span) on the task and mark it done and crashed; print it on stderr; cancel its running descendants; close its owned handles and channels (§37.5); pass on a `next_owner` turn; wake its awaiters, which re-run their `Task.await` and see the crash. The task's registers and frames are dropped, as for a task that returns. The cleanup runs under the run-level `setjmp` target, so a `RUNTIME-INTERNAL` during cleanup ends the run.
- **The audit.** After this section, a failure no longer ends the run, so no builtin may fail while it leaves runtime state half-done: a lock taken but not recorded, a half-built registry entry, a task half-parked, a job without its owner, or a `malloc`'d temporary that is live across `agc_fail` (it would leak). Phase 24 checks every `agc_fail` and `agc_fail_text` site in `vm/` and moves each failure before the state change, or undoes the change first. The `on_limit` jump of `vm/value.c:85` is used by the fuzzer only and stays a run-ending outcome. The fuzzer (`make vm-fuzz`) gets a mode that spawns the mutant's `main` body in a task, so its crashes go down the new path.
- **Cost of the cleanup.** Cancelling descendants and starting the closes is O(descendants + handles). It runs between turns and is charged to no turn and never to `--max-steps`: the descendants were paid for when they were spawned. (As built in phase 24; the first plan charged the scheduler's next turn.)

### 37.9 Order

Decided by the owner on 2026-10-13: 7i (delete the evaluator and the builtin `HTTP` module) → 20b → §37 (phase 24) → §36 (phase 25) → 20c → 22 → 23. §37 needs 20b's parent and children links and `agc_task_cancel`; unit tests (§36) come right after, because they use it for isolation inside a test file. HTTP 20c does not depend on either and could go before them.

### 37.10 Later, in Agentica on top of this

Each needs its own spec and must pass the one-way test of §25:

- **Links and monitors** in the Erlang sense: be told when another task crashes, without awaiting it. They need channels (§27.2) to carry the message.
- **Supervisors and restart strategies** (one for one, one for all), written in Agentica (a `std/` module or the prelude) over spawn, await, crash results and channels.
- **Handle transfer** after spawn (Erlang's `port_connect`): give a handle a new owner.

### 37.11 Tests

Golden fixtures in `tests/fixtures/vm/` for each case (no timing, so their step counts are fixed and the `--max-steps` sweep holds):

- a crash in a task whose `R` is a `Result`: the await gets `error(text)`, `main` goes on, exit 0; the stderr line in text, `--ai` and `--json` (the golden harness normalizes the fixture directory in stderr, since crash lines carry the file path);
- a crash in a task whose `R` is not a `Result`: the awaiter halts with `RUNTIME-TASK-CRASHED` at its own span; from `main`, the run ends with exit 1; from another task, that task crashes in turn;
- two awaits of the same crashed task, one parked before the crash and one after;
- an unawaited crash: stderr line, `main` goes on, exit 1 with the summary line; the same with `System.exit(0)` at the end exits 0;
- `Task.unobserved_crash()` before a crash, after it, and after the await that observes it;
- a crash in `main`, `RUNTIME-STEP-LIMIT` in a task, and `System.exit(3)` in a task still end the run with their own outcome;
- `RUNTIME-STACK-OVERFLOW` in a task ends only that task;
- descendants: a child and a grandchild of the crashed task never print again; awaiting a cancelled descendant gives `error("task: cancelled")` or `RUNTIME-TASK-CANCELLED`, by `R`;
- handles: a file the crashed task opened is closed, and another task that holds it gets the closed error; a socket passed as the spawn argument is closed by the crash; a socket passed inside a struct, and a file opened by `main` and captured by a block, stay open; a process it spawned is gone; an `HttpClient` it made still works in another task.

C tests in `vm/tests/task_cancel_test.c` (20b's file): a crash while `next_owner` of a handle lock passes the lock on; the pending close of a file while another task's job holds it (the job ends first, then the close; a waiter gets the closed error), and while a detached job holds it (the close runs when 20b releases the hold); the crash cleanup of a subtree.

Invariants, in the existing timing tests:

- **Latency** (`tests/vm-latency-test.rkt`): while one task crashes with 10,000 running descendants and 1,000 open files, a `Task.sleep(10)` wake in another task stays within the limit of the 7h latency test.
- **Step budget:** a crash spends no steps of its own and gives none back; a golden fixture with a crash records the same step count on every run, and `RUNTIME-STEP-LIMIT` from a task still ends the whole run.

Existing tests that change, and the docs to update, are listed in [phase 24](../roadmap/24-task-crash-isolation.md).
