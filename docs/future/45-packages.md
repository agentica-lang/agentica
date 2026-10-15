## 45. Packages

**Status:** Design, not scheduled: the code waits until after the bootstrap
(§35 step 8), except 45-0 (`std/toml`), which may land before it. Asked by the
owner on 2026-10-15 ("Shall we plan this?").

Decided by the owner on 2026-10-15:

- `std/toml` comes first (45-0, 45.4).
- The manifest and the lock are TOML (45.5, 45.6).
- `Toml.parse` returns the recursive enum `Toml.Value` (45.4).
- The import form: GitHub with no prefix (`owner/repo/mod`), and every other
  host as a prefix (`host/owner/repo/mod`) (45.3).

Everything else here is a proposal. The open questions in 45.14 need the
owner's answer before the phases after 45-0 start.

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
get it too. The `.agcb` file stores absolute source paths today (§35.1). PR
#273 (in flight) makes project files relative to the entry file's folder, which
§35.4 asks for before step 6. Package files are stored differently (45.8).

### 45.2 Goals

- **Reproducible builds.** The same manifest and lock give the same source
  bytes. Every package file is checked by a hash.
- **No code runs at install.** Installing a package only copies files. A
  package has no build script, no install hook and no post-install step. npm
  runs lifecycle scripts, and pip has run `setup.py` at install, so both let a
  package run code when it is installed. This design does not.
- **One import form.** A package has one name and one way to import it. GitHub
  is never written `github.com/owner/repo`.
- **Offline after one fetch.** Once a package is in the cache or vendored, a
  build needs no network.
- **Hermetic tests.** A local git repository can stand in for the remote, so
  the tests need no network (45.11).

Not goals in v1: a central registry, a version solver and publishing commands.
See 45.13.

### 45.3 Import form

Decided by the owner on 2026-10-15:

- **GitHub packages have no host prefix.** `import Sqlite from
  "owner/sqlite-ac/sqlite"` loads `sqlite.agc` at the root of the repository
  `owner/sqlite-ac`. The part after the repo name is a path inside the repo.
  It uses forward slashes, has no extension, and each part follows the rules
  of 05b. `"owner/sqlite-ac/util/json"` loads `util/json.agc`.
- **Other hosts come first.** `import X from "gitlab.com/owner/repo/mod"`. As
  in Go, a first segment with a dot names a host. A host has no port and no
  user name in v1.
- **One canonical form.** Writing `github.com/owner/repo/...` is
  `CHECK-IMPORT-PATH`, with the help "write owner/repo/... for GitHub".

Proposed, with the form above:

- **Key grammar.** Each segment is lowercase, from `[a-z0-9._-]`. No segment
  is `.` or `..`, and none starts with `-`. A first segment with a dot is a
  host. `std` and `pkg` are reserved as first segments. Keys and imports are
  spelled the same way, so one package has one spelling. GitHub ignores case
  in names, so the tool must not accept two spellings of one package.
- **A bare key.** An `owner/repo` import with no module part is
  `CHECK-IMPORT-PATH` when `owner/repo` is a declared key. Otherwise it is an
  ordinary relative path.
- **The manifest decides.** An import is a package import only when its first
  segments are a key of the manifest of the package that owns the importing
  file (`owner/repo` or `host/owner/repo`). Otherwise it is a relative import,
  as today.

The clash comes from today's rules. `owner/repo/x` names the file
`owner/repo/x.agc` beside the importing file. A dot in a folder name is legal,
because 05b checks only the last part of a path. So a folder called
`gitlab.com` could exist. The manifest rule settles the choice, and 45.14
question 1 lists the other options.

When the rule finds both a declared package and a relative file or folder that
matches its leading path (the file `owner/repo/x.agc`, or the folder
`owner/repo/` beside the importing file), the import is
`CHECK-IMPORT-AMBIGUOUS`, located at the import. Nothing is chosen silently.

**Inside a package.** A package imports its own modules by a relative path
(`import Parse from "json/parse"`), and that path must stay inside the package
root. A `../` that leaves the root is `CHECK-IMPORT-PATH`. Hidden folders and
`agc_libs/` are not importable from a package.

