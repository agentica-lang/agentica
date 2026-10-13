### Lightweight tasks

`Task` is reserved. Tasks are cooperative tasks on one VM scheduler, for I/O concurrency without new keywords or CPU parallelism; a task yields when it waits for I/O, a timer or another task, and at the end of each turn. A block can be the task function when it is passed through a `Fn` variable or parameter.

```text
Task.spawn(f: Fn[A, R], arg: A) -> Task[R]
Task.await(task: Task[R]) -> R
Task.sleep(milliseconds: Int) -> Void
Task.pending_count() -> Int
Task.unobserved_crash() -> Result[String]
```

Spawn starts a named function immediately with one argument; use a struct for multiple values. Each task has independent scopes, call depth and return handling. Await returns the cached result and may be repeated. False, nil and Result.error are normal results. Tasks have no constructor, equality, fields, indexing or JSON encoding; inspect shows `<Task>`.

A runtime error in a task other than `main` is a crash: it ends only that task, and the rest of the program goes on. Its diagnostic is printed on stderr when it happens, with ` in a task` after the code (`--json` adds `"task": true`). Its running descendants are cancelled; no program can await one of them, since only the crashed subtree holds them (with `Task.map`, a later `Task.await` on a cancelled task will give `error("task: cancelled")` when `R` is a `Result`, and RUNTIME-TASK-CANCELLED otherwise; `HTTP.close_server` cancels only tasks no program holds). The files, sockets, listeners and processes it owns are closed: a handle belongs to the task that opened it, and one passed directly as the `Task.spawn` argument moves to the new task (a handle inside a struct, list or block does not move). When a task returns normally, the handles it still owns go to its parent task. Other tasks that use a closed handle get its closed error. An `HttpClient` is never closed by a crash. `Task.await` on a crashed task returns `error(text)` when `R` is a `Result`, where `text` is `task crashed: CODE at FILE:LINE:COLUMN: MESSAGE`; otherwise the awaiter halts with RUNTIME-TASK-CRASHED at its own await, with that text as the message, so the crash moves up through awaits. Each await of a crashed task gives the same outcome. These still end the whole run: a runtime error in `main`, RUNTIME-STEP-LIMIT, an internal VM error, and System.exit in any task (the run ends with its code). The first of these outcomes wins.

A crash is observed when an await returns its error or halts with RUNTIME-TASK-CRASHED, or when `Test.run` reports it. When `main` returns and a crash was never observed, the run exits 1 and prints one summary line on stderr: `2 task crashes were not observed; first: task crashed: ...` (`--json`: `{"unobserved_crashes":2,"first":"task crashed: ..."}`). `Task.unobserved_crash()` returns `ok(text)` for the first crash no await has observed, or `error("no unobserved crash")`; calling it does not observe the crash.

Returning from the entrypoint ends the run, and pending tasks never run again: explicitly await work that must finish. At the end of a run, however it ends, the VM flushes and closes open files (waiting for the writes; `--flush-timeout` bounds the wait), closes sockets and listeners, and stops and reaps the child processes it started; stdin, stdout and stderr stay open.

Sleep takes nonnegative milliseconds; zero yields. Negative durations halt with RUNTIME-INVALID-DURATION at the argument. Tasks inherit ports, arguments and contextual builtin services. Shared streams have no cross-task ordering guarantee; coordinate who reads input. All tasks, including nested tasks, share the execution's synchronized --max-steps counter.

Pending count returns how many tasks of this run have not ended, not counting `main`: tasks waiting to run, the task that calls it (unless it is `main`), and tasks waiting on a sleep, an await or I/O. A task that has returned or crashed is not counted, even when nothing awaited it.

BDD step handlers may use tasks but must finish them before returning, normally through Task.await: `std/bdd` checks `Task.pending_count()` after each handler, and pending work fails that step with RUNTIME-BDD-PENDING-TASKS; so does a step program whose `main` leaves tasks running when it calls `BDD.run`. Assertions made by tasks count for the step. A context changed in a task is lost unless the handler takes it back from `Task.await`. After the pending check, `std/bdd` checks `Task.unobserved_crash()`: a task that crashed in the step and was not awaited fails that step with RUNTIME-TASK-CRASHED and the crash text as its message. A runtime error in the handler itself ends the scenario's child VM, which fails only that scenario.

