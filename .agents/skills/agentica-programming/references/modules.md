# File modules and imports

Each file is a module. Use `import "models" as Models` at the top level.
An import path names a module without its extension: `"models"` loads
`models.agc`, and `"../lib/util"` loads `../lib/util.agc`. Never write the
extension: `import "models.agc"` gives `CHECK-IMPORT-PATH` (the help shows the
path without it), and so do an empty path, a path that ends in `/`, and a last
part with a dot (`"models.rb"`). So a module file name has no dot apart from
`.agc`: `json.tools.agc` cannot be imported; rename it, for example to
`json_tools.agc`. Relative paths resolve from the importing
file, not the working directory. Canonical paths identify files; each file is linked once. Cycles give
`CHECK-IMPORT-CYCLE`; missing or unreadable imports give `CHECK-IMPORT-IO`, and
invalid paths give `CHECK-IMPORT-PATH`. Each is located at the import.

`export struct User ... end`, `export enum Option[T] ... end`, and
`export def greet(...) ... end` expose declarations; everything else is
private. Use `Models.User` in annotations and JSON type arguments,
`Models.User(name: "Ana")` for construction, `Models.greet(user)` for calls,
and `&Models.greet` for callbacks. Imported enums use `Models.Option[T]`,
`Models.Option.Some(value)`, and `Models.Option.Some(item)` in patterns.
Local names remain unqualified inside their file. Import aliases are uppercase
and cannot collide with declarations, other aliases, or builtin names.
Imports cannot be re-exported. Exported signatures may mention private types,
but importers cannot name or construct those private types.

Only the root file supplies the executable `main() -> Void`. Imported main
functions do not run automatically. Linking preserves source spans and distinct
module identities; imported calls/tasks share the program's execution budget
and resource ownership. CLI check/run/dump and `agentica test` use the same loader.
There are no wildcard imports, package registry, module state, nested module
blocks, or receiver attachment. `as` is contextual in imports, not reserved.

## Standard library and external libraries

Two prefixes select library resolution:

- `import "std/queue" as Queue` loads the standard library embedded at
  build time. No stdlib installation, environment variable, or repository
  checkout is needed at runtime. Local files and external roots cannot shadow it.
- `import "pkg/acme/tools" as Tools` searches for `acme/tools.agc` in:
  1. `agc_libs/` beside the root program (not beside each dependency or in cwd).
  2. Absolute roots in `AGENTICA_PATH`, in listed order.
  3. `$XDG_DATA_HOME/agentica/lib/`, defaulting to
     `~/.local/share/agentica/lib/`.
  4. `/usr/local/share/agentica/lib/`, then `/usr/share/agentica/lib/`.

On Windows, `AGENTICA_PATH` uses `;` instead of `:`, the user root is
`%LOCALAPPDATA%/agentica/lib/` (fallback `~/AppData/Local/agentica/lib/`),
and there are no default system roots. On other platforms the paths above apply.
An unset or relative user-data environment variable uses the fallback directory.
Empty `AGENTICA_PATH` entries are ignored; relative entries give
`CHECK-IMPORT-PATH` when resolving a `pkg/` import. First existing file wins;
a read or syntax error in that file does not fall back to another root.

Library paths use forward slashes and reject empty, `.`, `..`, backslash,
and colon components. External targets must remain inside their selected root
after symlink resolution. These restrictions apply to namespaced imports, not
to ordinary relative dependencies: imports are not a filesystem sandbox.
Missing modules give `CHECK-IMPORT-IO` at the import. Other imports retain
their existing file-relative behavior; there is no implicit search fallback.
Embedded-module diagnostics name their source, for example `std/queue.agc`.
Embedded dependencies may use relative paths within their stdlib directory.
External modules may use ordinary relative imports for their dependencies.

## String queue

`std/queue` (the file `std/queue.agc`) is a non-native library written in Agentica. Its exported
immutable records are `QueueState(items: List[String])` and
`Popped(value: String, remaining: QueueState)`.

With the alias `Queue`:

```text
Queue.new() -> Queue.QueueState
Queue.push(q: Queue.QueueState, value: String) -> Queue.QueueState
Queue.pop(q: Queue.QueueState) -> Result[Queue.Popped]
Queue.peek(q: Queue.QueueState) -> Result[String]
Queue.size(q: Queue.QueueState) -> Int
Queue.empty?(q: Queue.QueueState) -> Bool
```

Push adds at the back; pop removes the oldest value. Empty pop/peek return an
error Result. Inputs remain unchanged; assign the returned queue (or
`Popped.remaining`) to continue. Empty strings and duplicates are valid.
QueueState is a normal exported struct, not an opaque handle. There are no
user generics or blocking cross-task queue operations.
The implementation uses Lists: push, pop, peek, size and empty? are O(n)
with the current host list operations; new is O(1). No constant-time FIFO
performance is promised.

## HTTP client (`std/http`)

`std/http` is the new HTTP client, written in Agentica. It runs only on the
VM, and until the builtin `HTTP` module goes it is imported under another
alias: `import "std/http" as Web`. It has `Web.client_options()`,
`Web.client(options)`, `Web.get`, `Web.post`, `Web.request`,
`Web.header_values` and `Web.close_client`; calls return
`Result[HttpResponse]` with the whole body as a `String`. Importing it makes
the program VM-only: do not mix it with `HTTP` builtins in one
program (`LOWER-UNSUPPORTED`). Details are in `network.md`.

`import "std/bdd" as BDD` is the step API of `agentica test`; see `bdd.md`.
