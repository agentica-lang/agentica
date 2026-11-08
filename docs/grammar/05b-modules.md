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

#### Unused imports

An import alias that its file never uses is `CHECK-UNUSED-IMPORT`, located at
the alias, with the help `remove import Alias from "path"`. A use is any place
that writes a name with the alias first: a call, a `&function` value, a type
(in an annotation, a signature, a field or a block parameter), a construction,
an enum constructor or a pattern, an enum type and a constant (`Alias.NAME`),
and the alias of a re-export (`export Alias.name`). A regex literal counts as a
use of the `std/regex` import and a `<<~EAG` template as a use of the `std/eag`
import, since each needs it in some form. A use inside a function that nothing
calls counts: the rule is about the text of the file. An import
has no effect besides its names, so removing an unused one never changes what a
program does. The rule holds for every file, `pkg/` libraries and `std/`
included: a package with a stray import fails the build of every program that
uses it.

An alias written without its member (`u: User`, `User(name: "Ana")`, or
`Domain.Some(1)` with `Domain` an alias) is `CHECK-IMPORT-NAME` at the alias,
with the help `write User.<Type>`, not an unused import. A file with a call
`Alias.name` whose first part is no alias, no name of the file and no builtin
module (a mistyped alias) gets `CHECK-UNKNOWN-NAME` from the checker instead.
The first alias never used is reported, imports in source order and files in
link order (the root first), after that file's own resolve errors. Any command
that builds or checks a program (`check`, `run`, `compile`, `test`) reports it.
The query commands (`type-at`, `refs`, `symbol`, `--partial`) do not report it
in the file they are asked about, since an editor adds an import before it
writes the first use; the files that file imports keep the rule.

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
names `HttpWire`, `LogRegistry` and `RegexEngine` are reserved too, so they can
be neither an alias nor an imported name. A name that the module does not export, or that is
private, is `CHECK-IMPORT-NAME` at the name, with a `did you mean` help over the
exports only. These checks run when the file is loaded, so they are reported at
the import, before any use of the name. A name used as the wrong kind (an
imported struct as the enum of a pattern) is `CHECK-TYPE-MISMATCH`, as with an
alias.

Unused names of an import list are not reported.

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
name are `CHECK-REDEFINED-NAME`, as for any declaration. A constant is never
changed, so there is no shared state between modules: the value an importer
reads is the value the declaring file computed.

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

- The manifest knows `name`, `[dependencies]`, `[native]`, `[style]`,
  `[workspace]` (below) and `[tool]`, a table of tables (`[tool.NAME]`) that
  other tools own: Agentica reads nothing inside them and checks only that
  `tool` and each `tool.NAME` is a table. Outside `[tool]`, an unknown key at
  any level, a value of the wrong form, or a TOML syntax error is
  `PKG-MANIFEST-INVALID`, as is a `tool` that is not a table of tables. `name`
  is optional and follows the rule of a dependency name below.
  `max_line_width` is an integer of 1 or more. `blank_line_after_end` is a
  boolean, false by default; any other value is `PKG-MANIFEST-INVALID` at `style.blank_line_after_end`.
- With `max_line_width = N`, `agentica check` and every command that checks a
  program report a line of more than N characters (Unicode code points; a CR
  before the line feed does not count; comments count) as
  `CHECK-LINE-TOO-LONG`, from its first character past N to its end, after the
  type check passes. It covers the same files as `blank_line_after_end`
  (below), and in a file it comes before that rule. `agentica fmt` lays out in
  N columns (119 without the key) and, with `blank_line_after_end`, adds the
  empty lines that rule asks for.
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
  (next item), or a `path` instead of all of those (the item after the next).
  A branch, a version range or another key is `PKG-MANIFEST-INVALID`, at the
  key path (`dependencies.sqlite.branch`). `override = true` is the only other
  key (the item on `override`).
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
- `path = "../sqlite"` is a dependency on a folder of this machine, as in Mix:
  relative to the folder of the manifest, or absolute; not empty, with no
  control character, at most 1024 characters. It excludes `git`, `tag`, `ref`
  and `subdir` (`PKG-MANIFEST-INVALID` at `dependencies.<name>`), and the
  folder must hold an `agentica.toml` (else `PKG-MANIFEST-INVALID` at
  `dependencies.<name>.path`, as for a workspace member). Like a workspace
  member it is neither fetched, cached nor copied to `deps/`: the build reads
  the files from the folder, with no hash check, so an edit there is seen by
  the next build, and the `agentica.toml` of the folder declares its
  dependencies as for any package. Its lock entry has `name` and `path` as
  written, and no `git`, `commit` or `hash` (any of them is `PKG-LOCK-INVALID`).
  Its answer is `in place NAME@path` from `install` and `added NAME@path` from
  `add` and `update`. A package can be published, so a `path` is allowed only in
  the manifest of the root project: in the manifest of a package (fetched, or a
  workspace member) it is `PKG-ROOT-ONLY` at `dependencies.<name>.path`.
