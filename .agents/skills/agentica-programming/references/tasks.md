# Lightweight tasks

```text
Task.spawn(f: Fn[A, R], arg: A) -> Task[R]
Task.await(task: Task[R]) -> R
Task.sleep(milliseconds: Int) -> Void
Task.pending_count() -> Int
```

Start tasks before awaiting them to overlap I/O. They call named functions with one argument; pass a struct for multiple values. Each has independent variables, scopes and returns. Await returns the cached value and can be repeated. False, nil and error Results are normal values, with no extra Result wrapper. Task[R] has no constructor, equality, fields, indexing or JSON encoding; inspect prints `<Task>`. A handle belongs to its execution; awaiting one in another halts with RUNTIME-TASK-CONTEXT.

Any task diagnostic terminates the evaluation with its original code and span, even when unawaited. System.exit in any task terminates that evaluation with its code. The first terminal outcome published by the supervisor wins. Returning from the entrypoint cancels pending work; explicitly await tasks that must finish. External interruption cancels tasks and closes newly created resources while preserving caller-supplied ports. No channels or CPU parallelism are exposed. A block can be the task function when passed through a `Fn` variable or parameter.

Random: each task has its own generator, split from its parent at spawn (one parent draw per spawn), so with `--seed N` each task repeats its own values. `--seed` alone does not make a multi-task run repeatable: only per-task values repeat, and the interleaving can still depend on timer and thread-pool timing (sleeps, file and stdin reads), even on one scheduler. Do not depend on cross-task order.

Sleep accepts nonnegative milliseconds; zero yields and negative values halt with RUNTIME-INVALID-DURATION at the argument. Tasks inherit ports, program arguments and contextual services. Cross-task output order is unspecified; coordinate ownership of reads.

`pending_count` (VM only) returns how many tasks of this run have not ended, not counting `main`: tasks waiting to run, the caller when it is not `main`, and tasks waiting on a sleep, an await or I/O. A returned task is not counted, even when nothing awaited it. Calling it where the program must run on the legacy evaluator stops with `LOWER-UNSUPPORTED` at that call.

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

BDD step handlers may spawn tasks and pass `ctx` to them inside a struct. Finish them before returning, normally by awaiting them: `std/bdd` checks `Task.pending_count()` after each handler, and pending work fails the step with RUNTIME-BDD-PENDING-TASKS (also a `main` that leaves tasks running when it calls `BDD.run`). Assertions made by tasks count for the step. A context changed in a task is lost unless the handler takes it back from `Task.await`. A failing task ends the scenario's child VM, so only that scenario fails.
