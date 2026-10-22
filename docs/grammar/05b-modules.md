### File modules and imports

Each file is a module. `import Models from "models"` loads `models.agc` and
gives it the alias `Models`, and `import Util from "../lib/util"` loads
`../lib/util.agc`. The path has no extension. A path ending in `.agc`, an empty
path, a path ending in `/`, or a last part containing a dot (`"models.rb"`,
`"."`, `".."`) is `CHECK-IMPORT-PATH`, so a module file name has no dot apart
from `.agc`: `json.tools.agc` cannot be imported; rename it `json_tools.agc`.

Relative paths resolve from the importing file, not the working directory. Each
file is linked once. Cycles are `CHECK-IMPORT-CYCLE`, missing or unreadable
files are `CHECK-IMPORT-IO`, and invalid paths are `CHECK-IMPORT-PATH`; each is
located at the import.

`export type Name = Type` exports a type alias, alongside exported structs,
enums, functions and constants. An importer can use `Models.Names` or import it
by name with `import {Names} from "models"`; type aliases can also be renamed to
another capitalized name. Aliases can name private types in exported signatures;
importers can use values of the alias but cannot name or construct the private
type. Local names stay unqualified. Import aliases are uppercase and cannot
collide with declarations, other aliases, imported names or builtin names.
Imports cannot be re-exported.

#### Importing names

`import {User, greet} from "models"` brings the exported names `User` and
`greet` into the file, to be used bare, wherever the name can stand: `User` in
annotations and signatures, `User(name: "Ana")` to construct, `greet(user)` or
`user |> greet()` to call (parentheses are required, as for a function of the
file), `&greet` for a function value, and for an enum `Option`, the type
`Option[T]`, the values `Option.None` and `Option.Some(value)` and the patterns
`Option.Some(v)`. Variants are not imported on their own: import the enum. A
function, struct, enum, type alias and constant can all be imported this way.
The two forms mix: a file may import a module with an alias and, on another
line, import names from it, and two lines with the same path are fine (the file
is loaded once). A module imported only by names has no alias, so `Models.` is
not available for it.

An entry may rename: `import {greet as hello, User as Account, Names as Labels}
from "models"` binds local names for those exports. It exists so that two
modules that export the same name can both be imported by name, and so that a
long name can be shortened. A struct, enum or alias is renamed to a type name (a
capital first letter), a function to a lowercase name, a constant to another
constant name (capitals and underscores), and anything else is
`CHECK-IMPORT-RENAME`, located at the new name. The original name is not bound
unless another entry imports it, `{greet as hello, greet as hi}` binds two names
for one function, and messages that print a name show the original name. `as` is
contextual here too, and the original always comes first, so `{as as as_text}`
renames a function called `as`.

A name from an import list joins the names of the file, as a declaration does.
It must not be the name of a declaration of the file, of an alias, of another
imported name (in the same list or in another import line, and the same name
from the same module twice), of a builtin function such as `puts` or `ok`, or of
a reserved type name such as `Int` or `JSON`; each is `CHECK-REDEFINED-NAME`,
located at the name in the braces (at the new name of a rename). The std-only
names `HttpWire` and `LogRegistry` are reserved too, so they can be neither an
alias nor an imported name. A name that the module does not export, or that is
private, is `CHECK-IMPORT-NAME` at the name, with a `did you mean` help over the
exports only. These checks run when the file is loaded, so they are reported at
the import, before any use of the name. A name used as the wrong kind (an
imported struct as the enum of a pattern) is `CHECK-TYPE-MISMATCH`, as with an
alias.

Unused names are not reported.

#### Constants