### Unit tests (`Test`)

`Test` and `TestCase` are reserved. `Test` is a builtin module for unit tests in the style of ExUnit; it needs no import. A test file is a program whose `main` calls `Test.run` with a list of `Test.test(name) do ... end` blocks.

The signatures of the `Test` functions are in `agentica help NAME --json` and in [`test.md`](../../site/content/library/test.md).

`Test.test` builds a `TestCase`, an opaque value that keeps the name, the block and the span of the `Test.test` call; it has no constructor, fields, equality or JSON encoding, and inspect shows `<TestCase>`. The block returns `Result[Void]`, so `try` works inside it and the last assertion can be its result.

Assertions return `ok()` when they hold and `error(text)` when they do not. `Test.eq` compares by value; both arguments have one type, and that type must be a data type: `Int`, `Float`, `Bool`, `String`, `Nil`, `Range`, `Json`, and lists, maps, Results, structs and enums made of them (`Result[Void]` too). Anything else, such as `Fn`, `Task`, a handle or `TestCase`, is CHECK-TYPE-MISMATCH. Lists compare in order, maps by their keys in any order, structs and enums by type, variant and fields, Results by tag and payload, Floats by IEEE 754, and a `Json` at any depth by its canonical text (sorted keys, as `JSON.encode` writes it). A failed `Test.eq` records the message `values are not equal`; its error text is `expected E; actual A`, where both are the inspect form, with each `Json` as its canonical text. `Test.ok?` gives `expected ok; actual A`, `Test.error?` gives `expected an error; actual A`, and `Test.assert` gives its message.

A failed assertion is also recorded on the test it runs in: the test's own task, or a task spawned inside the test. So `Test.eq(a, b)` as a statement, whose Result is dropped, still fails the test, and the first recorded failure is the one reported. Outside a test, an assertion only returns its Result.

`Test.run` never returns: it ends the run with an exit code. It runs only in `main`'s own task: called in any other task (a test, or a task `main` or a test spawned), it fails with RUNTIME-TEST-RUN at the call. It then checks the names: an empty name, or a name used by an earlier test of the list, fails the run with RUNTIME-TEST-NAME at that `Test.test` call. Run directly, as `agentica file.agc`, it then prints `run this file with agentica test` on stderr and exits 2. Under `agentica test`, stdin belongs to the runner; the runner protocol is in [`bdd.md`](../bdd.md#unit-test-files-testrun).

A test fails, in this order, with: the crash of its task (its own code, message and span; reporting it observes the crash); else its first recorded assertion (RUNTIME-TEST-ASSERTION at the assertion, its message, and `expected` and `actual` for `Test.eq`, only `actual` for `Test.ok?` and `Test.error?`, neither for `Test.assert`); else the `error(m)` the block returned (RUNTIME-TEST-ERROR with `m`, at the test); else tasks spawned in the test that were still running when its task ended (RUNTIME-TEST-PENDING-TASKS, at the test); else the first crash of such a task that no await observed (RUNTIME-TASK-CRASHED at the test, with the crash text as its message). After the record, every crash of the test's tasks counts as observed, and its tasks still running are cancelled before the next test, whatever the outcome. A crash prints its diagnostic on stderr as any task crash does. A runtime error in `main`, RUNTIME-STEP-LIMIT and `System.exit` in a test still end the whole run.

Each test's task gets its own `Random` generator, seeded from the run's seed (`--seed`, or the one drawn from the operating system) and the test's name, so a test sees the same values whether it runs alone or after other tests.

### `agentica test`

`agentica test [PATH...] [--steps FILE] [--only TEXT]` runs `.feature` specifications and `*_test.agc` unit test files in one report and gives the verdict as its exit code. BDD is the standard module `std/bdd`, written in Agentica (`import "std/bdd" as BDD`; `BDD` is not reserved, and a `BDD.` call without the import is `CHECK-UNKNOWN-NAME` with that import as its help). The discovery rules, the test timeouts, the output limits, the seed, the runner protocol and the step catalog are in [`bdd.md`](../bdd.md).
