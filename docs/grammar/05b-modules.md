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
A module can pass on a name it imports with a re-export (below).

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

#### Re-exports

A module can pass on a name it imports, so a small facade file can collect the
API of several files:

```agentica
# web.agc
import Url from "url"
import Parts from "http_parts"

export Url.parse
export Url.Address
export Parts.header_value
```

`export Alias.name` (a function, a constant) and `export Alias.TypeName` (a
struct, enum or type alias) add the name to the exports of the file. There is
no renaming (`as`) and no wildcard (`export Url.*`): a facade that wants
another name writes a wrapper function. `export` is followed by a type name
and a dot only for a re-export, so there is no clash with `export def`,
`export struct`, `export enum`, `export type` and `export NAME = ...`.

- The alias must be an import of this file (`import Url from "url"`; a module
  imported only by names has no alias), otherwise `CHECK-IMPORT-NAME` at the
  alias. The module must export the name, otherwise `CHECK-IMPORT-NAME` at the
  name, with a `did you mean` help over the exports. A private name is not
  re-exportable.
- The name must not be the name of a declaration of the file, of another
  re-export or of an import alias of the file: `CHECK-REDEFINED-NAME` at the
  name. So the alias of a facade must differ from the names it re-exports:
  `import Value from "value"` with `export Value.Value` is an error; write
  `import V from "value"` and `export V.Value`.
- It is the same declaration, not a copy. A program that imports both
  `web.agc` and `url.agc` sees `Web.Address` and `Url.Address` as one type, and
  `&Web.parse` and `&Url.parse` are the same function. A re-export of a
  re-export leads to the original declaration, and a re-exported enum brings
  its variants (`Web.Option.Some(x)`). A re-exported constant is read as
  `Web.LIMIT`.
- Inside the file the name is still `Url.parse`: a re-export adds no local
  name.
- Re-exports come with the imports, may follow each other and the imports
  directly, and after a declaration need the blank line
  (`PARSE-MISSING-BLANK-LINE`); they are in the first group of
  `CHECK-DECL-ORDER`. A `##` doc before a re-export is `PARSE-DETACHED-DOC`:
  the doc stays on the original.
- An exported signature may still mention a private type that importers cannot
  name, as before.

#### Constants

`export LIMIT = 100` makes a constant visible, and
`import {LIMIT} from "limits"` brings it in by name, like any other exported
name (it can be renamed to another constant name:
`import {LIMIT as MAX_ITEMS} from "limits"`). A constant is read by its bare
name, wherever an expression can stand, in the file that declares it and in a
file that imports it by name. An importer that has the module under an alias
reads an exported constant as `Limits.LIMIT`, like an exported function:
`Limits.NAMES.size`, `Limits.CONFIG.with(port: 81)` and `"#{Limits.LIMIT}"` work
as for a bare constant. A private constant, and a name the module does not
export, are `CHECK-IMPORT-NAME` at the member, with a `did you mean` help for a
near export, as for a function. A constant is no function and no type:
`Limits.LIMIT()` and `x: Limits.LIMIT` are `CHECK-TYPE-MISMATCH`. An imported
name must not collide with a constant of the file, and two constants of the same
name are `CHECK-REDEFINED-NAME`, as for any declaration. An unexported constant
is private: importing it is `CHECK-IMPORT-NAME`. A constant is never changed, so
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
packages only from `deps/` beside `agentica.toml`, which `agentica install`
writes (see below). A build never runs git and never uses the network, and it
never reads the package cache. `agentica add` and `agentica update` write the
lock (see below).

```toml
name = "notes"

[dependencies]
sqlite = { git = "https://github.com/owner/sqlite-ac", tag = "v1.2.0" }
json5 = { git = "https://gitlab.com/someone/json5", ref = "3f2a9c1" }
postgres = { git = "https://github.com/owner/packages", tag = "postgres-0.1.0", subdir = "postgres" }

[style]
max_line_width = 119
```

```ruby
import Sqlite from "pkg/sqlite/db"
```

- The manifest knows `name`, `[dependencies]`, `[native]`, `[style]` and
  `[workspace]` (below). An unknown key at any level, a value of the wrong
  form, or a TOML syntax error is `PKG-MANIFEST-INVALID`. `name` is optional
  and follows the rule of a dependency name below. `max_line_width` is an
  integer of 1 or more. `blank_line_after_end` is a boolean, false by default;
  any other value is `PKG-MANIFEST-INVALID` at `style.blank_line_after_end`.