`export LIMIT = 100` makes a constant visible, and `import {LIMIT} from
"limits"` brings it in by name, like any other exported name (it can be renamed
to another constant name: `import {LIMIT as MAX_ITEMS} from "limits"`). A
constant is read by its bare name, wherever an expression can stand, in the file
that declares it and in a file that imports it by name; it is not reached
through an alias. `Limits.LIMIT` is `CHECK-IMPORT-NAME` at the member, with the
help `write import {LIMIT} from "limits", then use LIMIT` (a typo of a constant
through an alias suggests `import {NAME}`), so a module that wants to offer a
value through its alias exports a function. An imported name must not collide
with a constant of the file, and two constants of the same name are
`CHECK-REDEFINED-NAME`, as for any declaration. An unexported constant is
private: importing it is `CHECK-IMPORT-NAME`. A constant is never changed, so
there is no shared state between modules: the value an importer reads is the
value the declaring file computed.

Only the root file supplies the executable `main() -> Void`; imported `main`
functions do not run. Imported calls and tasks share the program's step budget
and resource ownership. The CLI and `agentica test` use the same loader. There
are no wildcard imports, package registry, mutable module state, nested modules
or receiver attachment.

#### Standard library and external libraries

- `import Queue from "std/queue"` loads the standard library embedded at build
  time. Nothing needs to be installed, and local files or external roots cannot
  shadow it. Embedded modules may use relative imports inside `std/`, with
  `..` as long as the path stays in `std/`.
- `std/internal/` holds code that `std/` modules share and that is not API
  (`std/analysis` compiles the pure core of the front end from there). Only a
  `std/` module may import it; any other file gets `CHECK-IMPORT-IO`.
  `agentica doc` and `outline` of it fail as for a missing module: `cannot
  read` (`QUERY-USAGE` in `outline`, exit 2).
- `import Tools from "pkg/acme/tools"` searches for `acme/tools.agc` in order:
  `agc_libs/` beside the root program, or beside `agentica.toml` when the
  project has a manifest (not beside a dependency); the absolute roots in
  `AGENTICA_PATH` (`:`-separated, `;` on Windows), in order;
  `$XDG_DATA_HOME/agentica/lib/` (default `~/.local/share/agentica/lib/`; on
  Windows `%LOCALAPPDATA%/agentica/lib/`); then `/usr/local/share/agentica/lib/`
  and `/usr/share/agentica/lib/` (none on Windows). A first part (`acme`) that
  the manifest declares as a dependency is a package instead, and the search
  does not run for it (see Packages below).

The first existing file wins, and an error in that file does not fall back to
another root. Empty `AGENTICA_PATH` entries are ignored; a relative entry is
`CHECK-IMPORT-PATH`. A root is absolute when it starts with `/` (on Windows: a
drive path such as `C:\libs` or `C:/libs`, a UNC path such as
`\\server\share\libs`, or a path that starts with `/` or `\`; `C:libs` is
relative). On Windows the other separator is part of the entry, and
`XDG_DATA_HOME` and `HOME` are not read: an unset or relative `LOCALAPPDATA`
leaves the user root out. Library paths use forward slashes and reject empty,
`.`, `..`, backslash and colon components. After symlink resolution, the target
must stay inside its root. These checks apply to namespaced imports only:
imports are not a filesystem sandbox. A missing module is `CHECK-IMPORT-IO`.
Diagnostics inside an embedded module name its source, such as `std/queue.agc`.

#### Packages (`agentica.toml` and `agentica.lock`)

A package is a git repository of `.agc` files. A project uses packages when an
`agentica.toml` (the manifest) is in the folder of the root file or in a folder
above it; the nearest one counts, and its folder is the project folder. The
search goes up to the root of the file system, so an `agentica.toml` in a shared
parent folder (such as `/tmp`) is read and checked for every script below it,
and a bad one there is `PKG-MANIFEST-INVALID` for each of them. Without a
manifest nothing changes. A build reads the manifest and the lock and loads
packages from a cache that `agentica install` fills (see below). A build never
runs git and never uses the network. The other package commands are planned in
`docs/future/45-packages.md`.

```toml
name = "notes"

[dependencies]
sqlite = { git = "https://github.com/owner/sqlite-ac", tag = "v1.2.0" }
json5 = { git = "https://gitlab.com/someone/json5", ref = "3f2a9c1" }

[style]
max_line_width = 119
```

```ruby
import Sqlite from "pkg/sqlite/db"
```

- The manifest knows `name`, `[dependencies]` and `[style]`. An unknown key at
  any level, a value of the wrong form, or a TOML syntax error is
  `PKG-MANIFEST-INVALID`. `name` is optional and follows the rule of a
  dependency name below. `max_line_width` is an integer of 1 or more.
- A dependency is a local name and an inline table. The name is the key: a
  lowercase letter, then lowercase letters, digits, `_` and `-`, at most 64
  characters. It is the segment after `pkg/` in an import and has nothing to do
  with the URL, so moving a repository changes only its `git` line. The table
  has `git`, an `https://host/owner/repo` URL (an optional `.git` at the end; a
  lowercase host with no port and no user name; exactly an owner and a
  repository, each with only letters, digits, `.`, `_` and `-`, not `.`, `..` or
  starting with `-`, not ending in `.` and not a Windows device name such as
  `con` or `nul`), and exactly one of `tag` (1 to 128 letters, digits and the
  characters `.`, `_`, `+` and `-`; no `/`, and not starting with `.` or `-`) or
  `ref` (7 to 64 lowercase hex digits of a commit). Only git sources exist: a
  `path`, a branch, a version range or another key is `PKG-MANIFEST-INVALID`, at
  the key path (`dependencies.sqlite.path`).
