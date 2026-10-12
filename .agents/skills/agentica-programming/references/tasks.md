# Lightweight tasks

```text
Task.spawn(f: Fn[A, R], arg: A) -> Task[R]
Task.await(task: Task[R]) -> R
Task.sleep(milliseconds: Int) -> Void
```

Start tasks before awaiting them to overlap I/O. They call named functions with one argument; pass a struct for multiple values. Each has independent variables, scopes and returns. Await returns the cached value and can be repeated. False, nil and error Results are normal values, with no extra Result wrapper. Task[R] has no constructor, equality, fields, indexing or JSON encoding; inspect prints `<Task>`. A handle belongs to its execution; awaiting one in another halts with RUNTIME-TASK-CONTEXT.

Any task diagnostic terminates the evaluation with its original code and span, even when unawaited. System.exit in any task terminates that evaluation with its code. The first terminal outcome published by the supervisor wins. Returning from the entrypoint cancels pending work; explicitly await tasks that must finish. External interruption cancels tasks and closes newly created resources while preserving caller-supplied ports. No channels or CPU parallelism are exposed. A block can be the task function when passed through a `Fn` variable or parameter.

Random: each task has its own generator, split from its parent at spawn (one parent draw per spawn), so with `--seed N` each task repeats its own values. `--seed` alone does not make a multi-task run repeatable: only per-task values repeat, and the interleaving can still depend on timer and thread-pool timing (sleeps, file and stdin reads), even on one scheduler. Do not depend on cross-task order.

Sleep accepts nonnegative milliseconds; zero yields and negative values halt with RUNTIME-INVALID-DURATION at the argument. Tasks inherit ports, program arguments and contextual services. Cross-task output order is unspecified; coordinate ownership of reads.

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

BDD registration and steps may spawn tasks. Finish them before returning, normally by awaiting them; pending work fails with RUNTIME-BDD-PENDING-TASKS. Child failures stop only their current handler; later scenarios continue. Completed child assertions count toward the current Then step; Doc Strings and tables remain those of that step. BDD registration/state/assertions are synchronized and stream lock wait counts against the operation timeout.
