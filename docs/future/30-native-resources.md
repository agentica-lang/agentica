## 30. Native resources that outlive their module

Issue #1918, on demand: it starts when a package has to hand a native
handle to another package. The case that found it is `agentica-lang/ml`,
where a tensor library keeps its backends in their own packages.

### 30.1 Motivation

A package that owns a data type should be able to say "this value holds a
native handle" once, and let the backends fill it in. Today it cannot: a
`resource` belongs to the `extern module` block that declares it, and only
that block may name it in a signature, so a handle cannot travel inside a
value that another package types.

### 30.2 The rule today

`compiler/check/check_native.agc` accepts an `Opaque` in a native signature
only when the block owns it (`owners.get(name) == library`). Anything else:

```text
error[CHECK-NATIVE-TYPE] HandleA does not cross to a native module
```

The rationale is sound: the block also registers the free function, so a
type that another block could name would leave the VM unable to say who
frees it. `docs/grammar` states the same for parameters: a resource crosses
"as a whole parameter type", nothing else.

The consequence is that a handle cannot be *stored in data* and passed
between packages. Std handles (`File.Handle`, `Task`, `Channel`,
`JSON.Value`) do it because they are VM-level opaque types, not `extern
module` resources, so they never hit this check.

### 30.3 The case that needs it

Two packages, `tensor/` and a backend, where the backend depends on
`tensor/`:

- `tensor/` types the value: `struct Tensor` with a handle field.
- The backend declares the native module and creates the handle.
- `tensor/` dispatches operations; the backend only implements them.

Every arrangement hits the same wall:

1. Dispatch by `case` over a backend enum: the arm that calls the backend
   would need `tensor/` to import the backend, which imports `tensor/`.
2. Dispatch by a table of `Fn` values built by the backend (`Ops`): the
   table is over `tensor/`'s `Tensor`, whose handle is a resource of the
   *backend's* block, so `tensor/` cannot name the type.
3. A third package owning the dispatch: same problem, it would have to
   name both handles.
4. An untyped handle (an `Int` or `C.Pointer` into a registry the backend
   keeps): typechecks, and destroys arenas, explicit close and
   use-after-close diagnostics, because all three key on the resource
   value. Every leak becomes silent.

The workaround in use is the worst of the workable ones: the library that
should need nothing native declares one native module per backend,
`optional = true`, and owns all their build tables and C layers.

### 30.4 Proposal

Let a resource be declared outside an `extern module` block, so its type
belongs to the program or package while the block keeps the behaviour:

```agentica
# At file scope: the type is nameable by every module of the program.
resource TensorHandle, free: torch_free

extern module "torch"
  ## Creates a handle; the caller owns it.
  compute def create(shape: List[Int]) -> Result[TensorHandle]
  ...
end
```

Rules that make it safe:

- The `free` function is registered once, with the declaration, and the
  declaring module must define it. A handle value carries its destructor,
  so a module that receives one never has to know how to close it.
- A signature may name such a resource freely; a module that only *uses*
  the type does not become an owner.
- `RUNTIME-NATIVE-CLOSED` still reports a handle used after its close, and
  the close is still the one the declaration named.

A narrower variant, if the above is too much surface: keep the declaration
inside the block and add `resource TensorHandle, public`, which makes the
*type name* visible outside while ownership and the free function stay
unchanged. That is enough for case 2 above, which is the one `ml` needs.

### 30.5 Invariants the change must keep

1. `Native.arena` closes what the task opened inside it, newest-first, and
   keeps what the return value reaches.
2. `Native.close` stays explicit and idempotent; use after close is
   `RUNTIME-NATIVE-CLOSED`, never undefined behavior.
3. The free function of a handle is the one its declaration named, even
   when another module or another package created the value.
4. Crossing tasks keeps today's rule: `Task.spawn_owning` transfers
   ownership, and anything else is documented and not refused.
5. `CHECK-NATIVE-TYPE` keeps catching what it catches today: a type the VM
   could not free, a term where a C value belongs, a resource of a module
   that declares no free function.

### 30.6 Decided against

- An untyped handle with a registry per module (30.3, item 4): it trades
  the checker's knowledge of lifetimes for a type that looks ordinary, and
  the VM can no longer close anything correctly on a task abort.
- Making every resource implicitly public: the free function is what makes
  the type safe, and a public type without one is a leak by construction.
- A `Fn` table of ops defined in the *library* package for each backend:
  it works (that is the `ml` workaround), but it inverts the dependency, so
  the library grows one native module and one C layer per backend.

### 30.7 Open questions

- Does the type live in the program, in the package, or in the module that
  declares it? The `ml` case only needs "any module of the importing
  package", but a lock file hashes packages, so the answer decides whether
  a handle can cross a package boundary too.
- Should the declaration allow more than one destructor (a small vtable,
  e.g. `free` and `close`), or is one function enough?
- How does this interact with generics: `struct Holder[T]` where `T` is a
  resource, in a package that never declares a native module.
