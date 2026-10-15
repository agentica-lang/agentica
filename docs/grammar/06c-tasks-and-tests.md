### Lightweight tasks

`Task` is reserved. Tasks are cooperative and share one VM scheduler, so they give I/O concurrency without CPU parallelism. A task yields when it waits for I/O, a timer, a channel or another task, and at the end of each turn. Signatures are in [`library/concurrency/task.md`](../../site/content/library/concurrency/task.md).

`Task.spawn` starts a function at once with one argument; use a struct for several values. A block works when it is passed through an `Fn` variable or parameter. Each task has its own scopes, call depth and return handling. `Task.await` returns the cached result and may be repeated; `false`, `nil` and `error` are normal results. Tasks have no constructor, equality, fields, indexing or JSON encoding.

A runtime error in a task other than `main` is a crash. It ends only that task. Its diagnostic goes to stderr at once, with ` in a task` after the code (`--json` adds `"task": true`), and its running descendants are cancelled. The handles it owns close: see the next paragraph.

A handle (a file, a socket, a listener, a process or a `std/http` server) belongs to the task that opened it, and it is closed when that task ends, in any way: it returns, it crashes or it is cancelled. Nothing is given to the parent: a handle opened in a helper task and returned through `Task.await` is closed when the helper ends, so open a long-lived handle in the task that keeps it. A regular file is closed with its output written, and `Task.await` of the ended task returns only after that, so what a helper wrote to a regular file is on disk when the parent's await returns; the await does not wait for a flush to a FIFO or a pipe. Ownership decides who closes a handle, not who may use it: `Task.spawn(&f, handle)` passes the handle like any other argument and the caller still owns it, and any task that holds the handle can use it until its owner closes it. `Task.spawn_owning(&f, handle)` is the one way to hand a handle over. It starts the task as `Task.spawn` does and gives it a handle that the caller owns, so the new task closes it when it ends, as a connection task closes its socket. A server handed over this way takes its listener with it. The argument must be a handle type or a `Channel[T]`, or the checker gives `CHECK-NOT-A-HANDLE`; at run time a handle that the caller does not own, that was already handed over or that is closed is `RUNTIME-HANDLE-NOT-OWNED` in the caller. A crash or an end never closes an `HttpClient`. A `Channel` has no opener: it is unowned until `Task.spawn_owning(&f, channel)` gives it to the new task, and then it is closed when that task ends, as in [Channels](#channels). The first hand-off of an unowned channel is open to any task; after that only the owner can hand it on.

`Task.await` on a crashed task returns `error(text)` when the result type is a Result, where `text` is `task crashed: CODE at FILE:LINE:COLUMN: MESSAGE`. For any other type, the awaiter halts with `RUNTIME-TASK-CRASHED` at its await, with that text, so the crash moves up. Each await gives the same outcome. Cancellation reaches the running descendants of a crash, and the handler tasks of `HTTP.close_server`. A program can hold such a task, since a task can send its child's handle over a channel. An await of a cancelled task gives `error("task: cancelled")` when the result type is a Result, and halts with `RUNTIME-TASK-CANCELLED` otherwise.

Some errors end the whole run, whichever task raises them: a runtime error in `main`, `RUNTIME-STEP-LIMIT`, an internal VM error, and `System.exit` in any task. The first of these wins.

A crash is observed when an await returns its error or halts, or when `Test.run` reports it. If `main` returns with a crash never observed, the run exits 1 and prints one line on stderr: `2 task crashes were not observed; first: task crashed: ...` (with `--json`, `{"unobserved_crashes":2,"first":"task crashed: ..."}`). `Task.unobserved_crash()` returns `ok(text)` for the first unobserved crash, or `error("no unobserved crash")`; calling it does not observe the crash.

Returning from the entrypoint ends the run, and pending tasks never run again. At the end of any run the VM flushes and closes open files and waits for the buffered output of stdout and stderr to reach the pipe or file (bounded by the flush limit, 30 seconds by default, `--flush-timeout`), closes sockets and listeners, and stops and reaps the child processes it started. Standard streams stay open.

