## 45. Packages

**Status:** Built. The parts (45-0 `std/toml`, the manifest, the lock and the
cache imports of 45a, the fetch and `install` of 45b, `add`, `update` and the
writers of 45c, the `deps/` folder of #578, and the native libraries of 45.10)
are specified in [`05b-modules.md`](../grammar/05b-modules.md), the contract.
This file keeps the decisions.

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
- **Offline after one fetch.** A package in `deps/` needs no network and no
  cache to build.
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
- A package's `name` is only a hint for the local name: `agentica add` (45c)
  takes the local name as an argument and never reads it. Nothing checks it
  against the names that others give it.

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
[05b](../grammar/05b-modules.md), Packages. The lock writer is built (45c,
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

**Built (45b).** The cache layout, the fetch, the limits and the codes are in
[05b](../grammar/05b-modules.md), Packages. The reasons behind the choices:

- Git runs as the system `git`, so the user's git config, SSH keys and
  credential helpers apply; the tool has no HTTP client and keeps no tokens.
- The fetch goes into a bare temporary repository with no working tree, so no
  checkout hook runs, and the files are read from the commit's tree
  (`git ls-tree`, `git cat-file`), so `.gitattributes` does not change the
  bytes.
- Only case is folded for `PKG-PATH-COLLISION`, not Unicode normalisation or
  Windows device names; the lock hash catches whatever a file system makes of
  them.
- The cache folder is not made read-only (there is no `chmod` builtin); every
  build hashes what it loads instead (45.14, question 7).
- Only `add`, `install` and `update` run git. A build never fetches.

### 45.9 Commands and errors

**Built.** `install` (45b), `add` and `update` (45c) and `deps/` (#578, 45d):
the command lines, the files they write and the `PKG-` codes are in
[05b](../grammar/05b-modules.md) and the programming skill. Decided:

- `add` adds one line to the manifest and changes no other byte (comments, key
  order and line endings stay); a layout it cannot edit is `PKG-MANIFEST-EDIT`,
  and the user writes the line. The local name is always an argument; the
  package's own `name` is not read.
- Nothing is written unless everything worked: the lock first (a lock with a
  spare package is good, a manifest the lock lacks is `PKG-LOCK-STALE`), then
  the manifest, each beside the old file and renamed into place.
- `install` never changes the lock; only `add` and `update` write it, and an
  unchanged `update` writes the same bytes. The lock writer sorts packages by
  name and keys in the order of 05b, so a rewrite with no change makes no diff.
- `deps/` is Elixir-style: the packages of a project are in `deps/` beside
  `agentica.toml`, the compiled programs in `_build/`, and the global cache is
  only a download cache. A build reads a declared `pkg/<name>` only from
  `deps/<name>/`, never from the `pkg/` search, because that would load an
  unhashed copy. Committing `deps/` is the project's choice: the tool writes no
  `.gitignore` there.
- The package commands grant the run permission to their own process (45.14,
  question 8). `agentica FILE` never runs git.

### 45.10 Native code

**Built (FFI-b, issue
[#534](https://github.com/sonic182/agentica/issues/534)).** The rules are in
[05b](../grammar/05b-modules.md), Packages. Packages stay pure Agentica unless
the manifest names a native library. Decided (2026-10-23, the smallest rule
that works on Linux, macOS and Windows):

- **Declaration.** `[native.NAME]` in the manifest of the package, one inline
  table per system (`linux`, `macos`, `windows`) with `file` (a path in the
  package's `native/` folder) or `system` (a name for the loader). The key is
  the operating system only, because `System.os()` is all the front end can
  ask: a macOS library is a universal binary (`lipo`), and the VM supports one
  Linux architecture. The tables are inline so that a later `url` and `sha256`
  (a downloaded prebuilt library, issue
  [#594](https://github.com/sonic182/agentica/issues/594) H) is one more key.
- **Lookup.** `extern "NAME"` in a file of the package means that entry. The
  front end rewrites the library to an absolute path in `deps/<package>/`
  while it links, so no search is involved and `LD_LIBRARY_PATH` plays no
  part. The VM and the lowering are unchanged. A name the manifest does not
  declare is a system name as before, so no program changes meaning.
- **Hash.** The hash of the package covers every file of its `native/` folder
  (dotfiles, `Thumbs.db` and `desktop.ini` aside), for all systems, next to
  the `.agc` files, and the package's `agentica.toml` when `native/` holds a
  file that is not `.agc` or there is a `[native]` table, because the manifest
  decides which file is opened
  (any other package hashes as before). The lock format is unchanged, and a
  changed library or manifest is `PKG-HASH-MISMATCH` at `package[n].hash`,
  from the same check and the same fetch as the source.
  A hash for each system in the lock was weighed: it would add a lock table,
  its writer and its stale checks to say less than the one hash says.
- **Cache.** For a package, the bytecode cache entry holds the digest of the
  manifest (when hashed), of every file of `native/` and of the list of their
  names; for the project, only of the files its `[native]` declares. So a
  changed file is a miss and the build hashes the package again. The bytecode
  of `compile` holds the absolute path, and `run -- file.agcb` opens it with
  no check.
- **Errors.** `PKG-NATIVE-PLATFORM` (no entry for the running system) and
  `PKG-NATIVE-MISSING` (the file is not in the package), at the manifest and
  the key path, only where a file of the package uses the name.
- **Grants.** Nothing changes: the result is an ordinary extern function, so
  `--deny-native` and `--sandbox` refuse it. No code runs at install.
- **Size.** A file of a package is at most 1 MiB, the library included, so
  a larger library is a `system` name until downloaded libraries exist.

Compiling at install, which breaks "no code runs at install", and downloading
prebuilt libraries (a URL and a hash for each system) come later, each with its
own grant or lock key.

### 45.11 Testing plan

**Built.** The tests are `tests/test_spec_packages.py`,
`test_spec_package_fetch.py`, `test_spec_package_add.py` and
`test_spec_package_deps.py`, through the CLI. The decisions that stay:

- The remote is a bare git repository in a temporary folder: a throwaway `HOME`
  has a `.gitconfig` whose `url.<base>.insteadOf` sends `https://example.test/`
  to `file://` paths, as any user can, so the tool needs no test knob and the
  commit and hash checks still apply. No test touches the network or the real
  git config.
- The writers of 45c are checked by byte round trips against an independent
  Python writer (`update` keeps its lock unchanged; `add` writes its text; a
  manifest keeps every byte but the new line, in several layouts).
- A build with the cache filled and no `git` on `PATH` passes, which proves
  that a build never fetches.

### 45.12 Phases

45-0, 45a, 45b (fetch and `install`), 45c (`add`, `update`), 45d (`deps/`) and
native libraries (FFI-b, 45.10) are done.

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
- Compiling a native library at install, and downloaded prebuilt libraries
  (45.10).

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
6. **Data files.** Only `.agc` files and the files of `native/` (45.10) are
   used and hashed. The manifest of a package is hashed only with a native
   file or a `[native]` table (45.10). Rejected for v1: a `files` list in the
   manifest.
7. **Hashing at build.** Every build hashes each package it loads, so a changed
   file of `deps/` is caught. Rejected: hashing only at install, which trusts
   `deps/`.
8. **Who may run git.** The package commands start it from their own process.
   `agentica FILE` never runs git.
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