- `override = true` in a dependency of the root manifest makes its source win
  for that name everywhere in the tree, with any of the sources above (a `path`
  too, to try a local copy of a transitive dependency). A package that asks for
  another source of the name is not a `PKG-SOURCE-CONFLICT`, and the source it
  asks for is never fetched or compared; the files of the name are the root's,
  for the project and for every package. Only the root manifest may say it: in
  the manifest of a package it is `PKG-ROOT-ONLY` at
  `dependencies.<name>.override`, and `false` is the same as leaving it out. The
  lock entry has `override = true` after its other keys; the root manifest and
  the lock must agree (`PKG-LOCK-STALE` at the manifest), and the lock key must
  be `true` (else `PKG-LOCK-INVALID` at `package[n].override`). `install`,
  `add` and `update` end their answer with one line for each overridden
  package, `overridden NAME@VERSION`, and `add` and `update` add
  `(another source asked by A, B)` when packages asked for another source.
  `PKG-SOURCE-CONFLICT` has a help that suggests `override = true` in the
  root manifest.
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
  (`sha256:` and 64 lowercase hex digits), `workspace = true` for a member
  of the workspace of the project, or `path` in place of the git source for a
  `path` dependency, then `override = true` for an overridden name. A bad lock
  is `PKG-LOCK-INVALID`, a bad `subdir` too, at `package[n].subdir`; a lock
  with no `subdir` reads as before. Every dependency of the manifest must be
  in the lock with the same `git` (with or without a `.git` at the end), the
  same `subdir` (or none) and the same `tag` or `ref`, or the same `path`, and
  the same `override`, or the lock is `PKG-LOCK-STALE`. The same check runs
  on the manifest of every locked package that is in `deps/`: a name the lock
  lacks is `PKG-LOCK-STALE`, and a name with another source than the lock is
  `PKG-SOURCE-CONFLICT`; both are reported at `dependencies.<name>` of that
  manifest. One name with two different sources anywhere in the
  tree (the project and a package, or two packages) is `PKG-SOURCE-CONFLICT`,
  unless the project overrides the name (the item on `override`);
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
  answer is `fetched NAME@VERSION`, `in the cache NAME@VERSION`, for a
  workspace member `in the workspace NAME@workspace` or, for a `path`,
  `in place NAME@path` for each package, then `overridden NAME@VERSION` for
  each overridden package; with no package but host artifacts ready,
  `1 native artifact ready` (or `N native artifacts ready`); else `nothing to
  install`. The command starts git even under `--deny-run`, which only limits
  programs.
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
  The hash is `sha256:` and the SHA-256 of that stream in hex
  (`OpenSSL.Digest.sha256`).
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
  `PKG-SYMLINK`, and a FIFO, socket or device named `*.agc` or in `native/`
  is `CHECK-IMPORT-IO`. A package that no import reaches is not hashed. A build
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
  - `build` is the one key of `[native.NAME]` that is not a system: the C
    sources of a native module (`extern module`), which the project, a
    workspace member, a `path` dependency and a fetched package build instead
    of using their system entry. A fetched package is never compiled in
    `deps/`: when a file first uses the library, the files its hash covers are
    read once and checked against the hash of its lock row
    (`PKG-HASH-MISMATCH` at `native.NAME.build`), and the files of `native/`
    among them are copied into a private build folder and compiled there. So
    the code that is built is the code of the locked commit: a file the hash
    leaves out (a dotfile, `Thumbs.db`) is not copied, and a header outside
    `native/` is not found. `check` never builds, but a copy that differs
    from the lock is still `PKG-HASH-MISMATCH` when the package is loaded.
    ```toml
    [native.stats]
    build = { sources = ["native/stats.c"], defines = ["NDEBUG"], libs = ["m"] }
    ```
    `sources` (1 to 256) are `.c` files in `native/`, as a `file` is;
    `defines` (at most 64) are `NAME` or `NAME=VALUE`, a C name and a value of
    letters, digits and `_ . + -`; `libs` (at most 32) are names for `-l`, of
    the same letters, not starting with `-`. Anything else is
    `PKG-MANIFEST-INVALID` at the key path of the item
    (`native.stats.build.defines[0]`), and so is a Windows device name (`con`,
    `nul`, `com1`) as the name of a library to build (at `native.NAME`). A
    source that is not a regular file of `native/` is `PKG-NATIVE-MISSING` at
    its item. For a package read in place, every entry of `native/` is read,
    hidden ones included, when a file first uses the library; a `native` that
    is not a folder, a link, a pipe or a device in it, or more than 4096 files
    or 1024 folders, is `PKG-NATIVE-BUILD` at `native.NAME.build`. A fetched
    package reads only the files its hash covers, within the limits of a
    fetch (1 MiB a file, 16 MiB in all; more is `PKG-NATIVE-BUILD` there), so
    its hidden files are in neither the copy nor the key.
  - A run, `compile`, `test` and `install` run the user's C compiler on the
    C of `native/`; `check` and the queries never do. Under any
    `--deny-*` flag or `--sandbox`, in front of `test` or after it, the VM
    refuses native code, so no compiler starts: a run or a test file that
    uses the library is `RUNTIME-NATIVE-DENIED` (the bytecode cache keeps
    such programs apart, so a hit and a miss agree), and `compile`, whose
    output may run without the flag, is `PKG-NATIVE-BUILD`. A run, `compile`
    and `test` build a library when a file of the program first uses it, so
    a library that no file uses is never built; `install` builds them all
    for the project, its members and its `path` dependencies, and none of a
    fetched package, so installing one needs no C compiler.
    The compiler is the words of `CC` (split at spaces, with no quoting), else
    `cc` (`gcc` on Windows), started with an argument list and no shell, in
    the package folder. Every build gets `-std=c11 -O2 -fvisibility=hidden`,
    the folder of the `agentica_native.h` that the binary carries, the defines
    (`-DNAME=VALUE`, one argument each) and the system's flags: Linux
    `-fPIC -shared -Wl,-z,defs`, macOS `-dynamiclib` with the install name
    `@rpath/libNAME.dylib` (the host architecture only; an undefined symbol
    is a link error there by default), Windows `-shared -static-libgcc`; then
    the sources and the `-l` libraries. The manifest names no compiler and no
    other flag.
  - The library goes to `<package cache>/native-build/<key>/libNAME.so`
    (`.dylib`, `NAME.dll`), never into the package. The key is the SHA-256 of
    the files of `native/`, the table, the compiler words, the first lines of
    its `--version` and `-dumpmachine`, the header, and `CPATH`,
    `C_INCLUDE_PATH`, `CPLUS_INCLUDE_PATH` and `LIBRARY_PATH`. Headers of your
    own must live under `native/`: system headers, installed libraries and
    the rest of the environment are not part of the key, so to build again
    after they change, remove the entry or change a file under `native/`. The
    files of `native/` are hashed again after the compile, and a change during
    it stores nothing (`PKG-NATIVE-BUILD`). The entry is made in a private
    folder and renamed into place with its receipt (the SHA-256 of the
    library); an entry or a `native-build` folder that is not private to the
    user, or a library that is not the one its receipt names, is
    `PKG-NATIVE-BUILD`, and so is a compiler that cannot start, fails or makes
    no library. Its standard error is printed as it is (the start of it in the
    message with `--json` and `--ai`), and a new build prints
    `built native NAME: PATH` on stderr. The bytecode cache of
    `agentica FILE.agc` watches, for each package that builds, every file of
    `native/` and its names (hidden ones too), the built libraries, `CC` and
    the four search variables, so an edit or a new file in `native/` builds
    again. A compiler replaced at the same path is seen only when the program
    is compiled again.
- The stored name of a package file in the `.agcb` file is
  `pkg/<name>@<tag>/path/in/package.agc`, such as `pkg/sqlite@v1.2.0/db.agc`
  (the path is from the package folder, without the `subdir`); for a package
  pinned by a `ref` it is `pkg/<name>@<first 12 digits of the commit>/...`. So
  the bytes do not depend on the folder of the project. Diagnostics inside a
  package name the real file in `deps/`.

**Decided against (packages).**

- Semver and a major-version rule, and a `v2` path segment (it clashes with
  folders in the repository): one name has one source, and two majors can be
  used under two names.
- `dev_dependencies`: there is one list of dependencies.
- `owner/repo/mod` as the import form (it clashes with local folders and needs
  an ambiguity rule) and `./` for relative imports: the form is
  `pkg/<name>/<module>`.
- Hashing only at install: every build hashes each package it loads, so a
  changed file of `deps/` is caught.
- A `files` list in the manifest: only `.agc` files and the files of `native/`
  are used and hashed.
- A `Json` value or typed decoding for `Toml.parse`: the result is the enum
  `Toml.Value`, which keeps the types of TOML and works with `case`.