- With `blank_line_after_end = true`, `agentica check` and every command that
  checks a program require an empty line (only spaces or tabs) after each line
  whose code is only `end`, in the files below the folder of that manifest
  that have no `agentica.toml` of their own nearer. A file outside that folder
  (`../shared/util.agc`), `std/`, a package, the `agc_libs/` of the folder, any
  other `pkg/` library folder (and what its files import by a relative path),
  and a file in a folder with its own manifest are not checked, even when the
  root imports them. A link counts where its real path is. The key of a nested
  manifest is not honored: a build reads only the manifest of its root. A
  trailing `# comment` on the `end` line is allowed, but a comment line after
  the `end` is not an empty line, so it needs one too, also before a closing
  `end` and at the end of the file. A line that breaks it is
  `CHECK-BLANK-LINE-AFTER-END`, at the `end`, reported after the type check
  passes. These next lines need no empty line: one that starts with
  `end`, `else`, `elsif`, `)`, `]` or `}`, and one that starts with `.name`
  (the lexer joins it to the `end`). The end of the file needs none either: the
  last `end` may have no final line break, one, or extra empty lines, in a
  module file and in the main file. An `end` with more on its line (`end.size`,
  `end)`) is not covered, and an `end` in a string, a heredoc or a comment
  never counts.
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
  `ref` (7 to 64 lowercase hex digits of a commit), and optionally `subdir`
  (next item). Only git sources exist: a `path`, a branch, a version range or
  another key is `PKG-MANIFEST-INVALID`, at the key path
  (`dependencies.sqlite.path`).
- `subdir` says that the package is a folder of the repository, not the
  repository itself, so one repository can hold many packages. It is a relative
  path of plain folder names joined by `/` (`"postgres"`, `"libs/sql"`). Each
  name has only letters, digits, `.`, `_` and `-`, and is not empty, hidden (so
  no `.` or `..`), `agc_libs` (in any case), ending in `.` or a Windows device
  name such as `con`; the whole path has at most 128 characters. Anything else,
  a leading or final `/` and a value that is not text included, is
  `PKG-MANIFEST-INVALID` at `dependencies.<name>.subdir`. The folder is the
  package: its files are the files of the package, its own `agentica.toml` is
  the manifest of the package, and relative imports cannot leave it
  (`CHECK-IMPORT-PATH`), as they cannot leave the repository of a package
  without `subdir`. A project installs only the folders it declares. A package
  that needs another folder of its own repository declares it like any other
  dependency (the same `git`, its own `subdir` and pin). Versions use prefixed
  tags (`postgres-0.1.0`).
