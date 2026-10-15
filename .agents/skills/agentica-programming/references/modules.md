# File modules and imports

Each file is a module. `import "models" as Models` loads `models.agc`; `"../lib/util"` loads `../lib/util.agc`. Paths never include the extension (`import "models.agc"` is `CHECK-IMPORT-PATH`, and so are an empty path, a path ending in `/`, or a last part with a dot such as `"models.rb"`). So a module file name has no dot except `.agc`: `json.tools.agc` cannot be imported; rename it `json_tools.agc`.

- Relative paths resolve from the importing file, not the working directory.
- Every file, imported ones included, keeps the order: `import`s, then `struct` and `enum`, then `export def`, then private `def`. An imported file out of order is `CHECK-DECL-ORDER`, located in that file.
- Canonical paths identify files, and each file is linked once. A cycle is `CHECK-IMPORT-CYCLE`; a missing or unreadable import is `CHECK-IMPORT-IO`; an invalid path is `CHECK-IMPORT-PATH`. Each is reported at the import.

## Exports and names

`export struct`, `export enum`, and `export def` expose declarations; everything else is private.

- Use `Models.User` in annotations and JSON type arguments, `Models.User(name: "Ana")` to construct, `Models.greet(user)` to call, and `&Models.greet` for a callback.
- Imported enums: `Models.Option[T]` as a type, `Models.Option.Some(value)` to build, and `Models.Option.Some(item)` in a pattern.
- Local names stay unqualified inside their own file.
- Alias names are uppercase and cannot collide with declarations, other aliases, or builtin names. Imports cannot be re-exported.
- An exported signature may mention private types, but importers cannot name or build them.

## Running

Only the root file's `def main() -> Void` runs; imported `main` functions never run. Linking keeps source spans and distinct module identities. Imported calls and tasks share the program's execution budget and resource ownership. `agentica check`, `agentica FILE`, `agentica --dump`, and `agentica test` use the same loader.

There are no wildcard imports, package registry, module state, nested module blocks, or receiver attachment. `as` is contextual in imports, not reserved.

## Standard library and external libraries

Two prefixes select where a module comes from:

- `import "std/queue" as Queue` loads the standard library embedded at build time. No installation, environment variable, or checkout is needed at run time. Local files and external roots cannot shadow it.
- `import "pkg/acme/tools" as Tools` searches for `acme/tools.agc` in, in order:
  1. `agc_libs/` beside the root program (not beside each dependency, and not the working directory);
  2. absolute roots in `AGENTICA_PATH`, in the listed order;
  3. `$XDG_DATA_HOME/agentica/lib/`, defaulting to `~/.local/share/agentica/lib/`;
  4. `/usr/local/share/agentica/lib/`, then `/usr/share/agentica/lib/`.

On Windows, `AGENTICA_PATH` is separated by `;`, the user root is `%LOCALAPPDATA%/agentica/lib/` (fallback `~/AppData/Local/agentica/lib/`), and there are no default system roots. An unset or relative user-data variable uses the fallback directory. Empty `AGENTICA_PATH` entries are ignored; a relative entry gives `CHECK-IMPORT-PATH` when resolving a `pkg/` import. The first existing file wins, and a read or syntax error in it does not fall back to another root.

Library paths use forward slashes and reject empty, `.`, `..`, backslash, and colon components. An external target must stay inside its root after symlink resolution. These rules apply to namespaced imports only; ordinary relative imports are not a filesystem sandbox. A missing module is `CHECK-IMPORT-IO` at the import. Embedded-module diagnostics name their source, such as `std/queue.agc`. Embedded modules may use relative paths within their stdlib directory; external modules may use ordinary relative imports for their dependencies.

## String queue (`std/queue`)

`std/queue` is a library written in Agentica. Its exported records are `QueueState(items: List[String])` and `Popped(value: String, remaining: QueueState)`. With the alias `Queue`:

```text
Queue.new() -> Queue.QueueState
Queue.push(q: Queue.QueueState, value: String) -> Queue.QueueState
Queue.pop(q: Queue.QueueState) -> Result[Queue.Popped]
Queue.peek(q: Queue.QueueState) -> Result[String]
Queue.size(q: Queue.QueueState) -> Int
Queue.empty?(q: Queue.QueueState) -> Bool
```

Push adds at the back; pop removes the oldest value. Pop and peek on an empty queue return an error Result. Inputs are never changed: assign the returned queue (or `Popped.remaining`). Empty strings and duplicates are valid. `QueueState` is a normal exported struct, not an opaque handle. There are no user generics and no blocking cross-task queue operations. The implementation uses Lists: push, peek, size, empty? and new take near constant time, but pop is O(n) because it drops the first item of the list; no constant-time FIFO is promised.

## Other standard modules

- `std/http`: the HTTP client and server, written in Agentica. See `network.md`.
- `std/binary`: reads and writes binary numbers in a `List[Int]` of bytes. See `binary.md`.
- `std/logger`: levels, handlers, text and JSON lines on stderr. See `logger.md`.
- `std/bdd`: the step API of `agentica test`. See `bdd.md`.
