## 45. Packages

**Status:** Designed; it has no roadmap row of its own. On the path to the JIT
it comes after the native Windows and macOS builds (issue
[#344](https://github.com/sonic182/agentica/issues/344)) and before the FFI
([§40.5](40-native-code.md#405-order)). 45-0 (`std/toml`) and 45a (manifest,
lock and imports from the cache) are done. The owner answered the questions of
45.14 on 2026-10-20, and on the same day replaced the import form of 45.3 and
the versions of 45.7 with named git dependencies (issue
[#468](https://github.com/sonic182/agentica/issues/468)). Asked by the owner on
2026-10-15 ("Shall we plan this?").

Decided by the owner on 2026-10-15:

- `std/toml` comes first (45-0, 45.4).
- The manifest and the lock are TOML (45.5, 45.6).
- `Toml.parse` returns the recursive enum `Toml.Value` (45.4).

Decided by the owner on 2026-10-20 (#468), which replaces the `owner/repo/mod`
import form and semver with minimal version selection of 2026-10-15:

- A dependency has a local name, a git source and a pin: `sqlite = { git =
  "https://github.com/owner/sqlite-ac", tag = "v1.2.0" }`, with a `tag` or a
  `ref` (a commit) (45.5).
- The import is `pkg/<name>/<module path>`. The `pkg/` prefix already means
  "external library", and a declared dependency becomes the first root searched
  for its name (45.3).
- The lock pins each dependency to a commit and a content hash. There is no
  semver and no MVS: one name with two different sources in the tree is an error
  (45.6, 45.7).

The owner decided the questions of 45.14 on 2026-10-20. The rest is the design
that 45a and the later phases build.

### 45.1 Today

Imports take a path. `import Models from "models"` loads `models.agc` next to
the importing file ([`05b-modules.md`](../grammar/05b-modules.md), line 5). A
path that starts with `pkg/` searches library roots (05b, line 26): `agc_libs/`
beside the root program, the roots in `AGENTICA_PATH`, the user data directory
`$XDG_DATA_HOME/agentica/lib/`, and two system directories. The first file
found wins, and a symlink must stay inside its root (05b, line 28).

That is all there is. There is no manifest, no lock, no version and no
download. A library is a folder that someone copies by hand. A library cannot
find its own dependencies, because `agc_libs/` is searched only beside the root
program, never beside a dependency (05b, line 26).

Two parts of the design already fit packages. The unused-import rule of §26 has
no exception for `pkg/` libraries
([`26-strict-diagnostics.md`](26-strict-diagnostics.md), line 156), so packages
get it too. The `.agcb` file stores project source paths relative to the entry
file's folder (§18.3), which PR #273 landed. Package files are
stored differently (45.8).

### 45.2 Goals

- **Reproducible builds.** The same manifest and lock give the same source
  bytes. Every package file is checked by a hash.
- **No code runs at install.** Installing a package only copies files. A
  package has no build script, no install hook and no post-install step. npm
  runs lifecycle scripts, and pip has run `setup.py` at install, so both let a
  package run code when it is installed. This design does not.
- **One import form.** A package has one local name and one way to import it,
  `pkg/<name>/mod`. The name does not depend on the URL.
- **Offline after one fetch.** Once a package is in the cache or vendored, a
  build needs no network.
- **Hermetic tests.** A local git repository can stand in for the remote, so
  the tests need no network (45.11).

Not goals in v1: a central registry, a version solver and publishing commands.
See 45.13.

### 45.3 Import form

Decided by the owner on 2026-10-20 (#468), in place of the `owner/repo/mod` form
of 2026-10-15:

- **`pkg/<name>/<module path>`.** `import Sqlite from "pkg/sqlite/db"` loads
  `db.agc` at the root of the package that the manifest calls `sqlite`. The part
  after the name is a path inside the repository. It uses forward slashes, has
  no extension, and each part follows the rules of 05b. `"pkg/sqlite/util/json"`
  loads `util/json.agc`. `pkg/sqlite` with no module is `CHECK-IMPORT-PATH`.
- **The name is local.** It is the key of the dependency in the manifest (45.5).
  It is decoupled from the URL: moving a repository changes only the `git` line,
  and no import changes. A name is a lowercase letter followed by lowercase
  letters, digits, `_` and `-`, at most 64 characters.
- **A declared name comes first.** A name declared in the manifest of the
  importing module is the first root searched for `pkg/<name>`: the package at
  the locked commit in the cache. It shadows a folder of the same name in
  `agc_libs/`, `AGENTICA_PATH` or the user root, and the search of those roots
  does not run for it, so a missing module of a declared package is
  `CHECK-IMPORT-IO` and never falls through.
- **An undeclared name is today's search.** A `pkg/` import whose first part is
  not declared searches `agc_libs/`, `AGENTICA_PATH`, the user data directory
  and the system directories, exactly as before
  ([05b](../grammar/05b-modules.md)). The libraries installed by hand keep
  working (45.14 question 2, decided).
- **No clash with local files.** The `pkg/` prefix makes a package import
  unambiguous: it can never name a file or folder beside the importing file. So
  `CHECK-IMPORT-AMBIGUOUS` does not exist, and neither does a rule for
  `github.com/...` in an import path.

**Which manifest decides.** For a file of the project, the manifest of the
project (and for a `pkg/` library file that the project loads, the same). For a
file of a package, the `agentica.toml` of that package, read from its folder in
the cache. A package file imports only the names its own manifest declares: it
cannot reach a dependency of the project, and the project cannot reach a
dependency of a package unless the project declares the name too (with the same
source, 45.6). A `pkg/` name that a package file did not declare is
`CHECK-IMPORT-PACKAGE`, and a package file never searches the `pkg/` roots, so a
package does not depend on what is installed on the machine.

**Inside a package.** A package imports its own modules by a relative path
(`import Parse from "json/parse"`), and that path must stay inside the package
root. A `../` that leaves the root is `CHECK-IMPORT-PATH`. Hidden folders and
`agc_libs/` are not importable from a package.

The root project imports a dependency by the name it gave it. A package imports
its dependencies by the names in its own manifest. The names that two manifests
give to one repository do not have to match, but one name must mean one source
in the whole build (45.7).

### 45.4 The TOML parser: `std/toml` (phase 45-0)

Decided by the owner on 2026-10-15: the manifest and the lock are TOML, and
`parse` returns the enum `Toml.Value`. The parser is its own std module,
because the manager needs it and any program can use it.

- **Where it lives.** `stdlib/toml.agc`, embedded as `std/toml`, imported as
  `import Toml from "std/toml"`. It is pure Agentica, like `std/binary` and
  `std/bdd/gherkin`, so it follows the rule "std first" (roadmap, "New library
  features: std first"). The only changes in `src/` are one line in the module
  registry of `src/stdlib.rkt` and the std list in the `src/main.rkt` help
  text. Row 7.2.7 allows both, as data and messages. There is no parser,
  checker or VM change. So the module can land before the bootstrap (port step
  8): the Racket front end compiles it like any other std module.
- **Scope.** All of TOML 1.0: basic, literal and multi-line strings with
  escapes; integers in decimal, hex, octal and binary, with `_`; floats,
  including `inf` and `nan`; booleans; datetimes; arrays; inline tables;
  standard tables, dotted keys and arrays of tables. No extension. Integers are
  64-bit, so a value out of range is an error.
- **The API.**
  - `Toml.parse(text) -> Result[Value]` reads a document. Its root is a table.
  - `Toml.to_json(value) -> Result[Json]` converts a value. It is an error for
    `inf` and `nan`, since JSON has no form for them. A datetime becomes a
    string, and a float stays a float. Typed decoding is
    `JSON.decode(JSON.encode(j), T)` on the result, so no new builtin is needed.
  - `Toml.encode(value) -> Result[String]` writes a document (45.6 uses it).
- **`parse` returns `Toml.Value` (decided).** The enum models TOML's own values.

  ```ruby
  export enum Value
    Str(String)
    Int(Int)
    Float(Float)
    Bool(Bool)
    DateTime(String)
    Array(List[Value])
    Table(Map[String, Value])
  end
  ```

  A recursive enum such as `Array(List[Value])` passes the checker today.
- **Datetimes (open question 11).** Recommended: `DateTime(String)` keeps the
  text exactly as written. A datetime and a string differ in TOML, and the
  encoder must write a datetime unquoted. Keeping the text makes the round trip
  exact. When §41 adds its date types, this variant splits into four, one for
  each TOML kind (41.19), which is a breaking change of `std/toml`.
- **Errors.** The error message starts with `line L, column C: ` and then says
  what was expected. Lines and columns count from 1, and a column counts
  characters. A `Result` error holds only a `String`
  ([`06-semantics.md`](../grammar/06-semantics.md)), so the position is in the
  text. The module never halts. Arrays and inline tables nest at most 256
  levels, and a key has at most 256 parts; a deeper input is an error at the
  opening bracket or the key. 45-0 chose 256 (not the 1,000 of
  `PARSE-TOO-DEEP`) because the reader, the encoder and `to_json` recurse in
  proportion to the depth, and 256 levels stay far under the VM's call limit
  of 10,000. The manager reads a manifest with `File.read_text`, so a manifest
  is subject to its 1 MiB limit. The manager turns the position into the
  diagnostic of 45.9.
- **Encoder.** `Toml.encode(value) -> Result[String]` writes a whole document,
  so the root must be a `Table`. A non-table root is an error. It validates the
  Datetime text, and it quotes keys that are not bare. Within each table, plain
  keys and inline values come first, then sub-tables, then arrays of tables. So
  `version = 1` stays at the top of the lock, whatever the insertion order. An
  array of tables is written as `[[name]]` only when every item is a table. Any
  other array, including one that mixes tables and scalars, is written inline.
  Keys come out in Map insertion order. The lock writer builds each
  `[[package]]` table in the fixed order of 45.6, so the encoder does no sorting
  of its own. The encoder covers every variant, not only the lock's subset,
  because the same code serves both. The same value gives the same bytes.
- **Round trip.** Parsing what `encode` wrote gives the same value. This is one
  of the tests of 45.11.

### 45.5 Manifest `agentica.toml`

The manifest is `agentica.toml`. Its directory is the manifest directory:
`agentica.lock` and `agc_libs/` sit beside it. For a package, that is the root
of its repository. Without a manifest, nothing changes. The manifest is the
nearest one going up from the folder of the root file, as far as the root of the
file system, so an `agentica.toml` in a shared parent folder (such as `/tmp`)
counts for every script below it. This is a known choice, and it is a breaking
change for those scripts (see the CHANGELOG). Stored paths of project files
follow PR #273 (the entry file's folder, §18.3). Packages, vendored ones
included, use the logical path of 45.8.

```toml
name = "notes"

[dependencies]
sqlite = { git = "https://github.com/owner/sqlite-ac", tag = "v1.2.0" }
json5 = { git = "https://gitlab.com/someone/json5", ref = "3f2a9c1" }

[style]
max_line_width = 119
```

- `name` is the project's own name, optional. It follows the rule of a
  dependency name below. A package's `name` is the default local name that
  `agentica add` (45c) proposes; nothing checks it against the names that others
  give.
- `[dependencies]` maps a local name to a source. The key is the local name used
  in imports (45.3). It is a lowercase letter followed by lowercase letters,
  digits, `_` and `-`, at most 64 characters. A key that is not a bare TOML key
  is quoted by the author and rejected by the rule above, so `"owner/repo"` is
  not a name.
- A source is an inline table with `git` and exactly one of `tag` and `ref`.
  Only `git` sources exist for now: a `path`, a `branch`, a `version` or any
  other key is `PKG-MANIFEST-INVALID` at its key path
  (`dependencies.sqlite.path`).
- `git` is an `https://host/owner/repo` URL, with an optional `.git` at the end.
  The host is lowercase, with no port and no user name. There are exactly an
  owner and a repository, in letters, digits and `. _ -`, neither `.` nor `..`
  and neither starting with `-` or ending in `.`, and neither a Windows device
  name (`con`, `prn`, `aux`, `nul`, `com1` to `com9`, `lpt1` to `lpt9`, in any
  case, with or without an extension), because they are folders of the cache. No
  query, no fragment, no trailing slash. Only https: `http://`, `ssh://` and
  `git@host:` forms are `PKG-MANIFEST-INVALID`. Two spellings of one repository
  (with and without `.git`) are one source. The cache path is built from this
  URL, `<host>/<owner>/<repo>` (45.8). A host such as a company server works the
  same way as `github.com`.
- `tag` is a git tag: letters, digits and `. _ + -`, at most 128 characters, no
  `/`, not starting with `.` or `-`. `ref` is a commit, as 7 to 64 lowercase hex
  digits (a prefix of the commit, or the whole of it). Exactly one of them:
  both, or neither, is `PKG-MANIFEST-INVALID` at the dependency. There are no
  branches and no version ranges, so a build never follows a moving target.
- `[style]` holds style rules for the `.agc` files under the folder of the
  manifest. All keys are optional, and a manifest with no `[style]` sets no
  rule. Decided by the owner on 2026-10-15. Later style keys go in the same
  table; today there is one: `max_line_width` is the longest line allowed, in
  characters (Unicode code points, not bytes). It counts every line, comments
  and doc comments included. With no `max_line_width` there is no limit. A line
  over it is an error, never a warning (section 26). `agentica check` reports it
  as `CHECK-LINE-TOO-LONG`, at the first character past the limit (proposed in
  §47.2 and owned by phase 28, 47c; the owner confirms the code). The rule
  covers every `.agc` file under the folder that holds that `agentica.toml`.
  `agentica fmt` does not enforce it: a line it cannot break stays long. Today
  `compiler/agentica.toml` and `stdlib/agentica.toml` set it to 119, and
  `tests/test_style_line_width.py` enforces it. `agentica check` reads `[style]`
  after port step 8 (§18.3), with `std/toml`, and phase 28 (47c) moves the check
  there and removes the test. The manager accepts `[style]` and its known keys,
  and an unknown style key is `PKG-MANIFEST-INVALID` like any other unknown key.
- An unknown key, a bad name or URL or pin, or a value of the wrong type is
  `PKG-MANIFEST-INVALID`. The manager lists the keys of the parsed table itself
  and rejects any it does not know. It does not leave this to a typed decode,
  which ignores extra keys. A TOML syntax error is the same code, with the line
  and column from `std/toml`.
- The manifest of a dependency is read from its folder in the cache, and only to
  learn which names its files may import and to check that each agrees with the
  lock (45.6, 45.7). It is not hashed (45.6). The build does not use anything
  else from it. It must be a regular file of the package folder: a symbolic
  link, a folder or a pipe under that name (in any case) is `PKG-SYMLINK` at the
  import that loads the package, and it is never opened.

### 45.6 Lock `agentica.lock`

The lock is TOML and is committed to git. It lists every package of the build,
direct and transitive, one entry for each local name, flat, with the git source,
the pin, the exact commit and a hash. The layout follows Cargo.lock and uv.lock.
The examples below are shortened.

```toml
version = 1

[[package]]
name = "greeter"
git = "https://github.com/owner/greeter"
tag = "v1.2.0"
commit = "9f2c4e1a0b7d..."
hash = "sha256:e3b0c44298fc..."

[[package]]
name = "json5"
git = "https://gitlab.com/someone/json5"
ref = "3f2a9c1"
commit = "3f2a9c1d44e0..."
hash = "sha256:a41f09c2e7bd..."
```

- **Layout.** `version = 1` is the lock format. Each `[[package]]` table has its
  keys in this fixed order: name, git, tag or ref, commit, hash. The manager
  sorts the tables by name, and `Toml.encode` writes them. So a rewrite with no
  change makes no diff. A bad key, value or shape is `PKG-LOCK-INVALID` at its
  key path. A name locked twice is `PKG-LOCK-INVALID`.
- **One entry for each name.** The lock is flat: a name is one package, whoever
  declares it. It holds the `git` URL and the `tag` or `ref` as the manifests
  write them, not the URL after a `url.<base>.insteadOf` rewrite, so the lock
  does not depend on one machine's git config. `commit` is the full commit (40
  or 64 lowercase hex digits). When the pin is a `ref`, the commit starts with
  it.
- **The hash.** Take the `.agc` files of the package. Their paths are relative
  to the repo root, written with `/`. Sort them in bytewise order. For each file
  write its path, a zero byte, its size in decimal, a zero byte and its bytes.
  The SHA-256 of that stream is the hash, written as `sha256:` and hex
  (`Crypto.sha256`; issue #455). Hidden folders and `agc_libs/` are not copied,
  not hashed and not importable. The `.agc` extension and the name `agc_libs`
  are compared without regard to case, so `x.AGC` is hashed and `AGC_LIBS/` is
  left out on every system (a case-insensitive file system could open them by
  their lowercase names). A symlink or gitlink among the copied `.agc` files is
  refused (`PKG-SYMLINK`). Elsewhere in the repo such entries are
  ignored. The package's `agentica.toml` is not part of the hash: what it can do
  is limited to naming dependencies, and each must agree with the lock (below).
- **One lock per build.** Only the root project's lock counts. A package's own
  lock is ignored when the package is a dependency.
- **Who writes it.** Only `add` and `update` write the lock (45.9).
- **When a build fails.** Any command that loads code (`agentica file.agc`,
  `check`, `test`) fails in these cases:
- A manifest that declares a dependency with no lock is `PKG-LOCK-MISSING`.
- A dependency of the manifest of the project that is not in the lock, or that
  the lock holds with another `git` URL, `tag` or `ref`, is `PKG-LOCK-STALE`, at
  `dependencies.<name>` of the manifest. This runs once, before any file is
  read.
- The same check runs on the manifest of every locked package that is in the
  cache, right after the check above and before any file is read, so a conflict
  anywhere in the tree is reported whether or not an import reaches that
  package. A dependency that the lock does not hold at all is `PKG-LOCK-STALE`.
  A name that the lock holds with another source is `PKG-SOURCE-CONFLICT`
  (45.7). Both are reported at `dependencies.<name>` of the package's manifest,
  in the cache. What cannot be looked at is left for the import that loads the
  package, with its own code, as before: a locked package that is not in the
  cache (`CHECK-IMPORT-PACKAGE`), a package folder that cannot be listed
  (`CHECK-IMPORT-IO`) and a manifest that is not a regular file
  (`PKG-SYMLINK`). So a conflict in such a package is reported only when it is
  imported.
- A failure about `agentica.toml` or `agentica.lock` as a whole, such as a lock
  that is missing or a file that cannot be read, has no key path and no place in
  the file: the plain and `--ai` forms show the file name alone, and `--json`
  has no `key_path` and a `range` at line 0, column 0.

The build does not fix the lock itself.

### 45.7 Pins and sources

Decided by the owner on 2026-10-20 (#468), in place of semantic versions and
minimal version selection.

- **A pin is a git tag or a commit.** A dependency says `tag = "v1.2.0"` or `ref
  = "<commit>"`. A tag is any git tag name that fits the rules of 45.5: the tool
  does not read it as a version, and does not order tags or ignore a tag that is
  not semver. There are no branches, so a build never follows a moving target,
  and there are no version ranges.
- **No solver.** There is no semver, no minimal version selection and no
  major-version rule. The lock holds the source that each name stands for, and
  the build uses it.
- **One name, one source.** In a build, a local name stands for one source: the
  same `git` URL and the same `tag` or `ref`. The project and the packages may
  all declare the same name, but only with the same source. The same name with
  two different sources anywhere in the tree is `PKG-SOURCE-CONFLICT`, reported
  at the declaration in the package's manifest that disagrees with the lock.
  When the manifest of the project disagrees with the lock, it is
  `PKG-LOCK-STALE` instead: the lock is out of date.
- **Two names for one repository** are allowed. They are two entries of the
  lock, with one folder in the cache for each commit, and the build loads the
  repository once for each name, as two packages. In particular, two
  incompatible majors of one library can be used together under two names.
- **A new release changes nothing by itself.** Only `add` and `update` write the
  lock (45.9). A build never reads the remote.
- **A moved tag.** When the commit of a fetched tag is not the commit in the
  lock, the fetch fails with `PKG-TAG-MOVED`. The lock is never changed
  silently.

### 45.8 Fetching and the cache

- **Git does the fetching.** The system `git` runs, so any host works with the
  user's git config, SSH keys and credential helpers. The tool keeps no tokens
  and has no HTTP client of its own.
- **URLs.** The `git` value of the dependency is fetched as written
  (`https://host/owner/repo`, with or without `.git`). The user's
  `url.<base>.insteadOf` setting in git config can rewrite it to SSH.
- **Fetch.** git fetches the tag `refs/tags/<tag>` with depth 1 into a bare
  temporary repository, or, for a `ref`, the commit. No working tree is made, so
  no checkout hook can run. A tag is peeled to its commit, and that commit must
  equal the lock's `commit`. The files are then read from that commit's tree
  with `git ls-tree` and `git cat-file`, so the package's `.gitattributes` has
  no effect on the bytes. Two copied `.agc` paths that differ only in case, in a
  file name or a folder name (`A.agc` and `a.agc`, or `Util/x.agc` and
  `util/y.agc`), are refused at fetch (`PKG-PATH-COLLISION`), so the package
  works on case-insensitive file systems too.
- **Manifest.** At fetch, the package's `agentica.toml` is read from the commit
  tree (`git cat-file`), not from a working tree, and checked as a manifest
  (45.5). Its `[dependencies]` must agree with the lock when `add` or `update`
  writes it (`PKG-SOURCE-CONFLICT`, or the lock gets the new names). The fetch
  copies it to the cache beside the `.agc` files, because the build reads it
  (45.3); it is not hashed (45.6). A symlink or gitlink among the copied `.agc`
  files is refused (`PKG-SYMLINK`).
- **Hash check.** The hash of 45.6 must match the lock, or the fetch fails with
  `PKG-HASH-MISMATCH`.
- **Cache.** The files go to
  `$XDG_CACHE_HOME/agentica/pkg/<host>/<owner>/<repo>/<commit>/`, which defaults
  to `~/.cache/agentica/pkg/`; on Windows, to
  `%LOCALAPPDATA%/agentica/cache/pkg/` (45a: `XDG_CACHE_HOME` and `HOME` are not
  read there, and a relative or unset `LOCALAPPDATA` leaves no cache). The
  `<host>/<owner>/<repo>` part is the `git` URL without `https://` and `.git`,
  so it does not depend on the local name. The commit in the path means two
  versions never share a folder. The fill goes into a temporary folder that is
  renamed into place, so a half-written folder is never read. If the target
  already exists, the fill checks its hash. A match is a success, because
  another process filled it first. A mismatch is `PKG-HASH-MISMATCH`, and
  nothing is overwritten. The folder is read-only after the fill.
- **Stored paths.** Project files are stored as PR #273 defines: relative to the
  entry file's folder, as §18.3 asks. Package files live in the cache, outside
  any project. A path relative to the entry file would depend on how deep that
  file is, so a package file is stored under its logical path:
  `pkg/<name>@<version>/path/in/repo.agc`, for example
  `pkg/sqlite@v1.2.0/db.agc`. `<version>` is the tag, or the first 12 hex digits
  of the commit for a `ref`, so two machines that write the same commit with
  different refs store the same bytes. The `.agcb` stores that path, so its
  bytes do not depend on the machine's cache folder. Vendored packages use the
  same path. 45a implements this for packages.
- **Only `.agc` files** are used and hashed, and the root `agentica.toml` of a
  package is kept for the build to read. Other files in a package are not
  copied.
- **A build never fetches.** Only `add`, `install`, `update` and `vendor` run
  git.

**Vendoring.** `agentica vendor` copies every locked package into
`agc_libs/<name>/`, for example `agc_libs/sqlite/`. The `agc_libs/` location
follows question 9 (beside `agentica.toml` when a manifest exists). The command
fills missing cache entries first, as `install` does. A CI job with no network
then builds from the vendored files, and the hash check proves they are the
locked ones. For a declared name the build looks in `agc_libs/<name>/` first and
in the cache second. A vendored copy whose hash does not match is an error,
never a silent fallback. A declared name never reaches the `pkg/` search of 05b
(45.3), so a vendored copy is loaded only through its name, where the hash is
checked. Otherwise a `pkg/` import would load an unhashed copy. `vendor` writes
only the paths of locked packages. It leaves other files in `agc_libs/` alone,
including the `pkg/` libraries of 05b (45.14 question 2).

**No code runs at install.** A package is data until a program imports it.
Importing it runs what any import runs: a module has no top-level statements, so
only its module constants are evaluated, and only when the program uses it.

### 45.9 Commands and errors

These commands are in the single `agentica` binary, written in Agentica, after
step 8 of §18.3. Their exact command line is decided in 45b and 45c; the
behavior is:

- `agentica add NAME URL` with a tag or a ref adds the dependency to
  `agentica.toml`, rewrites the lock and fills the cache.
- `agentica install` fills the cache with what the lock says. It never changes
  the lock. If the manifest asks for more than the lock has, it fails with
  `PKG-LOCK-STALE`.
- `agentica update [NAME]` re-resolves the named package, or every dependency
  when no name is given, from the pins in the manifest. It rewrites the lock.
- `agentica vendor` copies the locked packages into `agc_libs/` (45.8).

The commands start `git`. The VM refuses a process start without `--allow-run`
([`10-io-processes.md`](../vm/10-io-processes.md)). The package commands grant
it to their own run (45.14 question 8, decided). `agentica file.agc` never runs
git.

Errors use stable codes, with the `PKG-` prefix (45.14 question 4, decided).

- `PKG-MANIFEST-INVALID`: `agentica.toml` is not valid TOML, has an unknown key,
  or has a name, a URL, a tag or a ref of the wrong form, or a source that is
  not git. A TOML syntax error carries the line and column from `std/toml`.
- `PKG-LOCK-INVALID`, `PKG-LOCK-MISSING`, `PKG-LOCK-STALE`: the lock is bad,
  absent, or does not agree with a manifest (45.6).
- `PKG-SOURCE-CONFLICT`: one name has two different sources in the tree (45.7).
- `PKG-FETCH`: git failed, or the tag or commit is not in the repository. Git's
  message goes in the help.
- `PKG-TAG-MOVED`: the tag now points to another commit than the lock says.
- `PKG-HASH-MISMATCH`: a file, the listing or a cache folder does not match the
  lock.
- `PKG-PATH-COLLISION`: two copied `.agc` paths differ only in case, in a file
  or folder name (45.8).
- `PKG-SYMLINK`: a symlink or gitlink is among the copied `.agc` files (45.6).
- `CHECK-IMPORT-PATH`: the path is not valid. It also covers `pkg/<name>` with
  no module, a `../` that leaves a package root, and an import into a hidden
  folder or `agc_libs/` of a package (45.3).
- `CHECK-IMPORT-PACKAGE`: a declared package is not in the cache or in
  `agc_libs/`, with the help to run `agentica install`; or a file of a package
  imports a `pkg/` name that its own manifest does not declare.

The last two belong to the import checks, and the rest to the package tool.
Manifest and lock errors have no source span, so they name the file and the key
path (for example `dependencies.sqlite.git`), with the line and column when the
error is a TOML syntax error. AGENTS.md says codes carry a span, so 45a changes
the diagnostic format and AGENTS.md lists the `PKG-` prefix (45.14 question 4).

### 45.10 Native code

`owner/sqlite-ac` in the example wraps the SQLite C library. A package like that
needs native code, and the VM cannot load native code today: there is no FFI.
§40 is planned, and its FFI is a sketch (§40.3a). This design covers pure
Agentica packages only.

The order is in [§40.5](40-native-code.md#405-order): packages, then the FFI,
then native packages. Packages are planned as the distribution channel for
native libraries. A program that needs a C, C++ or Rust library gets it as a
package, and loading it still needs `--allow-native` (§40.4). How native
packages are built and hashed is still open (see below).

A native package is a separate topic, after §40. It needs more than an FFI. It
needs the trust flag of §40.4, and it needs either a build step or prebuilt
binaries with hashes in the lock. A build step would break "no code at install"
(45.2), so neither option is designed here.

### 45.11 Testing plan

**`std/toml` (phase 45-0).**

- **Goldens.** The vendored toml-test files (`tests/fixtures/toml-test/`,
  below) hold each valid input with its expected value. `tests/fixtures/toml/`
  holds our own inputs. A set of bad inputs has golden errors, with their line
  and column, in `tests/test_std_toml.py`.
- **Independent peer.** Python's standard `tomllib` (3.11 or later) parses the
  same inputs. A small printer in the test writes its dict in the same text
  form, and the two must match.
- **Errors.** For each bad input, both parsers must reject it. The test does not
  compare positions. `tomllib` errors have no line or column before Python 3.14,
  so the module's own golden holds the position.
- **Encoder.** The Agentica encoder writes each golden value, and `tomllib`
  reads the text back. The result must equal the value. This tests the writer
  against an independent reader.
- **Round trip.** Parsing what `encode` wrote gives the same value.
- **Runner.** CI runs `python3`, which is the runner's version (`ci.yml`). 45-0
  checks that it is 3.11 or later in CI and fails there if it is not. It does
  not skip.
- **The toml-test corpus.** The license of toml-lang/toml-test is MIT, which
  allows vendoring. 45-0 vendors its TOML 1.0.0 files (about 100 KB) under
  `tests/fixtures/toml-test/` with the license, in the fast tier: every valid
  input must give the expected value and every invalid one an error.

**The manager (45a to 45d).**

- **Hermetic.** A bare git repository in a temporary folder is the remote.
  `AGENTICA_PKG_ROOT` is a test-only knob (a proposal) that sets the base URL
  for git. A test points it at `file://` paths of the bare repositories. It
  changes where git fetches from, and the commit and hash checks still apply to
  what it serves. No test touches the network.
- **Pytest.** 45a tests are in `tests/test_spec_packages.py`, through the CLI
  with `--json check`: they assert the code and the span, or the file and key
  path, never message text. They run the `agentica` binary on fixture programs.
  The tests of the fetch (45b) need git: CI installs it and fails if it is
  missing. Local runs may skip.
- **A peer for the hash.** The rule of 45.6 is written again in Python with
  `hashlib` and `os.walk`, so a second implementation checks the Agentica one.
- **Few tests, each one important** (CLAUDE.md, "Writing Tests"):
  1. End to end: `add`, then `install` into an empty cache, then a program
     imports `pkg/name/mod` and prints. This covers the import form, the cache
     and the lock together.
  2. Round trip: read `agentica.lock`, write it back, and compare the bytes.
     The manifest gets the same test.
  3. Failures, checked by code and not by text: a tampered file gives
     `PKG-HASH-MISMATCH`; a moved tag gives `PKG-TAG-MOVED`; a tag changed in
     the manifest gives `PKG-LOCK-STALE`; one name with two sources gives
     `PKG-SOURCE-CONFLICT`.
  4. Offline: with the cache filled and no `git` on `PATH`, a build still
     succeeds. This proves that a build never fetches.
  5. Import paths: a `../` that leaves a package root, and an import into a
     hidden folder or `agc_libs/` of a package, give `CHECK-IMPORT-PATH`.

### 45.12 Phases

Phase 45-0 comes first and may land before the bootstrap. The manager phases
come after port step 8.

- **45-0. `std/toml`.** The parser, the encoder, the goldens and the peer tests
  of 45.4 and 45.11. The PR also touches the std module list in the help text of
  `src/main.rkt` and the list in `tests/modules-test.rkt`. Row 7.2.7 allows both
  as data and messages. It adds a std/toml section to
  `docs/grammar/05b-modules.md`, a library page, a row in the programming
  skill's library references, and a `CHANGELOG.md` entry, because the module is
  new for users.
- **45a. Manifest and lock (done).** Read `agentica.toml` and `agentica.lock`
  with `std/toml`. Resolve `pkg/<name>/...` imports from the cache, with the
  hash check (`Crypto.sha256`) and the `CHECK-IMPORT-*`, `PKG-LOCK-*` and
  `PKG-SOURCE-CONFLICT` checks. Packages are stored under their logical path
  (45.8). There is no fetching: the tests fill the cache by hand. The code lands
  in `compiler/` only (`compiler/packages/`, and
  `compiler/modules/resolve_import.agc` for the import), after step 8, when the
  Racket front end is gone. That is consistent with the freeze.
- **45b. Fetch and install.** The git fetch of the tag, the commit check, the
  hash check, the cache fill, `install`, and the fetch errors.
- **45c. Add and update.** `add`, `update`, the lock writer and the manifest
  writer, with the rules of 45.7.
- **45d. Vendor.** `vendor`, the `agc_libs/<name>/` layout, and the build order
  that prefers the vendored copy of a declared name (45.8).

Each manager PR has its own tests (45.11), and updates
[`05b-modules.md`](../grammar/05b-modules.md), the programming skill and a
`CHANGELOG.md` entry, because import behavior changes for users.

### 45.13 Not now

One line each, as possible later work:

- A central registry: git hosts already hold the packages.
- Private registries: git's own login covers private repositories for now.
- Publishing commands: a release is a tag, so there is nothing to publish.
- Signatures: the commit and the hash come first; signed tags can follow.
- Workspaces and monorepos: one manifest per project in v1.
- Branches and version ranges: a pin is a tag or a commit, so builds stay
  reproducible.
- Sources other than git, such as a local path: `git` only for now.
- Typed decoding into structs: not needed for the manager.
  `JSON.decode(JSON.encode(j), T)` on the output of `Toml.to_json` does it
  (45.4, question 10).
- Native packages: §40 first (45.10).

### 45.14 Open questions

All answered by the owner on 2026-10-20: each question takes its
recommendation (10 and 12 were decided earlier).

1. **The import form and the ambiguity rule.**
   - Option A: the manifest-declared rule of 45.3. Existing imports keep their
     meaning, and a clash is an error at the import.
   - Option B: keep `pkg/` as the package prefix, as `pkg/owner/repo/mod`. No
     clash is possible. The cost is a second form, and the owner asked for
     `owner/repo/...`.
   - Option C: require `./` for relative imports, as `import X from
     "./models"`. Packages then need no lookup, but every relative import
     changes. This is a breaking change, with a migration of `examples/`,
     `stdlib/`, `tests/` and the docs.
   - **Decided (2026-10-20):** A. It keeps every import that works today, and it
     makes a clash visible.
   - **Replaced (2026-10-20, #468):** B, with a local name: `pkg/<name>/mod`.
     The `pkg/` prefix makes a clash impossible, so `CHECK-IMPORT-AMBIGUOUS` and
     the host-prefix rule are gone (45.3).

2. **The fate of today's `pkg/` roots.**
   - Option A: keep them for libraries that are installed by hand, and revisit
     after 45c.
   - Option B: replace them with the package form now.
   - **Decided (2026-10-20):** A. Replacing them breaks people who install by
     hand, and nothing is gained before the manager exists.

3. **Major versions.**
   - Option A: Go's way, a `v2` segment in the path, as `owner/repo/v2/mod`. It
     can clash with folders inside the repo.
   - Option B: a new repo for each major, as `owner/sqlite-ac-v2`. The key names
     the major, and two majors can be in one build.
   - Option C: one major per build. A second major is an error.
   - **Decided (2026-10-20):** B. It needs no new rule in the import form, and
     it has no clash.
   - **Replaced (2026-10-20, #468):** there is no semver and no major rule. A
     pin is a tag or a commit, and one name has one source (45.7); two majors of
     one library can be used together under two names.

4. **Error codes and their prefix.**
   - Option A: a new `PKG-` prefix for the manifest, the lock, fetching, the
     cache and the CLI, and the `CHECK-IMPORT-*` family for import errors.
     AGENTS.md then lists the new prefix. Manifest and lock errors name the file
     and the key path, not a source span, so the diagnostic format needs a
     small change.
   - Option B: everything under `CHECK-IMPORT-*`.
   - **Decided (2026-10-20):** A, with the key path. The format change is small,
     and it belongs in 45a.

5. **`dev_dependencies`.**
   - Option A: not in v1. There is one list.
   - Option B: a second table, used only by `*_test.agc` files (phase 25).
   - **Decided (2026-10-20):** A. Add B when a test needs a package that the
     program does not.

6. **Data files in a package.**
   - Option A: only `.agc` files are used and hashed.
   - Option B: a `files` list in the manifest adds data files, such as a SQL
     schema, to the hash and to the vendored copy.
   - **Decided (2026-10-20):** A. Add B when a package needs one. The root
     `agentica.toml` of a package is kept beside its `.agc` files, because the
     build reads it (45.3), but it is not hashed.

7. **Hashing at build.**
   - Option A: every build hashes each package it loads, from the cache or from
     `agc_libs/`.
   - Option B: hash at install and vendor only. The build trusts the cache,
     which is read-only.
   - **Decided (2026-10-20):** A. It is one rule, and it catches a changed
     vendored file. 45a measures the cost on the largest package it has.

8. **Who may run git.**
   - Option A: the package commands turn on the run grant for their own process.
     The user typed the command, and `agentica file.agc` still cannot run git.
   - Option B: the user passes `--allow-run` to the package commands.
   - **Decided (2026-10-20):** A.

9. **Where `agc_libs/` sits when a manifest exists.** Decided (2026-10-20): B.
   - Option A: beside the root program, as today.
   - Option B: beside `agentica.toml` when a manifest exists, and beside the
     root program otherwise, as today. A vendored package is reached through
     its declared name, where the hash is checked (45.8).

10. **The shape of `parse`.** Decided by the owner on 2026-10-15: B.
    - Option A: a `JSON` value, reusing the JSON builtins (`JSON.get`,
      `JSON.at`, `JSON.string`). This works, but a `Json` value cannot be
      matched with `case`, and TOML's own types are lost. An integer and a float
      both become JSON numbers, a datetime becomes a string, and `inf` and `nan`
      have no JSON form.
    - Option B: the dedicated enum `Toml.Value` of 45.4. Pattern matching works,
      no language rule changes, and one type covers all of TOML. The checker
      accepts its recursion.
    - Option C: typed decoding straight into structs, as `JSON.decode(text, T)`
      does on JSON text. A std module cannot take a type argument, so this would
      need a builtin in C or in the Racket front end. The API gives the same
      result with `JSON.decode(JSON.encode(j), T)` on the output of
      `Toml.to_json`, so no builtin is needed.
    - **Decided:** B. The manager copies its manifest into its own struct by
      hand, after checking its keys (45.5).

11. **Datetimes.**
    - Option A: an RFC 3339 string in `Text`. A datetime and a string look the
      same, so a round trip writes the datetime in quotes and changes the file.
    - Option B: `DateTime(String)`, which keeps the text as written.
    - **Decided (2026-10-20):** B. The text is exact. When §41 lands, the date
      variants change: TOML's four kinds get one variant each (41.19). That is
      a breaking change of std/toml, and its design waits for §41.

12. **The toml-test corpus.**
    - Option A: vendor it under `tests/fixtures/toml-test/` with its license
      file, as `@slow` cases.
    - Option B: do not vendor it. Fetch it by hand from a pinned commit when
      needed.
    - **Decided (45-0):** A. The license is MIT, so the files are vendored.
      They are small, so they run in the fast tier, not as `@slow` cases.
