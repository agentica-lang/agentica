### Lightweight tasks

`Task` is reserved. Tasks are cooperative and share one VM scheduler, so they give I/O concurrency without CPU parallelism. A task yields when it waits for I/O, a timer or another task, and at the end of each turn. Signatures are in [`library/task.md`](../../site/content/library/task.md).

`Task.spawn` starts a function at once with one argument; use a struct for several values. A block works when it is passed through an `Fn` variable or parameter. Each task has its own scopes, call depth and return handling. `Task.await` returns the cached result and may be repeated; `false`, `nil` and `error` are normal results. Tasks have no constructor, equality, fields, indexing or JSON encoding.

A runtime error in a task other than `main` is a crash. It ends only that task. Its diagnostic goes to stderr at once, with ` in a task` after the code (`--json` adds `"task": true`), and its running descendants are cancelled. The handles it owns close: a handle belongs to the task that opened it, and a handle passed directly to `Task.spawn` moves to the new task. A handle inside a struct, list or block does not move. A normally returning task hands its handles to its parent. A crash never closes an `HttpClient`.

`Task.await` on a crashed task returns `error(text)` when the result type is a Result, where `text` is `task crashed: CODE at FILE:LINE:COLUMN: MESSAGE`. For any other type, the awaiter halts with `RUNTIME-TASK-CRASHED` at its await, with that text, so the crash moves up. Each await gives the same outcome. Cancellation reaches the running descendants of a crash, and the handler tasks of `HTTP.close_server`, but only tasks that no program holds. An await of a cancelled task gives `error("task: cancelled")` when the result type is a Result, and halts with `RUNTIME-TASK-CANCELLED` otherwise.

Some errors end the whole run, whichever task raises them: a runtime error in `main`, `RUNTIME-STEP-LIMIT`, an internal VM error, and `System.exit` in any task. The first of these wins.

A crash is observed when an await returns its error or halts, or when `Test.run` reports it. If `main` returns with a crash never observed, the run exits 1 and prints one line on stderr: `2 task crashes were not observed; first: task crashed: ...` (with `--json`, `{"unobserved_crashes":2,"first":"task crashed: ..."}`). `Task.unobserved_crash()` returns `ok(text)` for the first unobserved crash, or `error("no unobserved crash")`; calling it does not observe the crash.

Returning from the entrypoint ends the run, and pending tasks never run again. At the end of any run the VM flushes and closes open files (bounded by the flush limit, 30 seconds by default, `--flush-timeout`), closes sockets and listeners, and stops and reaps the child processes it started. Standard streams stay open.

`Task.sleep` takes nonnegative milliseconds; zero yields. A negative duration is `RUNTIME-INVALID-DURATION`. Tasks inherit ports, arguments and builtin services. Shared streams have no ordering guarantee across tasks. All tasks share the `--max-steps` counter.

`Task.pending_count()` counts the tasks of this run that have not ended, not counting `main`: tasks waiting to run, the caller (unless it is `main`), and tasks waiting on a sleep, an await or I/O. A task that has returned or crashed is not counted.

A BDD step handler must finish its tasks before it returns (`RUNTIME-BDD-PENDING-TASKS`), and a crash nothing awaited fails the step with `RUNTIME-TASK-CRASHED`. See [`bdd.md`](../bdd.md).

### Unit tests (`Test`)

`Test` and `TestCase` are reserved. `Test` is a builtin module that needs no import. A test file is a program whose `main` calls `Test.run` with a list of `Test.test(name) do ... end` blocks. Signatures are in [`library/test.md`](../../site/content/library/test.md).

`Test.test` builds an opaque `TestCase` with the name, block and span of the call; `IO.inspect` shows `<TestCase>`. The block returns `Result[Void]`, so `try` works inside it and its last assertion can be its result.

An assertion returns `ok()` when it holds and `error(text)` when it does not. `Test.eq` compares by value. Both arguments must have one data type: `Int`, `Float`, `Bool`, `String`, `Nil`, `Range`, `Json`, or lists, maps, Results, structs and enums of them (`Result[Void]` too). Other types, such as `Fn`, `Task`, handles and `TestCase`, are `CHECK-TYPE-MISMATCH`. Lists compare in order, maps by key in any order, structs and enums by type, variant and fields, and Floats by IEEE 754. A `Json` compares by its canonical text at any depth. A failed `Test.eq` records `values are not equal`, and its error text is `expected E; actual A`. `Test.ok?` gives `expected ok; actual A`, `Test.error?` gives `expected an error; actual A`, and `Test.assert` gives its message.

A failed assertion is also recorded on the test it runs in, which is its own task or a task spawned inside it. So a dropped `Test.eq` still fails the test, and the first recorded failure is reported. Outside a test, an assertion only returns its Result.

`Test.run` never returns; it ends the run with an exit code. It must run in `main`'s own task: elsewhere it is `RUNTIME-TEST-RUN` at the call. It then checks the names: an empty name, or one used by an earlier test, is `RUNTIME-TEST-NAME` at that `Test.test`. Run directly as `agentica file.agc`, it prints `run this file with agentica test` on stderr and exits 2. Under `agentica test`, stdin belongs to the runner (see [`bdd.md`](../bdd.md#unit-test-files-testrun)).

A test fails with the first of these that applies:

1. The crash of its own task: its code, message and span. Reporting it observes the crash.
2. Its first recorded assertion: `RUNTIME-TEST-ASSERTION` at the assertion, with `expected` and `actual` for `Test.eq`, only `actual` for `Test.ok?` and `Test.error?`, and neither for `Test.assert`.
3. The `error(m)` its block returned: `RUNTIME-TEST-ERROR` with `m`, at the test.
4. Tasks spawned in the test that still run when its task ends: `RUNTIME-TEST-PENDING-TASKS`, at the test.
5. The first crash of such a task that no await observed: `RUNTIME-TASK-CRASHED` at the test.

After the record, every crash of the test's tasks counts as observed, and its running tasks are cancelled before the next test. A runtime error in `main`, `RUNTIME-STEP-LIMIT` and `System.exit` in a test still end the whole run.

Each test's task has its own `Random` generator, seeded from the run's seed and the test's name, so a test sees the same values alone or after other tests.

### `agentica test`

`agentica test [PATH...] [--steps FILE] [--only TEXT]` runs `.feature` specifications and `*_test.agc` unit test files in one report, and its exit code is the verdict. BDD is the standard module `std/bdd`, written in Agentica, and `BDD` is not reserved. A `BDD.` call without `import "std/bdd" as BDD` is `CHECK-UNKNOWN-NAME`, with the import as its help. The discovery rules, timeouts, output limits, seeds, runner protocol and step catalog are in [`bdd.md`](../bdd.md).
