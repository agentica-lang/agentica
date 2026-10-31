### Lightweight tasks

`Task` is reserved. Tasks are cooperative and run on the VM's schedulers, so
tasks may run in parallel (`--schedulers N`, section 6b). Every `Task` function,
its timing, cancellation and crash behaviour, and its runtime errors are in the
[`Task` page](../../site/content/library/concurrency/task.md). The rules of the
language and the checker:

- A `Task[R]` has no constructor, equality, fields, indexing or JSON encoding.
  `Task.spawn(&f)` starts a function of no parameter and `Task.spawn(&f, x)` one
  of one parameter. A block is a function too (`Task.spawn do ... end`), and
  `Task.spawn(&f) do ... end` is `CHECK-BLOCK-TARGET`.
- A handle (a file, a socket, a listener, a process or a `std/http` server)
  belongs to the task that opened it, and it is closed when that task ends, in
  any way. `Task.spawn_owning(&f, handle)` is the one way to hand a handle over;
  its argument must be a handle type, a resource of native code (section 6d), a
  `C.Pointer` or a `Channel[T]`, or a struct, enum, `List[T]`, `Map[K, V]` or
  `Result[T]` whose type holds one of them, or the checker gives
  `CHECK-NOT-A-HANDLE`.
- A runtime error in a task other than `main` is a crash that ends only that
  task. `Task.await` of a crashed task returns `error(text)` when the result
  type is a `Result`, and halts with `RUNTIME-TASK-CRASHED` otherwise; the same
  holds for a cancelled task (`error("task: cancelled")`,
  `RUNTIME-TASK-CANCELLED`).
- `Task.cancel(task)` takes a `Task[R]`; any other argument type is
  `CHECK-TYPE-MISMATCH` at the argument.
- `Task.await(task, timeout_ms)` returns `Await[T]`, a builtin generic enum with
  the variants `Await.Done(value)` and `Await.TimedOut` (no payload, written
  without parentheses). `Await` is reserved: a struct, enum, type parameter or
  import alias with that name is `CHECK-REDEFINED-NAME`. It is matched with
  `case` and checked for exhaustiveness like a user enum. `try` does not apply
  to it (`CHECK-TYPE-MISMATCH` at the call). For a `Task[Void]` the payload is
  matched as `Await.Done(_)`; a named binding there is `CHECK-VOID-TYPE`.
- `Task.map(items, limit, timeout_ms) do |item| ... end` is always written
  `Task.map(...)`, not as a method, so `xs.map` stays the sequential
  `List.map`. The block gives a `Result[R]`; `try` works in it. `R` comes from
  the expected type of the call, else from the first `ok(...)` the block gives,
  so a block that gives only `error(...)` needs the annotation
  (`CHECK-RESULT-TYPE` otherwise). A block whose last expression is not a
  `Result` is `CHECK-TYPE-MISMATCH`, and an empty list needs a type
  (`CHECK-EMPTY-LIST-TYPE`). The result is a `List[Result[R]]`, one `Result` per
  item in the order of `items`.
- A BDD step handler must finish its tasks before it returns
  (`RUNTIME-BDD-PENDING-TASKS`). See [`bdd.md`](../bdd.md).

### Channels

`Channel` is reserved. A `Channel[T]` is a bounded queue that tasks send values
into and receive values from, and a handle: assigning or passing it shares the
same channel. The functions (`new`, `send`, `recv`, `close`, `closed?`,
`empty?`), the timeouts, the order of waiters and the ownership of a channel are
in the
[`Channel` page](../../site/content/library/concurrency/channel.md).

- `T` is any type a variable can have, so `Channel[Void]` is `CHECK-VOID-TYPE`.
  A user `struct`, `enum` or import alias named `Channel` is
  `CHECK-REDEFINED-NAME`.
- `Channel.new` needs an expected type, from an annotation, a parameter, a field
  or a return type, else `CHECK-EXPECTED-TYPE` at the call.
- `puts`, `print`, interpolation and `==` on a channel are
  `CHECK-TYPE-MISMATCH`, `.to_s` is `CHECK-UNKNOWN-METHOD`, and a JSON encoding
  of a struct with a channel field is `CHECK-NOT-ENCODABLE`.

### Shared tables (ATS)

`ATS` (Agentica Table Storage) is reserved: a user `struct`, `enum` or import
alias named `ATS` is `CHECK-REDEFINED-NAME`. An `ATS[K, V]` is a mutable table
that tasks share through a handle, the role of Erlang's ETS: values stay
immutable, and a table is the one place where shared data changes in place. The
functions, atomicity, costs and lifetime are in the
[`ATS` page](../../site/content/library/concurrency/ats.md).

- A table is a handle, never copied. It may be a struct field, a list element, a
  `Map` value, or a `Task.spawn` argument or result, but not a value inside a
  table. A constant cannot hold one (`CHECK-CONSTANT-TYPE`).
- Keys are `Int` or `String`, else `CHECK-MAP-KEY-TYPE`. `V` must be a data type
  that is not `Nil`, else `CHECK-ATS-VALUE` at the value type; the test is deep
  and refuses `Fn`, `Task`, `Channel`, every handle, `Lazy` and `ATS` itself.
  `V` as `Void` is `CHECK-VOID-TYPE`, and a type parameter is refused as `V`.
- `ATS.new` needs an expected type, like `Channel.new` (`CHECK-EXPECTED-TYPE`).
  `ATS.add` works only on a table whose values are `Int`
  (`CHECK-TYPE-MISMATCH`).
- `puts`, `print`, interpolation and `==` on a table are `CHECK-TYPE-MISMATCH`,
  `.to_s` is `CHECK-UNKNOWN-METHOD`, and a JSON encoding of a struct with a
  table field is `CHECK-NOT-ENCODABLE`.
- `ATS.put`, `put_new`, `delete` and `add` carry the `concurrency` effect, so
  an ignored `put_new` or `add` is not `CHECK-UNUSED-VALUE`.

### Unit tests (`Test`)

`Test` and `TestCase` are reserved. `Test` is a builtin module that needs no
import. A test file is a program whose `main` calls `Test.run` with a list of
`Test.test(name) do ... end` blocks, and the block returns `Result[Void]`. The
assertions, the report, `Test.run` and the order in which a test fails are in
the [`Test` page](../../site/content/library/testing/test.md).

- `Test.eq` compares by value. Both arguments must have one data type: `Int`,
  `Float`, `Bool`, `String`, `Nil`, `Range`, `Json`, or lists, maps, sets,
  Results, structs and enums of them (`Result[Void]` too). Other types, such as
  `Fn`, `Task`, handles and `TestCase`, are `CHECK-TYPE-MISMATCH`.

### `agentica test`

`agentica test [PATH...] [--steps FILE] [--only TEXT] [--tags EXPR]` runs
`.feature` specifications and `*_test.agc` unit test files in one report, and
its exit code is the verdict. BDD is the standard module `std/bdd`, written in
Agentica, and `BDD` is not reserved. A `BDD.` call without `import BDD from
"std/bdd"` is `CHECK-UNKNOWN-NAME`, with the import as its help. The discovery
rules, timeouts, output limits, seeds, runner protocol and step catalog are in
[`bdd.md`](../bdd.md).

Not planned: an assertion that stops the test by itself (Agentica has no
exceptions; `try` is the one way to stop early); running tests in the runner's
own VM; a child VM per test (a task per test is enough); and `describe`, `setup`
and tags (a helper function does what `setup` does). Doctests, running the
fenced `agentica` examples of `std/` docs, are an option to evaluate later.