- The import is `pkg/<name>/<module path>`, with no extension:
  `"pkg/sqlite/util/json"` loads `util/json.agc` of the package. `pkg/sqlite`
  with no module is `CHECK-IMPORT-PATH`. A name that the manifest of the
  importing file declares is a package, and it comes first: it shadows a library
  of the same name in `agc_libs/` and the other `pkg/` roots. A name that is not
  declared is the `pkg/` library search above, unchanged. Since the prefix is
  `pkg/`, a package import never clashes with a local file or folder.
- Which manifest decides: the manifest of the project for the files of the
  project (and of the `pkg/` libraries it loads), the manifest of the package
  itself, read from its folder in the cache, for the files of a package. A
  package file imports only the packages its own manifest declares; a `pkg/`
  name it did not declare is `CHECK-IMPORT-PACKAGE`, and the project cannot
  import the dependencies of a package unless it declares them too. A package
  file imports its own modules by relative paths that stay inside the package: a
  `../` that leaves it, a hidden folder or `agc_libs/` of the package, are
  `CHECK-IMPORT-PATH`.
- A manifest that declares a dependency needs `agentica.lock` beside it
  (`PKG-LOCK-MISSING`). Only the lock of the project is read; the
  `agentica.lock` of a package never is. The lock is TOML: `version = 1` (a
  missing `version` or any other value is `PKG-LOCK-INVALID`), then one
  `[[package]]` for every package of the build, direct or not, one entry for
  each name (a name twice is `PKG-LOCK-INVALID`): `name`, `git`, `tag` or `ref`
  (as in the manifest), `commit` (40 or 64 lowercase hex digits; it starts with
  the `ref`) and `hash` (`sha256:` and 64 lowercase hex digits). A bad lock is
  `PKG-LOCK-INVALID`. Every dependency of the manifest must be in the lock with
  the same `git` (with or without a `.git` at the end) and the same `tag` or
  `ref`, or the lock is `PKG-LOCK-STALE`. The same check runs on the manifest of
  every locked package that is in the cache: a name the lock lacks is
  `PKG-LOCK-STALE`, and a name with another source than the lock is
  `PKG-SOURCE-CONFLICT`; both are reported at `dependencies.<name>` of the
  manifest in the cache. One name with two different sources anywhere in the
  tree (the project and a package, or two packages) is `PKG-SOURCE-CONFLICT`;
  there are no versions to compare and no ranges to solve. Both checks run once
  for every command that loads code, before any file is read, so a conflict is
  reported whether or not an import reaches that package. A package that is not
  in the cache, one whose folder cannot be listed and one whose manifest is not
  a regular file are left for the import that loads them (so a conflict in them
  shows only then). A manifest that is a symbolic link, a folder or a pipe is
  `PKG-SYMLINK` and is never opened. The build never writes the lock.