`Task.sleep` takes nonnegative milliseconds; zero yields. A negative duration is `RUNTIME-INVALID-DURATION`. Tasks inherit ports, arguments and builtin services. Shared streams have no ordering guarantee across tasks. All tasks share the `--max-steps` counter.

`Task.pending_count()` counts the tasks of this run that have not ended, not counting `main`: tasks waiting to run, the caller (unless it is `main`), and tasks waiting on a sleep, an await, a channel or I/O. A task that has returned or crashed is not counted.

`Task.await` halts with `RUNTIME-TASK-AWAIT-CYCLE` at the await when the awaited task, or a task it awaits in turn, is waiting for the caller. A task that awaits its own handle is the shortest cycle. A task can reach its own handle through a channel, or through a closure that captures it.

`Task.await(task, timeout_ms)` waits for at most `timeout_ms` milliseconds and returns `Await[T]`, a builtin generic enum with two variants: `Await.Done(value)` carries the task's result, and `Await.TimedOut` has no payload and is written without parentheses. `Await` is reserved: a struct, enum, type parameter or import alias with that name is `CHECK-REDEFINED-NAME`. The result is matched with `case` and checked for exhaustiveness like a user enum, and it can be annotated (`outcome: Await[Int]`), printed and interpolated: `IO.inspect` shows `Await.Done(42)` or `Await.TimedOut`. `try` does not apply to it (`CHECK-TYPE-MISMATCH` at the call). `timeout_ms` must be positive: zero or a negative value is `RUNTIME-INVALID-DURATION` at the argument. A timeout does not cancel the task and does not stop the caller: the task keeps running, and a later await, with or without a timeout, returns its outcome. A task that has already ended never times out, however short the timeout. When the task crashes or is cancelled before the timeout, the outcome is the one of the plain await: `Await.Done(error(text))` for a `Result` task, a halt with `RUNTIME-TASK-CRASHED` or `RUNTIME-TASK-CANCELLED` otherwise. A crash or a cancel after `Await.TimedOut` does not reach the caller. For a `Task[Void]` the result is `Await[Void]`, and the payload is matched as `Await.Done(_)`, as `Result.Ok(_)` is; a named binding there is `CHECK-VOID-TYPE`. The timed form takes no part in the cycle check: a task that awaits its own handle with a timeout, or two tasks that await each other with timeouts, get `Await.TimedOut` after the timeout, and a plain `Task.await` that reaches a task waiting with a timeout does not halt. A nested result is two cases: for a `Result` task, `Await.Done(r)` holds the `Result` to match in turn.

A BDD step handler must finish its tasks before it returns (`RUNTIME-BDD-PENDING-TASKS`), and a crash nothing awaited fails the step with `RUNTIME-TASK-CRASHED`. See [`bdd.md`](../bdd.md).

### Channels

`Channel` is reserved. A `Channel[T]` is a bounded queue that tasks send values into and receive values from. It is a handle: assigning or passing it shares the same channel. Channels run on the VM only.

```agentica
def send_all(jobs: Channel[Int]) -> Result[Void]
  for n in 1..5
    try jobs.send(n, 1000)
  end
  return ok()
end

def produce(jobs: Channel[Int]) -> Result[Void]
  result = send_all(jobs)
  jobs.close
  return result
end

def main() -> Void
  jobs: Channel[Int] = Channel.new(2)
  producer = Task.spawn(&produce, jobs)
  total = 0
  while true
    case jobs.recv(1000)
      ok(n) -> total += n
      error(_) ->
        if jobs.closed?
          break
        end
    end
  end
  puts(total)
  puts(Task.await(producer))
end
```

```text
Channel.new(capacity: Int) -> Channel[T]
Channel.send(channel: Channel[T], value: T, timeout_ms: Int) -> Result[Void]
Channel.recv(channel: Channel[T], timeout_ms: Int) -> Result[T]
Channel.close(channel: Channel[T]) -> Void
Channel.closed?(channel: Channel[T]) -> Bool
```