A package imports its direct dependencies by the package form. The build never
reads a dependency's manifest (45.5). So for a dependency's files, the list of
its direct keys is its `requires` in the lock (45.6). For the root project, the
list is its own manifest. The root may import only its own direct dependencies.
Transitive dependencies are in the lock, and their versions come from there.

Today's `pkg/` roots stay for now. See 45.14 question 2.

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
  checker or VM change. So the module can land before the bootstrap (§35 step
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
of its repository. Without a manifest, nothing changes. Stored paths of project
files follow PR #273 (the entry file's folder, §35.4). Packages, vendored ones
included, use the logical path of 45.8.

```toml
name = "acme/notes"
version = "0.3.0"

[dependencies]
"owner/sqlite-ac" = "1.2.0"
"gitlab.com/team/json-tools" = "0.4.1"

[style]
max_line_width = 119
```

- `name` is the project's own name. For a package it must equal the key it was
  fetched as. A mismatch is `PKG-NAME-MISMATCH`.
- `version` is the project's own version, as semver. For a package it should
  equal its tag.
- `[dependencies]` maps a key (`owner/repo` or `host/owner/repo`) to a minimum
  version. The version is semver, written without the `v`. The lock says which
  version the build uses (45.6 and 45.7).
- The keys are quoted, because `/` and `.` are not bare-key characters in TOML.
- `[style]` holds style rules for the `.agc` files under the folder of the
  manifest. All keys are optional, and a manifest with no `[style]` sets no
  rule. Decided by the owner on 2026-10-15. Later style keys go in the same
  table; today there is one:
  - `max_line_width` is the longest line allowed, in characters (Unicode code
    points, not bytes). It counts every line, comments and doc comments
    included. With no `max_line_width` there is no limit. A line over it is an
    error, never a warning (section 26). The proposed code is
    `CHECK-LINE-TOO-LONG`, at the first character past the limit (a proposal,
    not decided). The rule covers every `.agc` file under the folder that holds
    that `agentica.toml`.
  - Today `compiler/agentica.toml` and `stdlib/agentica.toml` set it to 119, and
    `tests/test_style_line_width.py` enforces it. `agentica check` will read
    `[style]` after step 8 of 35.4, with `std/toml`, and the test can go then.
    The manager accepts `[style]` and its known keys, and an unknown style key
    is `PKG-MANIFEST-INVALID` like any other unknown key.
- An unknown key, a bad key or a bad version is `PKG-MANIFEST-INVALID`. The
  manager lists the keys of the parsed table itself and rejects any it does not
  know. It does not leave this to a typed decode, which ignores extra keys. A
  TOML syntax error is the same code, with the line and column from `std/toml`.
- A dependency's manifest is read only when that package is fetched or added,
  and there `PKG-NAME-MISMATCH` is checked (45.8). The build never reads it. The
  lock's `requires` is the authority at build time (45.6).

### 45.6 Lock `agentica.lock`

The lock is TOML and is committed to git. It lists every package in the graph,
direct and transitive, with the exact version, the commit and a hash. The
layout follows Cargo.lock and uv.lock. The examples below are shortened.

```toml
version = 1

[[package]]
name = "gitlab.com/team/json-tools"
version = "0.4.1"
source = "https://gitlab.com/team/json-tools.git"
commit = "2b7e0c9d4f1a..."
hash = "sha256:a41f09c2e7bd..."
requires = []

[[package]]
name = "owner/sqlite-ac"
version = "1.2.3"
source = "https://github.com/owner/sqlite-ac.git"
commit = "9f2c4e1a0b7d..."
hash = "sha256:e3b0c44298fc..."
requires = ["gitlab.com/team/json-tools@0.4.1"]
```

- **Layout.** `version = 1` is the lock format. Each `[[package]]` table has its
  keys in this fixed order: name, version, source, commit, hash, requires. The
  manager sorts the tables by name, and `Toml.encode` writes them. So a rewrite
  with no change makes no diff.
- **`source`** is the URL the key stands for, not the URL after a
  `url.<base>.insteadOf` rewrite. So the lock does not depend on one machine's
  git config.
- **`requires`** lists each direct dependency of the package as `key@minimum`.
  The minimum is the one the package's own manifest asks for, not the version
  used. The build reads the graph from here.
- **The hash.** Take the `.agc` files of the package. Their paths are relative
  to the repo root, written with `/`. Sort them in bytewise order. For each file
  write its path, a zero byte, its size in decimal, a zero byte and its bytes.
  The SHA-256 of that stream is the hash, written as `sha256:` and hex. Hidden
  folders and `agc_libs/` are not copied, not hashed and not importable. A
  symlink or gitlink among the copied `.agc` files is refused (`PKG-SYMLINK`).
  Elsewhere in the repo such entries are ignored.
- **One lock per build.** Only the root project's lock counts. A package's own
  lock is ignored when the package is a dependency.
- **Who writes it.** Only `add` and `update` write the lock (45.9).
- **When a build fails.** Any command that loads code (`agentica file.agc`,
  `check`, `test`) fails in these cases:
  - A manifest that declares a dependency with no lock is `PKG-LOCK-MISSING`.
  - `PKG-LOCK-STALE` checks the whole graph, not only the root. Every locked
    version must meet the minimum of each dependent that names it, transitive
    dependents included. The root's manifest is one dependent, and each
    package's `requires` is another. A declared dependency that is missing from
    the lock is `PKG-LOCK-STALE` too.
  - Two majors for one key is `PKG-MAJOR-CONFLICT` (45.7).

  The build does not fix the lock itself.

### 45.7 Versions

- **A version is a git tag** `vMAJOR.MINOR.PATCH`. A tag that is not semver is
  ignored. Prerelease tags are ignored by default: `add` and `update` never pick
  one, though a minimum can still name one exactly. A branch or a commit cannot
  be a version in v1, so a build never follows a moving target.
- **Minimal version selection,** as in Go. For each package, the build uses the
  highest minimum that any manifest in the graph asks for. The graph is read
  from the `requires` of the lock (45.6). There is no solver and no
  backtracking. The result depends only on the manifests, so every machine picks
  the same versions.
- **A new release changes nothing by itself.** Only `add` and `update` pick a
  newer tag and rewrite the lock. A build never reads the remote for versions.
- **`add` without a version** picks the newest tag and writes it as the
  minimum. **`update name`** re-resolves that package to the newest tag with the
  same major as the lock, and writes the new minimum for it. **`update`** with
  no name re-resolves every direct dependency, and recomputes MVS over the whole
  graph, so transitive versions can move too.
- **Majors.** A key has one major. A tag of a higher major under a key whose
  locked major is 1 is not a candidate for `add` or `update`. An `add` of a key
  with no locked major takes the newest tag, whatever its major, and that major
  is locked from then on. A minimum of another major for the same key is
  `PKG-MAJOR-CONFLICT`: two majors of one key cannot be in one build. How a v2
  gets its key is open (45.14 question 3).
- **A moved tag.** When the commit of a fetched tag is not the commit in the
  lock, the fetch fails with `PKG-TAG-MOVED`. The lock is never changed
  silently.

### 45.8 Fetching and the cache

- **Git does the fetching.** The system `git` runs, so any host works with the
  user's git config, SSH keys and credential helpers. The tool keeps no tokens
  and has no HTTP client of its own.
- **URLs.** `owner/repo` is fetched from `https://github.com/owner/repo.git`,
  and `host/owner/repo` from `https://host/owner/repo.git`. The user's
  `url.<base>.insteadOf` setting in git config can rewrite either to SSH.
- **Fetch.** git fetches the tag `refs/tags/vX.Y.Z` with depth 1 into a bare
  temporary repository. No working tree is made, so no checkout hook can run.
  The tag is peeled to its commit, and that commit must equal the lock's
  `commit`. The files are then read from that commit's tree with `git ls-tree`
  and `git cat-file`, so the package's `.gitattributes` has no effect on the
  bytes. Two copied `.agc` paths that differ only in case, in a file name or a
  folder name (`A.agc` and `a.agc`, or `Util/x.agc` and `util/y.agc`), are
  refused at fetch (`PKG-PATH-COLLISION`), so the package works on
  case-insensitive file systems too.
- **Manifest.** At fetch, the package's `agentica.toml` is read from the commit
  tree (`git cat-file`), not from a working tree. Its `name` is checked against
  the key (`PKG-NAME-MISMATCH`), and its `[dependencies]` become the `requires`
  of the package when `add` or `update` writes the lock (45.6). The manifest is
  not copied or hashed. A symlink or gitlink among the copied `.agc` files is
  refused (`PKG-SYMLINK`).
- **Hash check.** The hash of 45.6 must match the lock, or the fetch fails with
  `PKG-HASH-MISMATCH`.
- **Cache.** The files go to
  `$XDG_CACHE_HOME/agentica/pkg/<host>/<owner>/<repo>/<commit>/`, which defaults
  to `~/.cache/agentica/pkg/`. GitHub uses the host `github.com`. The commit in
  the path means two versions never share a folder. The fill goes into a
  temporary folder that is renamed into place, so a half-written folder is never
  read. If the target already exists, the fill checks its hash. A match is a
  success, because another process filled it first. A mismatch is
  `PKG-HASH-MISMATCH`, and nothing is overwritten. The folder is read-only after
  the fill.
- **Stored paths.** Project files are stored as PR #273 (in flight) defines:
  relative to the entry file's folder, as §35.4 asks. Package files live in the
  cache, outside any project. A path relative to the entry file would depend on
  how deep that file is, so a package file is stored under its logical path:
  `<key>@<version>/path/in/repo.agc`, for example
  `owner/sqlite-ac@1.2.3/sqlite.agc`. The `.agcb` stores that path, so its bytes
  do not depend on the machine's cache folder. Vendored packages use the same
  path. 45a implements this for packages.
- **Only `.agc` files** are used. Other files in a package are not copied.
- **A build never fetches.** Only `add`, `install`, `update` and `vendor` run
  git.

**Vendoring.** `agentica vendor` copies every locked package into
`agc_libs/<key>/`, for example `agc_libs/owner/sqlite-ac/` and
`agc_libs/gitlab.com/team/json-tools/`. The `agc_libs/` location follows
question 9 (recommended: beside `agentica.toml` when a manifest exists). The
command fills missing cache entries first, as `install` does. A CI job with no
network then builds from the vendored files, and the hash check proves they are
the locked ones. The build
looks in `agc_libs/<key>/` first and in the cache second. A vendored copy whose
hash does not match is an error, never a silent fallback. The `pkg/` search
skips these package folders, so a vendored copy is reached only through its
key, where the hash is checked. Otherwise a `pkg/` import would load an
unhashed copy. `vendor` writes only the paths of locked packages. It leaves
other files in `agc_libs/` alone, including the `pkg/` libraries of 05b (45.14
question 2).

**No code runs at install.** A package is data until a program imports it.
Importing it runs what any import runs: a module has no top-level statements,
so only its module constants (§44) are evaluated, and only when the program
uses it.

### 45.9 Commands and errors

These commands are in the single `agentica` binary, written in Agentica, after
step 8 of §35.4:

- `agentica add owner/repo[@version]` and
  `agentica add host/owner/repo[@version]` pick the version (the newest tag by
  default), add the key and its minimum to `agentica.toml`, rewrite the lock and
  fill the cache.
- `agentica install` fills the cache with what the lock says. It never changes
  the lock. If the manifest asks for more than the lock has, it fails with
  `PKG-LOCK-STALE`.
- `agentica update [name]` re-resolves the named package, or every direct
  dependency when no name is given, to the newest tag with the same major. It
  rewrites the lock, and it recomputes MVS over the graph (45.7).
- `agentica vendor` copies the locked packages into `agc_libs/` (45.8).

The commands start `git`. The VM refuses a process start without
`--allow-run` ([`10-io-processes.md`](../vm/10-io-processes.md)). The package
commands grant it to their own run (45.14 question 8). `agentica file.agc`
never runs git.

Errors use stable codes. The prefix is proposed in 45.14 question 4.

- `PKG-MANIFEST-INVALID`: `agentica.toml` is not valid TOML, has an unknown
  key, or has a key or version of the wrong form. A TOML syntax error carries
  the line and column from `std/toml`.
- `PKG-LOCK-INVALID`, `PKG-LOCK-MISSING`, `PKG-LOCK-STALE`: the lock is bad,
  absent, or does not match the graph (45.6).
- `PKG-NO-VERSION`: no tag matches the request (none, only non-semver tags, only
  prereleases, or only tags of another major).
- `PKG-MAJOR-CONFLICT`: two majors of one key are asked for (45.7).
- `PKG-FETCH`: git failed. Git's message goes in the help.
- `PKG-TAG-MOVED`: the tag now points to another commit than the lock says.
- `PKG-HASH-MISMATCH`: a file, the listing or a cache folder does not match the
  lock.
- `PKG-PATH-COLLISION`: two copied `.agc` paths differ only in case, in a file
  or folder name (45.8).
- `PKG-NAME-MISMATCH`: a package's `name` differs from its key.
- `PKG-SYMLINK`: a symlink or gitlink is among the copied `.agc` files (45.6).
- `CHECK-IMPORT-PATH`: the path is not valid. It also covers `github.com/...`,
  a `../` that leaves a package root, an import into a hidden folder or
  `agc_libs/` of a package, and a bare `owner/repo` that is a declared key
  (45.3).
- `CHECK-IMPORT-AMBIGUOUS`: an import matches both a declared package and a
  relative file or folder (45.3).
- `CHECK-IMPORT-PACKAGE`: an import matches a declared package that is not in
  the cache or in `agc_libs/`. The help says to run `agentica install`.

The last two belong to the import checks, and the rest to the package tool.
Manifest and lock errors have no source span, so they name the file and the
key path (for example `dependencies.owner/sqlite-ac`), with the line and column
when the error is a TOML syntax error. AGENTS.md says codes carry a span, so
45.14 question 4 covers this.

### 45.10 Native code

`owner/sqlite-ac` in the example wraps the SQLite C library. A package like that
needs native code, and the VM cannot load native code today: there is no FFI.
§40 is an idea, and its FFI is a sketch (§40.3b). This design covers pure
Agentica packages only.

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
- **Unittest.** The tests are Python `unittest` in `tests/test_packages.py`,
  standard library only, deriving from `tests.agentica_test.TestCase`. They run
  the `agentica` binary on fixture programs. CI installs git and fails if it is
  missing. Local runs may skip.
- **A peer for the hash.** The rule of 45.6 is written again in Python with
  `hashlib` and `os.walk`, so a second implementation checks the Agentica one.
- **Few tests, each one important** (CLAUDE.md, "Writing Tests"):
  1. End to end: `add`, then `install` into an empty cache, then a program
     imports `owner/repo/mod` and prints. This covers the import form, the
     cache and the lock together.
  2. Round trip: read `agentica.lock`, write it back, and compare the bytes.
     The manifest gets the same test.
  3. Failures, checked by code and not by text: a tampered file gives
     `PKG-HASH-MISMATCH`; a moved tag gives `PKG-TAG-MOVED`; a minimum raised in
     the manifest gives `PKG-LOCK-STALE`; a relative folder beside the importing
     file gives `CHECK-IMPORT-AMBIGUOUS`.
  4. Offline: with the cache filled and no `git` on `PATH`, a build still
     succeeds. This proves that a build never fetches.
  5. Import paths: a `../` that leaves a package root, and an import into a
     hidden folder or `agc_libs/` of a package, give `CHECK-IMPORT-PATH`.

### 45.12 Phases

Phase 45-0 comes first and may land before the bootstrap. The manager phases
come after §35 step 8.

- **45-0. `std/toml`.** The parser, the encoder, the goldens and the peer tests
  of 45.4 and 45.11. The PR also touches the std module list in the help text of
  `src/main.rkt` and the list in `tests/modules-test.rkt`. Row 7.2.7 allows both
  as data and messages. It adds a std/toml section to
  `docs/grammar/05b-modules.md`, a library page, a row in the programming
  skill's library references, and a `CHANGELOG.md` entry, because the module is
  new for users.
- **45a. Manifest and lock.** Read `agentica.toml` and `agentica.lock` with
  `std/toml`. Resolve `owner/repo/...` imports from the cache, with the hash
  check and the `CHECK-IMPORT-*` and `PKG-LOCK-*` checks. Packages are stored
  under their logical path (45.8). There is no fetching: the tests fill the
  cache by hand. The import resolution lands in `compiler/` only
  (`compiler/resolve_import.agc`), after step 8, when the Racket front end is
  gone. That is consistent with the freeze.
- **45b. Fetch and install.** The git fetch of the tag, the commit check, the
  hash check, the cache fill, `install`, and the fetch errors.
- **45c. Add and update.** `add`, `update`, the `@version` form, the lock writer
  and minimal version selection, with the major rules of 45.7.
- **45d. Vendor.** `vendor`, the `agc_libs/<key>/` layout, the build order that
  prefers the vendored copy, and the `pkg/` skip of 45.8.

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
- Branch or commit versions: tags only, so builds stay reproducible.
- Typed decoding into structs: not needed for the manager.
  `JSON.decode(JSON.encode(j), T)` on the output of `Toml.to_json` does it
  (45.4, question 10).
- Native packages: §40 first (45.10).

### 45.14 Open questions

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
   - **Recommendation:** A. It keeps every import that works today, and it
     makes a clash visible.

2. **The fate of today's `pkg/` roots.**
   - Option A: keep them for libraries that are installed by hand, and revisit
     after 45c.
   - Option B: replace them with the package form now.
   - **Recommendation:** A. Replacing them breaks people who install by hand,
     and nothing is gained before the manager exists.

3. **Major versions.**
   - Option A: Go's way, a `v2` segment in the path, as `owner/repo/v2/mod`. It
     can clash with folders inside the repo.
   - Option B: a new repo for each major, as `owner/sqlite-ac-v2`. The key names
     the major, and two majors can be in one build.
   - Option C: one major per build. A second major is an error.
   - **Recommendation:** B. It needs no new rule in the import form, and it has
     no clash. (This is separate from the rule of 45.7 that forbids two majors
     of one key.)

4. **Error codes and their prefix.**
   - Option A: a new `PKG-` prefix for the manifest, the lock, fetching, the
     cache and the CLI, and the `CHECK-IMPORT-*` family for import errors.
     AGENTS.md then lists the new prefix. Manifest and lock errors name the file
     and the key path, not a source span, so the diagnostic format needs a
     small change.
   - Option B: everything under `CHECK-IMPORT-*`.
   - **Recommendation:** A, with the key path. The format change is small, and
     it belongs in 45a.

5. **`dev_dependencies`.**
   - Option A: not in v1. There is one list.
   - Option B: a second table, used only by `*_test.agc` files (§36).
   - **Recommendation:** A. Add B when a test needs a package that the program
     does not.

6. **Data files in a package.**
   - Option A: only `.agc` files are used and hashed.
   - Option B: a `files` list in the manifest adds data files, such as a SQL
     schema, to the hash and to the vendored copy.
   - **Recommendation:** A. Add B when a package needs one.

7. **Hashing at build.**
   - Option A: every build hashes each package it loads, from the cache or from
     `agc_libs/`.
   - Option B: hash at install and vendor only. The build trusts the cache,
     which is read-only.
   - **Recommendation:** A. It is one rule, and it catches a changed vendored
     file. 45a measures the cost on the largest package it has.

8. **Who may run git.**
   - Option A: the package commands turn on the run grant for their own process.
     The user typed the command, and `agentica file.agc` still cannot run git.
   - Option B: the user passes `--allow-run` to the package commands.
   - **Recommendation:** A.

9. **Where `agc_libs/` sits when a manifest exists.** Recommendation: B.
   - Option A: beside the root program, as today.
   - Option B: beside `agentica.toml` when a manifest exists, and beside the
     root program otherwise, as today. The vendored paths are not reachable
     through `pkg/` (45.8).

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
    - **Recommendation:** B. The text is exact. When §41 lands, the date
      variants change: TOML's four kinds get one variant each (41.19). That is
      a breaking change of std/toml, and its design waits for §41.

12. **The toml-test corpus.**
    - Option A: vendor it under `tests/fixtures/toml-test/` with its license
      file, as `@slow` cases.
    - Option B: do not vendor it. Fetch it by hand from a pinned commit when
      needed.
    - **Decided (45-0):** A. The license is MIT, so the files are vendored.
      They are small, so they run in the fast tier, not as `@slow` cases.