- Manifest and lock errors have no source span. They name the file and the key
  path, such as `dependencies.sqlite.git` or `package[1].hash` (`[n]` counts
  from 0); a TOML syntax error has the line and column instead. In the plain
  form the key path replaces the source lines (`= key: ...`); in `--ai` it is
  the `key:` line; in `--json` it is `key_path`, and `range` is the start of the
  file. A failure about the file as a whole (a lock that is missing, a file that
  cannot be read) has no key: the plain and `--ai` forms show the file name
  alone, and `--json` has no `key_path` and a `range` at line 0, column 0.
- The cache holds one folder for each commit:
  `$XDG_CACHE_HOME/agentica/pkg/<host>/<owner>/<repo>/<commit>/`, from the `git`
  URL of the lock. Two names for one repository are two packages, each with its
  own lock entry. `XDG_CACHE_HOME` counts when it is absolute, else `~/.cache`
  is used (no cache when `HOME` is unset too). On Windows the folder is
  `%LOCALAPPDATA%/agentica/cache/pkg/` (no cache when it is unset or relative;
  `XDG_CACHE_HOME` and `HOME` are not read). A declared package that is not in
  the cache is `CHECK-IMPORT-PACKAGE`.
- `agentica install` fills the cache from the lock and never writes the lock. It
  takes no argument; the project is the nearest `agentica.toml` going up from
  the working folder (none is `PKG-MANIFEST-MISSING`), and the lock is checked
  against the manifest as a build checks it (`PKG-LOCK-STALE`). For each locked
  package, in the order of the file: a folder of the commit that is in the cache
  and has the locked hash is left alone and git does not run; a folder with
  another hash is `PKG-HASH-MISMATCH` and is never overwritten; else the package
  is fetched. The fetch runs the system `git` (its config, SSH keys and
  credential helpers apply; a `url.<base>.insteadOf` setting applies to the
  `git` value, which the lock keeps as written): a depth-1 fetch of the tag, or
  of the locked commit for a `ref`, into a temporary bare repository with no
  hooks and no working tree. The fetched commit must be the locked `commit`,
  else `PKG-TAG-MOVED`. The files are read from the commit tree with `git
  ls-tree` and `git cat-file`, so `.gitattributes` changes nothing. Only the
  files the hash covers and the `agentica.toml` at the root are copied. A
  symbolic link or submodule named `*.agc` or `agentica.toml` is `PKG-SYMLINK`,
  two copied paths that differ only in case are `PKG-PATH-COLLISION` (only case:
  not Unicode normalisation or Windows device names, which the hash still
  catches), a file over 1 MiB, or all files over 16 MiB, is `PKG-FETCH` naming
  the file, and the hash of the copy must be the locked hash
  (`PKG-HASH-MISMATCH`). The copy is built in a hidden `.tmp-*` folder of the
  cache root and renamed into place in one step (a killed install may leave that
  folder; delete it). git may ask for a password on a terminal; each read of its
  output has a 5 minute deadline. A git that cannot start or fails, a missing
  tag or commit, an unsafe path and a cache that cannot be written are
  `PKG-FETCH`. These failures name `agentica.lock` and the key of the entry
  (`package[1].tag`, `package[1].hash`; `package[1].git` when git itself
  failed; `package[1]` for the others). The first failure stops the command.
  When every package is in the cache, the manifest of each is checked against
  the lock (`PKG-LOCK-STALE`, `PKG-SOURCE-CONFLICT`). The command starts git
  even under `--deny-run`, which only limits programs.