All but `new` are also methods: `jobs.send(v, 1000)`, `jobs.recv(1000)`, `jobs.close`, `jobs.closed?`. Signatures are in [`library/concurrency/channel.md`](../../site/content/library/concurrency/channel.md).

- **Type.** `T` is any type a variable can have, so `Channel[Void]` is `CHECK-VOID-TYPE`. A task handle, a socket, a file or another channel is allowed. A user `struct`, `enum` or import alias named `Channel` is `CHECK-REDEFINED-NAME`.
- **`Channel.new`** needs an expected type, from an annotation, a parameter, a field or a return type: `jobs: Channel[String] = Channel.new(16)`. Without one it is `CHECK-EXPECTED-TYPE` at the call, with a help that shows the annotated form. The capacity is 1 to 1,048,576, else `RUNTIME-INVALID-COUNT` at the argument. A channel is always bounded.
- **`send`** adds the value at the back and returns `ok()`. When the channel is full, the task waits for a free slot, for a close, or for the timeout. It returns `error("channel: closed")` if the channel is closed before or during the wait, and `error("channel: timed out")` at the timeout. In both cases the value is not added.
- **`recv`** returns the oldest value as `ok(v)`. When the channel is empty, the task waits for a value, for a close, or for the timeout. It returns `error("channel: closed")` once the channel is closed and drained, and `error("channel: timed out")` at the timeout. Values sent before `close` are still received after it.
- **Timeouts are required.** `timeout_ms` is 0 or more. Zero never waits: the call tries once. A negative value is `RUNTIME-INVALID-DURATION` at the argument. There is no wait-forever value, so tasks that wait for each other get timeout errors, not a hang.
- **`close`** returns `Void`, and closing again does nothing. Waiting senders get the closed error, and so do woken senders that have not run yet. Waiting receivers get the values left, then the closed error. The producer closes, on every path, and consumers do not. With several producers, one coordinator awaits all of them and then closes.
- **An owner.** `Task.spawn_owning(&produce, jobs)` makes the new task the owner of the channel. When that task ends in any way (it returns, crashes or is cancelled), the channel is closed as by `close`: receivers get the values already sent, then the closed error at once, and parked senders get the closed error. So a consumer does not wait for a timeout when its producer died. Any task can still call `close` on an owned channel, and the owner's end then does nothing more. A channel that is never handed over has no owner and is closed only by `close`. Plain `Task.spawn(&f, jobs)` gives no ownership. A channel with several producers has no owner: use the coordinator.
- **`closed?`** is `true` when the channel is closed, its buffer is empty and no value is reserved for a woken receiver. Once `true` it stays `true`. After a `recv` error it tells the end of the stream from a timeout.
- **Order.** Values come out in the order they went in. Waiting receivers are served in the order they started waiting, and so are waiting senders, with no barging: a value is handed straight to the first waiting receiver. A waiter that leaves before it runs, because it was cancelled or its timeout came first, passes what it was given to the next waiter. A receiver that was given a value returns it even if its deadline passes before it runs. No value is lost or added twice.
- **No data operations.** `puts`, `print`, interpolation and `==` on a channel are `CHECK-TYPE-MISMATCH`, `.to_s` is `CHECK-UNKNOWN-METHOD`, a JSON encoding of a struct with a channel field is `CHECK-NOT-ENCODABLE`, and `IO.inspect` prints `<Channel>`.
- **Effects.** `send`, `recv` and `close` carry `concurrency`. `new` and `closed?` carry none.

There is no `select`, no `for x in channel`, and no unbounded or unbuffered channel. To merge several sources, send them into one `Channel[Event]` of an enum type.

### Unit tests (`Test`)