- A repository of packages can be a workspace, like an npm workspace. Its root
  `agentica.toml` has a `[workspace]` table with `repository`, the `git` URL of
  the repository (the rules of a dependency's `git`), and `members`, a
  non-empty list of the folders of its packages. A member is written like a
  `subdir`, appears once, and holds its own `agentica.toml`. An unknown key, a
  missing key, a bad value or a member that fails these rules is
  `PKG-MANIFEST-INVALID` at `workspace.repository`, `workspace.members` or
  `workspace.members[n]`.
- A project is in a workspace when its folder (the folder of its nearest
  manifest) is the root of the workspace or a member. The root is the nearest
  `agentica.toml`, going up from the project folder, that has a `[workspace]`
  table. The project is in it when its folder is that root, or its path from
  the root is one of the `members`; only then is the table checked in full. A
  table that does not list the project, even a broken one, is the same as no
  table for it (a project that is the root itself reports a broken table). The
  search stops at the root of the file system, and a project whose folder is
  directly inside a folder named `deps` is a package of `deps/` and is never in
  a workspace. A manifest above the project that cannot be read or parsed is
  skipped. The `[workspace]` table of a package that is in the cache
  or in `deps/` is never read, so it is not checked.
- In a workspace, a dependency whose `git` is the `repository` (with or without
  a `.git` at the end) and whose `subdir` is a member is a workspace member,
  wherever the manifest that declares it is: the project's own or a package's.
  It keeps its `git`, `tag` or `ref` and `subdir` in the manifest, which is what
  a user outside the repository resolves, but it is neither fetched nor copied
  to `deps/`: the build reads its files from the member's folder, with no hash
  check, so an edit there is seen by the next build. The folder's own
  `agentica.toml` declares its dependencies as for any package, and its files
  keep the rules of a package (relative imports stay inside the folder). The
  lock entry of a member has `workspace = true` in place of `commit` and
  `hash`, and needs `subdir`; a `commit` or a `hash` with it, a `workspace`
  that is not `true` or a missing `subdir` is `PKG-LOCK-INVALID`. The lock must
  say the same as the workspace: a member locked as a fetched package, or a
  package locked as a member for a project that is not in the workspace, is
  `PKG-LOCK-STALE` at the project's manifest and `PKG-SOURCE-CONFLICT` at a
  package's. `install`, `add` and `update` remove a `deps/` folder that has
  the name of a member. Outside the repository nothing changes: the same
  dependency is fetched and locked with a commit and a hash.
- The import is `pkg/<name>/<module path>`, with no extension:
  `"pkg/sqlite/util/json"` loads `util/json.agc` of the package. `pkg/sqlite`
  with no module is `CHECK-IMPORT-PATH`. A name that the manifest of the
  importing file declares is a package, and it comes first: it shadows a library
  of the same name in the `pkg/` roots, `agc_libs/` included. Its files come
  only from `deps/<name>/` beside `agentica.toml`, one flat folder for each
  locked package, including the ones that packages import (the lock is one list,
  so one folder for each name). A name that is not declared is the `pkg/`
  library search above, unchanged. Since the prefix is `pkg/`, a package import
  never clashes with a local file or folder.
- Which manifest decides: the manifest of the project for the files of the
  project (and of the `pkg/` libraries it loads), the manifest of the package
  itself, read from its folder in `deps/`, for the files of a package. A
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
  each name (a name twice is `PKG-LOCK-INVALID`): `name`, `git`, `subdir` (only
  when the dependency has one), `tag` or `ref` (as in the manifest), `commit`
  (40 or 64 lowercase hex digits; it starts with the `ref`) and `hash`
  (`sha256:` and 64 lowercase hex digits), or `workspace = true` for a member
  of the workspace of the project. A bad lock is `PKG-LOCK-INVALID`, a
  bad `subdir` too, at `package[n].subdir`; a lock with no `subdir` reads as
  before. Every dependency of the manifest must be in the lock with the same
  `git` (with or without a `.git` at the end), the same `subdir` (or none) and
  the same `tag` or `ref`, or the lock is `PKG-LOCK-STALE`. The same check runs
  on the manifest of every locked package that is in `deps/`: a name the lock
  lacks is `PKG-LOCK-STALE`, and a name with another source than the lock is
  `PKG-SOURCE-CONFLICT`; both are reported at `dependencies.<name>` of that
  manifest. One name with two different sources anywhere in the
  tree (the project and a package, or two packages) is `PKG-SOURCE-CONFLICT`;
  the source is the `git`, the `subdir` and the pin; there are no versions to
  compare and no ranges to solve. Both checks run once for every command that
  loads code, before any file is read, so a conflict is reported whether or not
  an import reaches that package. A package that is not in `deps/`, one whose
  folder cannot be listed and one whose manifest is not a regular file are left
  for the import that loads them (so a conflict in them shows only then). A
  manifest that is a symbolic link, a folder or a pipe is `PKG-SYMLINK` and is
  never opened. The build never writes the lock.
- Manifest and lock errors have no source span. They name the file and the key
  path, such as `dependencies.sqlite.git` or `package[1].hash` (`[n]` counts
  from 0); a TOML syntax error has the line and column instead. In the plain
  form the key path replaces the source lines (`= key: ...`); in `--ai` it is
  the `key:` line; in `--json` it is `key_path`, and `range` is the start of the
  file. A failure about the file as a whole (a lock that is missing, a file that
  cannot be read) has no key: the plain and `--ai` forms show the file name
  alone, and `--json` has no `key_path` and a `range` at line 0, column 0.
- The package cache is a download cache, so that a commit is never fetched
  twice; `install`, `add` and `update` fill it and write `deps/` from it. It
  holds one folder for each commit:
  `$XDG_CACHE_HOME/agentica/pkg/<host>/<owner>/<repo>/<commit>/`, from the `git`
  URL of the lock. Two names for one repository are two packages, each with its
  own lock entry. A package with a `subdir` has the folder `<commit>@<subdir>`
  instead, each `/` of the `subdir` written `@` (a `subdir` never holds one),
  and that folder holds only the files of the `subdir` folder. Two folders of
  one repository and commit are two cache folders, and a change in another
  folder of the repository changes neither. `XDG_CACHE_HOME` counts when it is
  absolute, else `~/.cache` is used (no cache when `HOME` is unset too). On
  Windows the folder is `%LOCALAPPDATA%/agentica/cache/pkg/` (no cache when it
  is unset or relative; `XDG_CACHE_HOME` and `HOME` are not read). A declared
  package that is not in `deps/` is `CHECK-IMPORT-PACKAGE`, whose help says to
  run `agentica install`.
- `agentica install` fills the cache from the lock, writes `deps/` (below) and
  never writes the lock. It
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
  files the hash covers and the `agentica.toml` at the root are copied. With a
  `subdir`, the tree read is that folder of the commit: the fetch is the same,
  but nothing outside the folder is listed, read or written; a `subdir` that the
  commit lacks, or that is a file, a symbolic link or a submodule there, is
  `PKG-FETCH` at `package[n].subdir`. A symbolic link or submodule named `*.agc`
  or `agentica.toml`, or in `native/`, is `PKG-SYMLINK`, two copied paths that
  differ only in case are `PKG-PATH-COLLISION` (only case: not Unicode
  normalisation or Windows device names, which the hash still catches), a file
  over 1 MiB, or all files over 16 MiB, is `PKG-FETCH` naming the file, and
  the hash of the copy must be the locked hash (`PKG-HASH-MISMATCH`). The copy
  is built in a hidden `.tmp-*` folder of the cache root and renamed into place
  in one step (a killed install may leave that folder; delete it). git may ask
  for a password on a terminal; each read of its output has a 5 minute
  deadline. A git that cannot start or fails, a missing tag or commit, an unsafe
  path and a cache that cannot be written are `PKG-FETCH`. These failures name
  `agentica.lock` and the key of the entry (`package[1].tag`,
  `package[1].hash`; `package[1].git` when git itself failed; `package[1]` for
  the others). The first failure stops the command. When every package is in
  the cache, the manifest of each is checked against the lock
  (`PKG-LOCK-STALE`, `PKG-SOURCE-CONFLICT`), and only then is `deps/` written,
  so a cache or a manifest that fails those checks writes nothing there. A
  failure in the middle of the copy (a full disk, say) leaves `deps/` partly
  updated: each package folder is either the old one or the new one, and
  `agentica install` finishes the rest. The
  answer is `fetched NAME@VERSION`, `in the cache NAME@VERSION` or, for a
  workspace member, `in the workspace NAME@workspace` for each package; with
  no package but host artifacts ready, `1 native artifact ready` (or `N
  native artifacts ready`); else `nothing to install`. The command starts
  git even under
  `--deny-run`, which only limits programs.
- `agentica add NAME URL --tag TAG` (or `--ref COMMIT`, and `--subdir DIR`) and
  `agentica update [NAME]` write the lock; they are the only commands that do.
  Both work on the project of the working folder (no manifest is
  `PKG-MANIFEST-MISSING`), read the lock without checking it against the
  manifest, and fetch as `install` does (the same `git`, the same checks, the
  same cache), so they may start `git` and need the network for what is new. The
  lock they write has one entry for every package of the build and no other: the
  dependencies of the manifest, then those in the manifest of each package they
  settle, and so on; one name with two sources is `PKG-SOURCE-CONFLICT`, at the
  manifest that asked second. A locked entry with the source the manifest names
  is kept, and only its files are put in the cache if they are missing; anything
  else is fetched, and the commit and the hash are read from what git gave; a
  fetch error of such a pin names the manifest that asks for it and
  `dependencies.<name>.git` (or `.tag`, `.ref`, `.subdir`), the same codes as
  `install`. Nothing is written when a step before the lock fails, and the lock
  is written before the manifest and `deps/` after both: if `deps/` cannot be
  written, `agentica install` writes the locked packages into it (it removes
  no folder). A file that cannot
  be written is `PKG-WRITE`; each file is written to a new file beside it that
  is renamed into place, and the old one is put back if a step fails. A
  manifest that changed while the packages were fetched is not overwritten
  (`PKG-WRITE`, nothing written), and a manifest that cannot be written after
  the lock was says so in the help: `agentica update` makes the lock match it
  again. The lock is sorted by name (just `version = 1`
  when it is empty), in the layout above, so it has the same bytes when nothing
  changed.
  - `add` takes the local name, the `https://` URL and `--tag` or `--ref`, in
    that order, then `--subdir DIR` if the package is a folder of the
    repository. The commit of `--ref` is the whole id (40 or, for SHA-256, 64
    digits), since git fetches no abbreviation (a package whose manifest asks
    for a part of an id that the lock lacks is `PKG-FETCH` at
    `dependencies.<name>.ref` of that manifest). The tag of a SHA-1 repository
    is fetched; a SHA-256 repository takes `--ref`. A name, URL, tag or commit
    that the manifest would refuse, or any other words, are a usage error (exit
    code 2). A name that is a dependency already is `PKG-DEPENDENCY-EXISTS`. The
    manifest gets one new line, `NAME = { git = "URL", tag = "TAG" }` (with
    `subdir = "DIR"` last when asked), after the last entry of `[dependencies]`
    (or in a new `[dependencies]` table at the end of the file); no other byte
    changes, so comments, blank lines, the order of the keys and the line
    endings stay. The new text is read as a manifest before it is saved, and a
    layout the edit cannot handle (the table written as `dependencies = {}`,
    say) is `PKG-MANIFEST-EDIT`: write the line by hand.
  - `update` takes no word or the name of a dependency of the manifest (else
    `PKG-DEPENDENCY-UNKNOWN`). It fetches the tag pins again, all of them or
    the one named, and takes the commit they point to now, so a moved tag is
    the new commit and hash in the lock. A pin that is a commit is not fetched
    again. It also fixes a lock that is missing or stale (a manifest edited by
    hand) and drops the packages that nothing asks for any more. A project with
    no dependency and no lock gets none.
  - Both refresh `deps/` as `install` writes it, for every package of the new
    lock, and remove the folder of a package that the old lock had and the new
    one lacks. If `deps/` cannot be written, the lock is saved already and the
    help says to run `agentica install` to write the locked packages into
    `deps/`.
  - A workspace member is locked with no fetch, whether or not its tag exists,
    and its manifest is read from its folder; its version is `workspace`.
  - The answer lists `added NAME@VERSION`, `updated NAME@VERSION` (another
    commit or pin) and `removed NAME`, one per line, or `nothing to update`;
    a package with a `subdir` adds ` (folder DIR)` after `NAME@VERSION`. With
    `--json` a success prints `{"ok":true}`.
- `deps/` holds the files of each locked package that is not a workspace
  member, direct or not, in
  `deps/<name>/` beside `agentica.toml`, like `mix deps.get`: the files the hash
  covers and the `agentica.toml` of the package (for a `subdir`, of that folder
  only: the cache holds nothing else). `install`, `add` and `update` copy them
  from the cache into a hidden `.tmp-*` folder of `deps/`, hash the copy against
  the lock (`PKG-HASH-MISMATCH` at `package[n].hash`), and swap it for the old
  `deps/<name>/` in two renames, so the old folder stays if a step fails. The
  folder of a locked package is replaced when it is not a real folder (a link,
  say) or its `.agc` files differ from the lock (an edited, added or missing
  file), and running `install` again is how to restore it. A real folder whose
  `.agc` files have the locked hash is left as it is, so its files keep their
  times, and so do other files in it (a note, say). Hidden `.tmp-*` and `.old-*`
  entries of `deps/` left by a killed command are removed first when they are
  older than ten minutes (a younger one may belong to a command that is still
  running), judged by their own time and never through a link. The new folder
  has the ordinary mode (not the private one of the staging folder). A
  `PKG-WRITE` that could not put an old folder back names the `.old-*` folder
  that holds it; `install` writes the package again from the cache, and the next
  command removes that folder once it is older than ten minutes. A folder of a
  package that `update` or `add` dropped from the lock is moved aside and
  removed without following links (a link is removed as a link). Nothing else in
  `deps/` is touched, and the tool writes no `.gitignore` there: a project may
  commit `deps/` or ignore it. `deps/` itself must be a real folder: a symbolic
  link is `PKG-SYMLINK`, and a file or a write that fails is `PKG-WRITE` (the
  file and no key); nothing is written through a link. `agc_libs/` is not
  touched: it stays for the libraries of the `pkg/` search. When `agentica test`
  and `agentica symbol` walk a folder, they skip the `deps/` beside an
  `agentica.toml`: installed packages are not the tests or modules of the
  project (a path that names a folder of `deps/` reads it).
- A build reads `deps/<name>/` of a declared name and hashes it against the
  lock: one that differs (an edited file, an added `.agc` file, a missing one)
  is `PKG-HASH-MISMATCH` at the import, and nothing else is used instead; a
  folder that is not there, or an entry that is not a folder, is
  `CHECK-IMPORT-PACKAGE`. The stored names of the files do not depend on where
  they were read. A link to a folder at `deps/<name>` is followed when a build
  reads it (the hash covers what is behind it); `install` replaces the link
  itself. A name the project does not declare is the `pkg/` library search.
- The hash covers the `.agc` files of the package folder and every file of its
  `native/` folder at the root, but dotfiles, `Thumbs.db` and `desktop.ini`
  (for a `subdir`, that folder of the repository, so a change in another folder
  does not change it).
  Their paths are relative to it, written with `/`, in bytewise order; for each
  file, its path, a zero byte, its size in decimal, a zero byte and its bytes.
  The hash is `sha256:` and the SHA-256 of that stream in hex (`Crypto.sha256`).
  Hidden folders (any depth), `agc_libs/` at the root and files that are not
  `.agc` (outside `native/`) are left out (`.agc`, `agc_libs` and `native` are
  compared without regard to case, so `x.AGC` is hashed and `AGC_LIBS/` is left
  out on every system). The `agentica.toml` of a package is left out too, so it
  can only choose among the names of the lock, except when `native/` holds a
  file that is not `.agc` or the manifest has a top-level `[native]` table: it
  then decides
  which file is opened, so it is added to the stream with the path
  `agentica.toml`, and the hash of any other package is unchanged. The first
  time a build loads a package, it hashes the folder of `deps/` and compares
  the result with the lock (`PKG-HASH-MISMATCH`); a symbolic link named
  `*.agc`, a link named `native` at the root, or any link in `native/`, is
  `PKG-SYMLINK`. A package that no import reaches is not hashed. A build
  changes nothing in `deps/`. The bytecode cache of `agentica FILE.agc` hashes
  only the files a program reads, so a new unused file in a `deps/` folder is
  caught by `check` or `--no-cache`, not by a cached run. A committed `deps/`
  needs no `install` to build.
- Native libraries. A package declares them in its own manifest, one table
  `[native.NAME]` for each library, where `NAME` follows the rule of a
  dependency name and is what `extern "NAME"` writes in the files of the
  package. Under it, one key for each system the library exists on: `linux`,
  `macos` or `windows` (any other key is `PKG-MANIFEST-INVALID`; a macOS file
  is a universal binary, and `linux` is any Linux the VM supports). Its value
  is an inline table with exactly one of `file`, a path in the `native/` folder
  of the package (plain folder names, as a `subdir`; the files of `native/` are
  copied and hashed with the package, so the lock covers all systems, and each
  is at most 1 MiB), `system`, a name for the system loader (no `/`, `\`
  or `:`; at most 128 characters) or an absolute path, or a list of them (1 to
  16), for a library the system has (`winsqlite3.dll`), or a download
  `{ url, sha256, member }` (an https URL, or http to 127.0.0.1 or [::1]; 64
  lowercase hex digits; a safe relative TAR or ZIP member): the archive is
  verified by its SHA-256 and the member is cached, pinned per system in
  `[[native-artifact]]` and fetched by `install` and `update` for the host
  only. Another key, both shapes or a half-written download are
  `PKG-MANIFEST-INVALID` at the key path (`native.sqlite3.linux.file`).
  ```toml
  [native.sqlite3]
  linux = { system = "libsqlite3.so.0" }
  macos = { system = "libsqlite3.dylib" }
  windows = { file = "native/windows/sqlite3.dll" }
  ```
  - In a file of the package, `extern "NAME"` with a `NAME` that its manifest
    declares means the entry of the running system, chosen when the file is
    compiled: a `file` becomes the absolute path of the file in
    `deps/<package>/`, which the VM opens as it opens any absolute library (no
    search, and `LD_LIBRARY_PATH` plays no part); a `system` entry stays as
    written. A `NAME` it does not declare stays as written. Nothing else in the
    program changes, and `--deny-native` and `--sandbox` refuse the program as
    for any `extern`.
  - A `system` list names candidates in order of preference, for a library
    that lives at different places on one system, such as Homebrew's on macOS:
    ```toml
    [native.libpq]
    macos = { system = ["libpq.5.dylib", "/opt/homebrew/lib/libpq.5.dylib"] }
    ```
    When the file is compiled, the first absolute path that is a file is
    chosen, else the first bare name, else the first path (the program then
    fails to open it, as `extern "/missing.so"` does). A macOS path such as
    `/usr/lib/libz.dylib` lives in the dyld shared cache, not on disk, so it
    does not count as existing: list it knowingly, before or after a path
    that does. The choice is the
    machine's: the manifest is hashed as written, the lock holds no choice,
    and the bytecode cache misses when a candidate appears or goes away. A
    relative path (`lib/x.so`, `C:x.dll`), an empty list or an item that is
    not a string is `PKG-MANIFEST-INVALID` at the key path of the item
    (`native.libpq.macos.system[1]`). The working directory is never searched.
  - A package that declares the library but has no entry for the running
    system is `PKG-NATIVE-PLATFORM`, and a `file` that the package lacks is
    `PKG-NATIVE-MISSING`, when a file of the package that is compiled uses
    that `NAME`. Both name the `agentica.toml` of the package and the key path
    (`native.NAME`, `native.NAME.linux.file`), so a package works on the
    systems it names and is refused only where it is used on another.
  - A library that is a `file` is checked by the hash of the package when the
    package is first loaded, so a changed file is `PKG-HASH-MISMATCH`. The
    entry of the bytecode cache of `agentica FILE.agc` also holds the digest of
    the manifest and of every file of `native/` (a library may load a sibling),
    so a change to one is a cache miss and the build runs again. The bytecode
    that `agentica compile` writes names the file by its path on this machine,
    and `agentica run -- file.agcb` opens whatever is at that path, with no
    hash check.
  - The manifest of the project has the same `[native]` table, used by the
    project's own files, with the files relative to the project folder (a
    package author's tests run with the package as the project). The project's
    files are not hashed. A workspace member is read from its folder with no
    hash, as its `.agc` files are.
- The stored name of a package file in the `.agcb` file is
  `pkg/<name>@<tag>/path/in/package.agc`, such as `pkg/sqlite@v1.2.0/db.agc`
  (the path is from the package folder, without the `subdir`); for a package
  pinned by a `ref` it is `pkg/<name>@<first 12 digits of the commit>/...`. So
  the bytes do not depend on the folder of the project. Diagnostics inside a
  package name the real file in `deps/`.

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
  `JSON.decode(json, T)`. A `DateTime` becomes its string, an integer stays an
  integer and a float stays a float, and `inf` or `nan` is an error.
- `Toml.get(value: Value, path: String) -> Result[Value]` reads a dotted path of
  keys; a segment of plain digits (no sign, no leading zero) indexes an array.

#### BDD steps (`std/bdd`)

`std/bdd` is the step API of `agentica test`, written in Agentica. Most `BDD.*`
functions take the context first and return it; see
[`library/testing/bdd.md`](../../site/content/library/testing/bdd.md) and
[`bdd.md`](../bdd.md). `BDD.Context` can be named but not built: a context
exists only inside a step, so use the context that a call returns. The modules
`std/bdd/gherkin`, `std/bdd/match`, `std/bdd/tags`, `std/test/report` and
`std/test/runner` are internal to `agentica test` and unsupported.

[agentica-link-1]: ../../site/content/library/data-structures/queue.md
[agentica-link-2]: ../../site/content/library/text-and-data/binary.md
[agentica-link-3]: ../../site/content/library/text-and-data/toml.md