- The hash covers the `.agc` files of the package folder. Their paths are
  relative to it, written with `/`, in bytewise order; for each file, its path,
  a zero byte, its size in decimal, a zero byte and its bytes. The hash is
  `sha256:` and the SHA-256 of that stream in hex (`Crypto.sha256`). Hidden
  folders (any depth), `agc_libs/` at the root and files that are not `.agc` are
  left out (`.agc` and `agc_libs` are compared without regard to case, so
  `x.AGC` is hashed and `AGC_LIBS/` is left out on every system), so the
  `agentica.toml` of a package is not hashed: it can only choose among the names
  of the lock. The first time a build loads a package, it hashes the folder and
  compares the result with the lock (`PKG-HASH-MISMATCH`); a symbolic link named
  `*.agc` is `PKG-SYMLINK`. A package that no import reaches is not hashed.
  Nothing in the cache is changed.
- The stored name of a package file in the `.agcb` file is
  `pkg/<name>@<tag>/path/in/repo.agc`, such as `pkg/sqlite@v1.2.0/db.agc`; for a
  package pinned by a `ref` it is `pkg/<name>@<first 12 digits of the
  commit>/...`. So the bytes do not depend on the cache folder. Diagnostics
  inside a package name the real file in the cache.

#### String queue (`std/queue`)

`std/queue` is written in Agentica; its signatures are in
[`library/data-structures/queue.md`][agentica-link-1].
Push adds at the back and pop removes the oldest value. Pop and peek on an empty
queue return an error Result. Inputs are never changed: continue with the
returned queue or `Popped.remaining`. Empty strings and duplicates are valid.
There are no user generics and no blocking cross-task operations. `push`, `pop`,
`peek`, `size` and `empty?` are O(n) with the current list operations; no
constant-time FIFO is promised.

#### Binary data (`std/binary`)

`std/binary` reads and writes binary numbers in a `List[Int]` of bytes, each
item in `0 .. 255`, the list that `IO.read_bytes`, `File.read_bytes` and the
other `*_bytes` builtins use. It is written in Agentica on the `Int` and `Float`
bit builtins; its signatures are in
[`library/text-and-data/binary.md`][agentica-link-2].
With the alias `Binary`:

- `Binary.read_u8`, `read_i8`, and `read_{u16,i16,u32,i32,u64,i64}_{be,le}` take
  `(data: List[Int], offset: Int)` and return `Result[Int]`.
  `Binary.read_f32_{be,le}` and `read_f64_{be,le}` return `Result[Float]`. `_be`
  is big-endian (network order), `_le` is little-endian, and signed types use
  two's complement. A reader never halts: a bad `offset`, a non-byte item, or a
  `u64` with the top bit set is an `error(...)`. The `offset` is zero-based and
  may be any `Int`.
- `Binary.write_u8`, `write_i8`, and `write_{u16,i16,u32,i32,u64}_{be,le}` take
  a value and return `Result[List[Int]]`, an error when the value is outside the
  type's range. `Binary.write_i64_{be,le}`, `write_f32_{be,le}` and
  `write_f64_{be,le}` cannot fail and return a plain `List[Int]`. `write_f32_*`
  rounds to binary32; every NaN is written as the canonical NaN
  (`Float.to_bits`, `Float.to_bits32`). Bit operations
  and the `Float` bit conversions are `Int` and `Float` builtins, because in
  Agentica each one is a 64-bit loop or an exact scaling by powers of two with
  special cases for `-0.0`, NaN and subnormals. If a compact `Bytes` type ever
  lands, the API moves to it in the same change as the `*_bytes` builtins.
- `Binary.concat(parts: List[List[Int]]) -> List[Int]` joins any number of parts
  in order, in O(n log k) for n bytes in k parts. `Binary.frame(payload:
  List[Int]) -> Result[List[Int]]` puts the payload's 4-byte big-endian length
  in front of it (an error above `4294967295` items).
  `Binary.read_frame_length(data, offset, max) -> Result[Int]` reads that length
  and returns an error above `max`, so a reader can reject a hostile length
  before it reads the body.
- `Int` is signed, so a `u64` above `9223372036854775807` is not an `Int`:
  `read_u64_*` returns an error for it and `write_u64_*` rejects a negative
  value. Use `read_i64_*` and `write_i64_*` for all 64 bits. Every `ok` of an
  integer reader writes back to the same bytes; a float reader does too, except
  that a NaN pattern other than the canonical one comes back canonical.