`Test` and `TestCase` are reserved. `Test` is a builtin module that needs no import. A test file is a program whose `main` calls `Test.run` with a list of `Test.test(name) do ... end` blocks. Signatures are in [`library/testing/test.md`](../../site/content/library/testing/test.md).

`Test.test` builds an opaque `TestCase` with the name, block and span of the call; `IO.inspect` shows `<TestCase>`. The block returns `Result[Void]`, so `try` works inside it and its last assertion can be its result.

An assertion returns `ok()` when it holds and `error(text)` when it does not. `Test.eq` compares by value. Both arguments must have one data type: `Int`, `Float`, `Bool`, `String`, `Nil`, `Range`, `Json`, or lists, maps, sets, Results, structs and enums of them (`Result[Void]` too). Other types, such as `Fn`, `Task`, handles and `TestCase`, are `CHECK-TYPE-MISMATCH`. Lists compare in order, maps by key and sets by element in any order, structs and enums by type, variant and fields, and Floats by IEEE 754. A `Json` compares by its canonical text at any depth. A failed `Test.eq` records `values are not equal`, and its error text is `expected E; actual A`. `Test.ok?` gives `expected ok; actual A`, `Test.error?` gives `expected an error; actual A`, and `Test.assert` gives its message.

A failed assertion is also recorded on the test it runs in, which is its own task or a task spawned inside it. So a dropped `Test.eq` still fails the test, and the first recorded failure is reported. Outside a test, an assertion only returns its Result.

`Test.run` never returns; it ends the run with an exit code. It must be called from `main`'s own task: a call in a test or in any other task is `RUNTIME-TEST-RUN` at the call ("call Test.run from main, outside every test"). It then checks the names: an empty name, or one used by an earlier test, is `RUNTIME-TEST-NAME` at that `Test.test`. Run directly as `agentica file.agc`, it prints `run this file with agentica test` on stderr and exits 2. Under `agentica test` it talks to the runner on the child channel (`Process.parent_read_line` and `Process.parent_send`, see [`06d`](06d-io-and-network.md#processes) and [`bdd.md`](../bdd.md#unit-test-files-testrun)); a VM started with the `--agentica-test` arguments but without that channel fails with `RUNTIME-TEST-RUN`. The channel belongs to `Test.run`: test code that calls `Process.parent_read_line` or `Process.parent_send` can break the protocol, and nothing stops it (the same trust level as in [`36.7`](../future/36-unit-tests.md)). The test's own stdin and stdout are free: the runner shows what a test printed only when it fails.

A test fails with the first of these that applies:

1. The crash of its own task: its code, message and span. Reporting it observes the crash.
2. Its first recorded assertion: `RUNTIME-TEST-ASSERTION` at the assertion, with `expected` and `actual` for `Test.eq`, only `actual` for `Test.ok?` and `Test.error?`, and neither for `Test.assert`.
3. The `error(m)` its block returned: `RUNTIME-TEST-ERROR` with `m`, at the test.
4. Tasks spawned in the test that still run when its task ends: `RUNTIME-TEST-PENDING-TASKS`, at the test.
5. The first crash of such a task that no await observed: `RUNTIME-TASK-CRASHED` at the test.

After the record, every crash of the test's tasks counts as observed, and its running tasks are cancelled before the next test. A runtime error in `main`, `RUNTIME-STEP-LIMIT` and `System.exit` in a test still end the whole run.

Each test's task has its own `Random` generator, seeded from the run's seed and the test's name, so a test sees the same values alone or after other tests.

### `agentica test`

`agentica test [PATH...] [--steps FILE] [--only TEXT]` runs `.feature` specifications and `*_test.agc` unit test files in one report, and its exit code is the verdict. BDD is the standard module `std/bdd`, written in Agentica, and `BDD` is not reserved. A `BDD.` call without `import BDD from "std/bdd"` is `CHECK-UNKNOWN-NAME`, with the import as its help. The discovery rules, timeouts, output limits, seeds, runner protocol and step catalog are in [`bdd.md`](../bdd.md).
