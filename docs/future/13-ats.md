## 13. Shared tables (ATS)

ATS (Agentica Table Storage) plays the role of Erlang's ETS. Values are immutable, so passing one to a task shares it without a copy. What is missing is shared mutable state: a counter, or a cache that fills while tasks run. Today a task can only hand back a new value through `Task.await`. A table is one mutable place that tasks share through a handle.

A `Channel[T]` ([§27.2](27-iteration-and-concurrency.md#272-channels)) passes messages between tasks; a table is state that many tasks read and update. The table waits for a program that needs it. `Table` becomes a reserved type and module name, a breaking change: a user `struct Table`, `enum Table` or `import ... as Table` becomes `CHECK-REDEFINED-NAME`, as §12 says for `Range`, `Set` and `Queue`.

```agentica
def count_visit(hits: Table[String, Int]) -> Void
  hits.add("home", 1)
end

def main() -> Void
  hits: Table[String, Int] = Table.new()
  a = Task.spawn(&count_visit, hits)
  b = Task.spawn(&count_visit, hits)
  Task.await(a)
  Task.await(b)
  IO.inspect(hits.get("home"))   # ok(2)
end
```

- `Table[K, V]` is a builtin opaque generic, like `Task[T]`. A table value is a handle: assigning or passing it shares the same table, it does not copy it. This is the one place where data values are shared and mutable, so the name and the type say so.
- **Nesting:** a `Table` may be a struct field, a list element, a `Map` value, or a `Task.spawn` argument or result. It may not be stored inside a table (next rule).
- **Keys and values:** keys are `Int` or `String`; any other key type is `CHECK-MAP-KEY-TYPE`, as for `Map` keys. `V` may not be `Void` or `Nil`, and `data-type?` (`src/checker.rkt`) must hold for `V`. That walk is deep: it looks through struct fields, list elements, enum payloads, `Map` values and `Result`, and it rejects `Fn`, `Task`, every opaque handle (such as `FileHandle`, `Process` or `Socket`) and any new type such as `Table`. `Fn` is out because a block can capture a handle, which would get past this rule and could build cycles. A nested `Result[Void]` is allowed, because `data-type?` accepts it. The walk checks each declaration once by name, so recursive generic enums cannot loop. The checker enforces this wherever a `Table[K, V]` type is written or inferred, with `CHECK-TABLE-VALUE` (span on the type, or on `Table.new()` when inferred).
- **Sharing values:** values are immutable, so storing one shares it safely. Each call is atomic, so a reader sees either the old value or the new one.
- Functions (also methods, with the table first):

  | Function | Result |
  |---|---|
  | `Table.new() -> Table[K, V]` | needs an expected type, like an empty `Map`; without one, `CHECK-EXPECTED-TYPE` (the general code of [§27.2](27-iteration-and-concurrency.md#272-channels)) |
  | `Table.put(t, k: K, v: V) -> Void` | insert or replace |
  | `Table.put_new(t, k: K, v: V) -> Bool` | insert only when the key is absent; `false` leaves the table unchanged (ETS `insert_new`) |
  | `Table.get(t, k: K) -> Result[V]`, `Table.has_key?(t, k: K) -> Bool` | |
  | `Table.delete(t, k: K) -> Void` | absent keys are ignored |
  | `Table.add(t, k: K, n: Int) -> Int` | `Table[K, Int]` only: adds `n` (absent counts as 0) and returns the new value, atomically (ETS `update_counter`); overflow halts with `RUNTIME-INTEGER-OVERFLOW` and leaves the table unchanged; on a table whose values are not `Int`, `CHECK-TYPE-MISMATCH` |
  | `Table.size(t) -> Int` | a snapshot read, O(1) |
  | `Table.keys(t) -> List[K]`, `Table.to_map(t) -> Map[K, V]` | snapshots, in first-insertion order; a key deleted and then put again goes to the end, as in `Map` |

- **Left out on purpose:** `get` with a default and `values`, which `Map` has. Use `Result.unwrap_or` and `to_map`.
- **No eviction:** a table has no size limit and no expiry, as ETS has neither. A bounded or expiring cache is not a change to `Table`. It is a later `std/` module, written in Agentica on top of `Table` (the std-first rule, [roadmap](../roadmap/README.md#new-library-features-std-first)). Elixir libraries such as Cachex add that on top of ETS. This spec does not design that module; `Table` stays the small primitive.
- **Costs:** `get`, `put`, `put_new`, `has_key?`, `delete` and `add` take at most O(log n) in the table size (unlike `Map.delete`, which is O(n)). `size` is O(1). Taking a snapshot for `keys` or `to_map` is O(1) and blocks no other task; building its list or map is O(n).
- **Atomicity:** each call is atomic on its own. There are no transactions over several keys and no user code runs inside a call (no `update` with a block), so a call cannot deadlock or re-enter the table.
- **Read-modify-write:** `Table.add` is the only atomic update. `put_new` only inserts when the key is absent. To update any other existing value safely, let a single owner task do the writes. A compare-and-swap (`Table.replace`) waits for a real program.
- **Lifetime:** a table belongs to the execution that created it, like a `Task` handle. Inside that execution all its tasks share it, and the garbage collector frees it when no value refers to it. Using it from another execution halts with `RUNTIME-TABLE-CONTEXT`. On the VM one run is one execution, so a handle cannot reach another one today; the check stays for safety and for any later way to pass values between executions. Scenarios stay isolated because each BDD scenario is its own VM run (`docs/bdd.md`, "How a run works"). There is no owner process and no named global table, unlike ETS: a task reaches a table only through a handle it was given.
  - **BDD:** after phase 21 (`docs/bdd.md`, "How a run works") each scenario runs in its own child VM, and the step program's `main` runs again in that child, so registration and every step of one scenario are one execution. A table created in `main` and captured by a step block is shared by the steps of that scenario and starts fresh in the next one; nothing crosses scenarios. A table cannot go in the scenario's JSON state (`BDD.set` takes `Json`), so to pass a table between steps capture it from `main`; to pass data, use the JSON state.
- **Ownership:** a table is not an OS resource, so the owner rule of [§37.5](37-task-crash-isolation.md#375-handles-of-a-task-that-ends) does not apply to it. The task that creates a table does not own it, and ending that task (a return, a crash or a cancel) does not close it. It lives while any value refers to it, and the garbage collector frees it then. A `Channel` is exempt from the owner rule in the same way. Passing a table to `Task.spawn` shares it; `Task.spawn_owning` is not needed.
- **No `==`, no JSON, no `to_s`.** As for `Task`, `puts`, `print` and interpolation of a table give `CHECK-TYPE-MISMATCH`, and `.to_s` gives `CHECK-UNKNOWN-METHOD`. The rules are deep: `==` takes primitive values only, so a struct or list holding a table cannot be compared anyway; JSON encoding rejects a value with a table inside, as it does for `Task`; `IO.inspect` prints `<Table>` in place of the table, without its contents. Use `to_map` to see them.
- **Not in the first version:** ordered tables (`ordered_set`), duplicate keys (`bag`), match specifications, and tables shared between OS processes. Each waits for a real program.
- **Effects:** `Table.put`, `put_new`, `delete` and `add` carry the existing `concurrency` effect label, like `Task.spawn`. The label matters for `put_new` and `add`: their results may be ignored, so it keeps `CHECK-UNUSED-VALUE` away. `put` and `delete` return `Void`; they carry it so `help --json` shows the effect.
- **Backend:** the VM is the only backend, since the Racket evaluator was deleted (roadmap row 7.2), so the table lands on the VM only. The contract is only that each call is atomic.
  - Scheduler: a table call does not yield, so with one scheduler it is atomic. The VM runs one scheduler today; the flag for more is not built yet. Once N schedulers run in parallel, each table call needs a lock, or a persistent structure installed with compare-and-swap. The rule is in `docs/vm/10-io-multicore.md` §10.2.3, and the schedulers wait for roadmap row 11.
  - Layout: O(log n) `delete` with insertion order needs its own layout, not the `Map` layout. 9a builds a persistent ordered map for it on the VM, for example a balanced tree: a persistent hash from key to (sequence, value), plus a persistent sorted map from sequence to key.
- **Front end:** the checker part (`CHECK-TABLE-VALUE` and the reserved name) goes into `src/` as written if phase 9 starts before the freeze of the Racket front end (roadmap row 7.2.7, [roadmap](../roadmap/README.md)). If it starts after the freeze, the checker part goes into the Agentica front end ([§35](35-self-hosting.md)) instead, since the Racket front end takes no new checker rules then.