- Errors are checked in this order and the first that applies is returned: a
  negative `max` (`read_frame_length` only), an `offset` below zero or above
  `data.size - n`, the first item by index that is not a byte, the `u64` top
  bit, a writer's value outside its type, a payload over `4294967295` items, a
  frame length above `max`. Messages are lowercase with no final period; the
  examples are in
  [`binary.md`](../../site/content/library/text-and-data/binary.md).
- Writers return new lists and no buffer is ever changed. Offset writers into an
  existing list and the compact `Bytes` type are not part of the module. Half
  floats (f16), varints (LEB128), hex and Base64 come later, each when a real
  program needs it; hex and Base64 stay open in the crypto section.

#### TOML (`std/toml`)

`std/toml` reads and writes TOML 1.0 documents. It is written in Agentica; its
signatures and examples are in
[`library/text-and-data/toml.md`][agentica-link-3].
With the alias `Toml`:

- `export enum Value` models TOML's own values: `Str(String)`, `Int(Int)`,
  `Float(Float)`, `Bool(Bool)`, `DateTime(String)`, `Array(List[Value])` and
  `Table(Map[String, Value])`. The enum names itself in its payloads. A
  `DateTime` keeps the text as written (offset date-time, local date-time, local
  date, local time) and the module checks that it is a valid date-time; a leap
  second (`:60`) is accepted and every fractional digit is kept. A float whose
  magnitude is above the largest float reads as `inf`. An `Int` is a signed
  64-bit integer, and a value outside that range is a parse error.
- `Toml.parse(text: String) -> Result[Value]` accepts all of TOML 1.0 and
  nothing else. The root is always a `Table`, which keeps the first-insertion
  order of its keys. A CRLF counts as one LF. The redefinition rules of the
  specification are errors: a duplicate key, a table defined twice, extending an
  inline table or a static array, a dotted key against a `[header]`, and `[[a]]`
  against a static array or a table.
- A parse error is `line L, column C: ` followed by lowercase text with no final
  period. Lines and columns count from 1 and a column counts characters. Arrays
  and inline tables nest at most 256 levels and a key has at most 256 parts; a
  deeper input is an error at the opening bracket or the key. No input halts the
  program.
- `Toml.encode(value: Value) -> Result[String]` writes a `Table` as a document
  with a final newline, and any other root is an error. In each table the plain
  `key = value` lines come first, then `[a.b]` sections, then arrays that hold
  only tables as `[[a.b]]` sections, each group in `Map` insertion order. Keys
  that are not bare keys are quoted, and a `DateTime` that is not a valid
  date-time is an error. `Toml.parse` of the output gives back the same values,
  but the key order of a `Map` may be regrouped (plain entries first). A table
  path over 256 parts or an inline value nested over 256 levels is an error, as
  for `parse`, and so is a `to_json` value nested over 2,048 levels; none halts.
- `Toml.to_json(value: Value) -> Result[Json]` converts a value for
  `JSON.decode(JSON.encode(json), T)`. A `DateTime` becomes its string, an
  integer stays an integer and a float stays a float, and `inf` or `nan` is an
  error.
- `Toml.get(value: Value, path: String) -> Result[Value]` reads a dotted path of
  keys; a segment of plain digits (no sign, no leading zero) indexes an array.

#### BDD steps (`std/bdd`)

`std/bdd` is the step API of `agentica test`, written in Agentica. Most `BDD.*`
functions take the context first and return it; see
[`library/testing/bdd.md`](../../site/content/library/testing/bdd.md) and
[`bdd.md`](../bdd.md). `BDD.Context` can be named but not built: a context
exists only inside a step, so use the context that a call returns. The modules
`std/bdd/gherkin`, `std/bdd/match`, `std/test/report` and `std/test/runner` are
internal to `agentica test` and unsupported.

[agentica-link-1]: ../../site/content/library/data-structures/queue.md
[agentica-link-2]: ../../site/content/library/text-and-data/binary.md
[agentica-link-3]: ../../site/content/library/text-and-data/toml.md
