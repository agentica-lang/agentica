### Lightweight tasks

`Task` is reserved. Tasks are cooperative and run on the VM's schedulers, so
tasks may run in parallel (`--schedulers N`, section 6b). Every `Task` function,
its timing, cancellation and crash behaviour, and its runtime errors are in the
[`Task` page](../../site/content/library/concurrency/task.md). The rules of the
language and the checker:

- A `Task[R]` has no constructor, equality, fields, indexing or JSON encoding.
  `Task.spawn(&f) do ... end` is `CHECK-BLOCK-TARGET`.
- A handle (a file, a socket, a listener, a process or a `std/http` server)
  belongs to the task that opened it, and it is closed when that task ends, in
  any way. `Task.spawn_owning(&f, handle)` is the one way to hand a handle over;
  an argument that holds no handle is `CHECK-NOT-A-HANDLE`. An `Address` is
  data, not a handle: a channel passed as its address in that argument is
  shared, not handed over.
- A runtime error in a task other than `main` is a crash that ends only that
  task. `Task.await` of a crashed or cancelled task returns `error(text)` when
  the result type is a `Result`, and halts with `RUNTIME-TASK-CRASHED` or
  `RUNTIME-TASK-CANCELLED` otherwise.
- `Await[T]` (`Await.Done(value)` and `Await.TimedOut`, written without
  parentheses), `TaskRef`, `TaskDown` and `TaskExit` are reserved: a struct,
  enum, type parameter or import alias with one of these names is
  `CHECK-REDEFINED-NAME`. `Await` is matched with `case` and checked for
  exhaustiveness like a user enum, and `try` does not apply to it. For a
  `Task[Void]` the payload is matched as `Await.Done(_)`; a named binding there
  is `CHECK-VOID-TYPE`.
- `Task.map(items, limit, timeout_ms) do |item| ... end` is always written
  `Task.map(...)`, not as a method, so `xs.map` stays the sequential
  `List.map`. The block gives a `Result[R]`, and `try` works in it.
- Argument types of `Task.cancel` and `Task.monitor`, and the reserved opaque
  `TaskRef` of `Task.current`, are in the `Task` page.
- A BDD step handler must finish its tasks before it returns
  (`RUNTIME-BDD-PENDING-TASKS`). See [`bdd.md`](https://github.com/agentica-lang/agentica/blob/master/docs/bdd.md).

### Channels

`Channel` is reserved. A `Channel[T]` is a bounded queue that tasks send values
into and receive values from, and a handle: assigning or passing it shares the
same channel. The functions, the timeouts, the order of waiters, the ownership
of a channel and the checker rules (the type `T`, the expected type of
`Channel.new`, what `puts`, `==` and JSON do with a channel) are in the
[`Channel` page](../../site/content/library/concurrency/channel.md).

`channel.address` gives an `Address[T]`: a send-only reference to the channel
that is data, so a table, a map, a list, a struct, an enum payload or a
message can hold it, and `==` compares which channel it names. It has `send`
only, so the channel's owner stays its one reader, and it does not keep the
channel alive. It cannot be JSON-encoded (`CHECK-NOT-ENCODABLE`), be a map key
or set element (`CHECK-MAP-KEY-TYPE`, `CHECK-SET-ELEMENT-TYPE`) or be in a
constant (`CHECK-CONSTANT-TYPE`). Its sends and errors are on the `Channel`
page. `Address` is not reserved: a program may declare a `struct`, `enum` or
alias named `Address` with no type parameters, but one with type parameters is
`CHECK-REDEFINED-NAME`, since `Address[T]` always names the builtin.

### Shared tables (ATS)

`ATS` (Agentica Table Storage) is reserved. An `ATS[K, V]` is a mutable table
that tasks share through a handle, the role of Erlang's ETS: values stay
immutable, and a table is the one place where shared data changes in place. The
functions, atomicity, costs, lifetime and the checker rules (where a table may
be held, the types `K` and `V`, the expected type of `ATS.new`, the effects of
its functions) are in the
[`ATS` page](../../site/content/library/concurrency/ats.md).

### Unit tests (`Test`)

`Test` and `TestCase` are reserved. `Test` is a builtin module that needs no
import. A test file is a program whose `main` calls `Test.run` with a list of
`Test.test(name) do ... end` blocks, and the block returns `Result[Void]`. The
assertions, the report, `Test.run` and the order in which a test fails are in
the [`Test` page](../../site/content/library/testing/test.md).

- Test functions: a `*_test.agc` file may have no `main`. Then `agentica test`
  runs its top-level `test_*` functions, in source order, as if `main` called
  `Test.run` with `Test.test("name", &test_name)` for each; the name is the
  function name without `test_`, with each `_` a space. A file with both
  `main` and `test_*` functions is `CHECK-TEST-MAIN`, at `main`, whatever the
  `test_*` functions are. Without `main`, a test function takes no parameters
  and its result is written `Result[Void]`, not an alias of it
  (`CHECK-TEST-SIGNATURE`, at the function), and `test_` alone is
  `CHECK-TEST-NAME`. `agentica check` applies
  these rules to a `*_test.agc` file; a run of such a file with no `main` is
  still `CHECK-MAIN`, and in a file of any other name `test_*` functions are
  ordinary functions.

### `agentica test`

`agentica test [PATH...] [--steps FILE] [--only TEXT] [--tags EXPR]
[--jobs N] [--timing] [--coverage]` runs `.feature` specifications and
`*_test.agc` unit test files in one report, and its exit code is the verdict.
BDD is the standard module `std/bdd`, written in Agentica, and `BDD` is not
reserved. A `BDD.` call
without `import BDD from "std/bdd"` is `CHECK-UNKNOWN-NAME`, with the import as
its help. The discovery
rules, timeouts, output limits, seeds, runner protocol and step catalog are in
[`bdd.md`](https://github.com/agentica-lang/agentica/blob/master/docs/bdd.md).

Not planned: an assertion that stops the test by itself (Agentica has no
exceptions; `try` is the one way to stop early); running tests in the runner's
own VM; a child VM per test (a task per test is enough); and `describe`, `setup`
and tags (a helper function does what `setup` does).
