# Lightweight tasks

```text
Task.spawn(f: Fn[A, R], arg: A) -> Task[R]
Task.await(task: Task[R]) -> R
Task.sleep(milliseconds: Int) -> Void
Task.pending_count() -> Int
Task.unobserved_crash() -> Result[String]
```

Start tasks before awaiting them to overlap I/O. They call named functions with one argument; pass a struct for multiple values. Each has independent variables, scopes and returns. Await returns the cached value and can be repeated. False, nil and error Results are normal values, with no extra Result wrapper. Task[R] has no constructor, equality, fields, indexing or JSON encoding; inspect prints `<Task>`.

A runtime error in a task other than `main` is a crash and ends only that task; `main` goes on. The crash prints its diagnostic on stderr at once (` in a task` after the code; `"task": true` in `--json`), cancels the task's running descendants, and closes the files, sockets, listeners and processes it owns (never an `HttpClient`). A handle belongs to the task that opened it; one passed directly as the `Task.spawn` argument moves to the new task, one inside a struct or list does not. So open a shared handle in `main` or in a task that does not crash; others get the closed error after its owner crashes. `Task.await` on a crashed task returns `error("task crashed: CODE at FILE:LINE:COLUMN: MESSAGE")` when `R` is a `Result`; otherwise the awaiter halts with RUNTIME-TASK-CRASHED at its await. Give a task a `Result` return type when its caller should handle a crash. When `main` returns and some crash was never awaited, the run exits 1 with a summary line on stderr (`1 task crash was not observed; first: ...`). `Task.unobserved_crash()` returns `ok(text)` for the first such crash, or an error; it does not observe it.

A runtime error in `main`, RUNTIME-STEP-LIMIT and System.exit in any task still end the whole run; System.exit keeps its code. Returning from the entrypoint cancels pending work; explicitly await tasks that must finish. External interruption cancels tasks and closes newly created resources while preserving caller-supplied ports. No channels or CPU parallelism are exposed. A block can be the task function when passed through a `Fn` variable or parameter.

Random: each task has its own generator, split from its parent at spawn (one parent draw per spawn), so with `--seed N` each task repeats its own values. `--seed` alone does not make a multi-task run repeatable: only per-task values repeat, and the interleaving can still depend on timer and thread-pool timing (sleeps, file and stdin reads), even on one scheduler. Do not depend on cross-task order.

Sleep accepts nonnegative milliseconds; zero yields and negative values halt with RUNTIME-INVALID-DURATION at the argument. There is no `Task.cancel`; the VM cancels a task only when an ancestor crashes. `Task.await` on a cancelled task returns `error("task: cancelled")` when `R` is a `Result`, and otherwise halts with RUNTIME-TASK-CANCELLED at the await. No program can reach this yet: only the crashed task's subtree holds a cancelled task, and it is cancelled too. `Task.map` (17a) and the HTTP server (20c) will make it reachable. Tasks inherit ports, program arguments and contextual services. Cross-task output order is unspecified; coordinate ownership of reads.

`pending_count` returns how many tasks of this run have not ended, not counting `main`: tasks waiting to run, the caller when it is not `main`, and tasks waiting on a sleep, an await or I/O. A returned or crashed task is not counted, even when nothing awaited it.

```ruby
def double(n: Int) -> Int
  Task.sleep(0)
  return n * 2
end

def main() -> Void
  first = Task.spawn(&double, 21)
  second = Task.spawn(&double, 7)
  puts(Task.await(first).to_s)
  puts(Task.await(second).to_s)
end
```

BDD step handlers may spawn tasks and pass `ctx` to them inside a struct. Finish them before returning, normally by awaiting them: `std/bdd` checks `Task.pending_count()` after each handler, and pending work fails the step with RUNTIME-BDD-PENDING-TASKS (also a `main` that leaves tasks running when it calls `BDD.run`). Assertions made by tasks count for the step. A context changed in a task is lost unless the handler takes it back from `Task.await`. A task that crashes and is not awaited fails the step with RUNTIME-TASK-CRASHED when the handler returns. A runtime error in the handler itself ends the scenario's child VM, so only that scenario fails.
