## 45. Packages

**Status:** Designed. The built parts (45-0 `std/toml`, and the manifest, the
lock and the cache imports of 45a) are specified in
[`05b-modules.md`](../grammar/05b-modules.md), the contract. This file keeps
the decisions and what is pending (45b to 45d). It sits on the path to the JIT:
after the native Windows and macOS builds (issue
[#344](https://github.com/sonic182/agentica/issues/344)) and before the FFI
(issue [#534](https://github.com/sonic182/agentica/issues/534)).

Decided by the owner:

- 2026-10-15: `std/toml` comes first. The manifest and the lock are TOML.
  `Toml.parse` returns the enum `Toml.Value`.
- 2026-10-20 (issue
  [#468](https://github.com/sonic182/agentica/issues/468)): a dependency has a
  local name, a git source and a pin, a `tag` or a `ref` (a commit). The import
  is `pkg/<name>/<module path>`. The lock pins each dependency to a commit and a
  hash. There is no semver and no minimal version selection.
- 2026-10-20: the answers to the questions of 45.14.

### 45.2 Goals

- **Reproducible builds.** The same manifest and lock give the same source
  bytes. Each package file is checked by a hash.
- **No code runs at install.** Installing only copies files. npm runs lifecycle
  scripts, and pip has run `setup.py` at install. This design does not.
- **One import form.** A package has one local name, and `pkg/<name>/<module>`
  is the only way to import it. The name does not depend on the URL.
- **Offline after one fetch.** A package in the cache, or vendored, needs no
  network to build.
- **Hermetic tests.** A local git repository stands in for the remote (45.11).

Not in v1: a central registry, a version solver and publishing commands (45.13).

### 45.3 Import form

**Built.** The rules are in [05b](../grammar/05b-modules.md), Packages. The
decisions on the form are in 45.14, questions 1 and 2.

### 45.4 The TOML parser: `std/toml` (45-0)

**Built.** The API, the errors and the limits are in
[05b](../grammar/05b-modules.md), TOML. The shape of `parse` and the datetime
form are decided in 45.14, questions 10 and 11.

### 45.5 Manifest and style

**Built.** The manifest is in [05b](../grammar/05b-modules.md), Packages.

- The manifest is the nearest `agentica.toml` going up to the root of the file
  system, so an unrelated file in a shared parent folder (such as `/tmp`)
  counts. This is a known, breaking choice (CHANGELOG).
- A package's `name` is the default local name that `agentica add` (45c)
  proposes. Nothing checks it against the names that others give it.

**Pending: the `[style]` rule.** `max_line_width` is the longest line allowed,
in characters (Unicode code points, not bytes). It counts every line, comments
and doc comments included. With no `max_line_width` there is no limit. A line
over it is an error, never a warning (section 26). `agentica check` reports it
as `CHECK-LINE-TOO-LONG`, at the first character past the limit. The code is
proposed in §47.2 and owned by phase 28 (47c), which moves the check there; the
owner confirms it. `tests/test_style_line_width.py` enforces the limit for
this repository. `agentica fmt` does not enforce it: a line it cannot break
stays long.

### 45.6 Lock and hash

**Built.** The lock layout, the hash rule and the stale checks are in
[05b](../grammar/05b-modules.md), Packages. Pending: the lock writer (45c,
45.9).

The lock keeps `git` and the pin as the manifests write them, not the URL after
a git `url.<base>.insteadOf` rewrite, so the lock does not depend on one
machine's git config.

### 45.7 Pins and sources

- A pin is a git tag or a commit. The tool does not read a tag as a version and
  does not order tags. There are no branches and no version ranges, so a build
  never follows a moving target.
- One name, one source, and the error codes: see 05b.
- A release changes nothing by itself. Only `add` and `update` write the
  lock (45.9).
- Two incompatible majors of one library can be used together under two names
  (two packages, see 05b).
- A moved tag: when a fetched tag does not peel to the locked commit, the fetch
  fails with `PKG-TAG-MOVED` (45b). The lock is never changed silently.

### 45.8 Fetching and the cache

The cache layout, the stored names and the hash rule are built (05b). The fetch
is pending (45b):

- Git runs as the system `git`, so the user's git config, SSH keys and
  credential helpers apply. The tool has no HTTP client and keeps no tokens. The
  `git` value is fetched as written; a `url.<base>.insteadOf` setting can send
  it to SSH, and the lock still keeps the value as written (45.6).
- The fetch is a depth-1 fetch of the tag `refs/tags/<tag>` (or of the commit,
  for a `ref`) into a bare temporary repository. No working tree is made, so no
  checkout hook runs. The peeled commit must equal the lock's `commit`.
- The files are read from that commit's tree with `git ls-tree` and
  `git cat-file`, so `.gitattributes` does not change the bytes.
- The package's `agentica.toml` is read from the commit tree. Only its `.agc`
  files and that manifest are copied. The manifest is checked as a manifest, and
  its `[dependencies]` must agree with the lock when `add` or `update` writes
  it: a different source is `PKG-SOURCE-CONFLICT`, and a name the lock lacks is
  added to the lock.
- Two copied `.agc` paths that differ only in case are `PKG-PATH-COLLISION`, so
  the package works on case-insensitive file systems.
- A symbolic link or gitlink among the copied files is `PKG-SYMLINK`.
- The fill goes into a temporary folder that is renamed into place. If the
  target exists, its hash is checked: a match is a success, and a mismatch is
  `PKG-HASH-MISMATCH`, with nothing overwritten. The folder is read-only after
  the fill.
- Only `add`, `install`, `update` and `vendor` run git. A build never fetches.

### 45.9 Commands and errors

Pending (45b to 45d). The exact command line is decided in each phase.

- `agentica add NAME URL` with a `tag` or a `ref` adds the dependency to
  `agentica.toml`, rewrites the lock and fills the cache.
- `agentica install` fills the cache from the lock and never changes the lock.
  A manifest that asks for more than the lock holds fails with
  `PKG-LOCK-STALE`.
- `agentica update [NAME]` re-resolves one package, or all of them, from the
  manifest pins, and rewrites the lock.
- `agentica vendor` copies the locked packages into `agc_libs/<name>/`, after
  it fills the missing cache entries. A CI job without network then builds from
  the copies, and the hash check proves they are the locked files. For a
  declared name, the build reads `agc_libs/<name>/` first and the cache second.
  A copy whose hash does not match is an error, never a silent fallback.
  `vendor` writes only the paths of locked packages. It leaves other files in
  `agc_libs/` alone, the `pkg/` libraries of 05b included. A declared name never
  reaches the `pkg/` search, because a `pkg/` import would load an unhashed
  copy.
- The lock writer sorts the `[[package]]` tables by name and writes their keys
  in the order of 05b, so a rewrite with no change makes no diff.
- The package commands grant the run permission to their own process (45.14,
  question 8). `agentica FILE` never runs git.
- Pending codes, with the meaning of each:
  - `PKG-FETCH`: git failed, or the tag or the commit is not in the repository.
    Git's message goes in the help.
  - `PKG-TAG-MOVED`: the tag points to another commit than the lock says.
  - `PKG-PATH-COLLISION`: two copied `.agc` paths differ only in case, in a file
    or folder name.

  The built codes are in 05b and in the programming skill's diagnostics
  reference.

### 45.10 Native code

Packages are pure Agentica. A native package, such as a wrapper of the
SQLite C library, needs the FFI and a native library. The design is in
[issue #534](https://github.com/sonic182/agentica/issues/534): a prebuilt or
system library first, with its hash in the lock. Compiling at install, which
breaks "no code runs at install", comes later and needs its own grant.

### 45.11 Testing plan

**Built:** the `std/toml` tests (goldens from toml-test, an independent
`tomllib` peer, round trips) and the manifest and lock tests in
`tests/test_spec_packages.py`, which run through the CLI. The pending tests are
below.

- The fetch and writer tests use a bare git repository in a temporary folder
  as the remote. A test-only base URL knob (`AGENTICA_PKG_ROOT`, proposed) sends
  git to `file://` paths. The commit and hash checks still apply to what it
  serves. No test touches the network.
- Tests go through the CLI with `--json check`. They assert codes and spans, or
  file and key paths, never message text (AGENTS.md). Git tests need `git`: CI
  installs it and fails if it is missing.
- Each pending error code gets a test that asserts the code. Also: a round trip
  of `agentica.lock` and `agentica.toml` (read, write back, same bytes; 45c);
  end to end (45b, 45c: `add`, then `install` into an empty cache, then a
  program imports `pkg/name/mod` and prints); offline (45b: with the cache
  filled and no `git` on `PATH`, a build passes, which proves that a build never
  fetches); moved tag (45b: a fetched tag that does not peel to the locked
  commit gives `PKG-TAG-MOVED`).

### 45.12 Phases

- **45b. Fetch and install.** The git fetch, the commit check, the hash check,
  the cache fill, `install` and the fetch errors (45.8, 45.9).
- **45c. Add and update.** `add`, `update`, the lock writer and the manifest
  writer, with the rules of 45.7. The round trip of 45.11.
- **45d. Vendor.** `vendor`, the `agc_libs/<name>/` layout, and the build order
  that prefers a vendored copy of a declared name (45.9).

Each phase updates [`05b-modules.md`](../grammar/05b-modules.md), the
programming skill and the CHANGELOG, because import behavior changes for users.

### 45.13 Not now

- A central registry: git hosts already hold the packages.
- Private registries: git's own login covers private repositories.
- Publishing commands: a release is a tag.
- Signatures: the commit and the hash come first. Signed tags can follow.
- Workspaces and monorepos: one manifest per project in v1.
- Branches and version ranges: a pin is a tag or a commit.
- Sources other than git, such as a local path.
- Typed decoding into structs: `JSON.decode(JSON.encode(j), T)` on the output of
  `Toml.to_json` does it (45.14, question 10).
- Native packages: the FFI first (45.10, issue
  [#534](https://github.com/sonic182/agentica/issues/534)).

### 45.14 Open questions

All decided by the owner on 2026-10-15 or 2026-10-20. Each line gives the
decision, then the rejected options.

1. **Import form.** `pkg/<name>/<module>` with a local name, and a declared name
   is searched first. Rejected: `owner/repo/mod`, which clashes with local
   folders and needs an ambiguity rule; `./` for relative imports, which breaks
   every relative import.
2. **The `pkg/` roots.** Kept for libraries installed by hand; revisit after
   45c. Rejected: replacing them, which breaks those installs and gains nothing
   before the manager exists.
3. **Major versions.** No semver and no major-version rule. One name has one
   source, and two majors can be used under two names. Rejected: semver with
   minimal version selection, a `v2` path segment (it clashes with folders in
   the repository) and one major per build.
4. **Error codes.** A `PKG-` prefix for the manifest, the lock, fetching, the
   cache and the CLI. Manifest and lock errors name the file and the key path.
   Rejected: all errors under `CHECK-IMPORT-*`.
5. **`dev_dependencies`.** None in v1; there is one list. Rejected: a second
   table for `*_test.agc` files, which can be added when a test needs it.
6. **Data files.** Only `.agc` files and native libraries (issue
   [#534](https://github.com/sonic182/agentica/issues/534)) are used and
   hashed. The manifest of a package is kept but not hashed. Rejected for v1: a
   `files` list in the manifest.
7. **Hashing at build.** Every build hashes each package it loads, so a changed
   vendored file is caught. Rejected: hashing only at install and vendor, which
   trusts the cache.
8. **Who may run git.** The package commands turn on the run grant for their own
   process. `agentica FILE` never runs git. Rejected: a `--allow-run` flag that
   the user passes to the package commands.
9. **Where `agc_libs/` sits.** Beside `agentica.toml` when a manifest exists,
   and beside the root program otherwise. Rejected: always beside the root
   program.
10. **The shape of `parse`.** The enum `Toml.Value`. Rejected: a `Json` value,
    which loses TOML's types and cannot be matched with `case`, and typed
    decoding straight into structs, which a std module cannot do (no type
    argument). `JSON.decode(JSON.encode(j), T)` on `Toml.to_json` gives the same
    result.
11. **Datetimes.** `DateTime(String)` keeps the text as written. Rejected: an
    RFC 3339 string in `Text`, because a round trip would write the datetime in
    quotes. When §41 lands, the variant splits into four, one per TOML kind
    (41.19). That is a breaking change of `std/toml`.
12. **The toml-test corpus.** Vendored under `tests/fixtures/toml-test/` with
    its MIT license, in the fast tier. Rejected: fetching it by hand.
