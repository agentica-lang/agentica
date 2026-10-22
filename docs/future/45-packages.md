## 45. Packages

**Status:** Built. The parts (45-0 `std/toml`, the manifest, the lock and the
cache imports of 45a, the fetch and `install` of 45b, `add`, `update` and the
writers of 45c, and `vendor` of 45d) are specified in
[`05b-modules.md`](../grammar/05b-modules.md), the contract. This file keeps
the decisions. It is item 3 of the list after 0.8.0 in the
[roadmap](../roadmap/README.md): after the FFI core (issue
[#534](https://github.com/sonic182/agentica/issues/534)) and before the native
packages (FFI-b), which are the only part left.

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

**Built (45b):** the cache layout, the stored names, the hash rule and the
fetch of `install` are in 05b. What 45b does, and what 45c adds on it:

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
  files and that manifest are copied. `install` checks the copied manifests as
  a build does (a name the lock lacks is `PKG-LOCK-STALE`, another source is
  `PKG-SOURCE-CONFLICT`). `add` and `update` read the same manifests and add the
  names the lock lacks to the lock they write (45.9).
- Two copied `.agc` paths that differ only in case are `PKG-PATH-COLLISION`, so
  the package works on case-insensitive file systems. Only case is folded: not
  Unicode normalisation (macOS) or Windows device names; the lock hash still
  catches whatever such a file system makes of them.
- A copied file is at most 1 MiB and all of them 16 MiB, else `PKG-FETCH` names
  the file and the limit: the VM keeps 1 MiB of a child's unread output, and
  the files are held in memory.
- git inherits the environment and may ask for a password on a terminal; each
  read of its output has a 5 minute deadline. Git runs in the temporary folder,
  never in the working folder. A killed install can leave a hidden `.tmp-*`
  folder in the cache root, which is safe to delete.
- A symbolic link or gitlink among the copied files is `PKG-SYMLINK`.
- The fill goes into a temporary folder that is renamed into place. If the
  target exists, its hash is checked: a match is a success, and a mismatch is
  `PKG-HASH-MISMATCH`, with nothing overwritten. Not built: the folder is not
  made read-only after the fill (there is no `chmod` builtin); every build
  hashes what it loads instead (question 7).
- Only `add`, `install`, `update` and `vendor` run git. A build never fetches.

### 45.9 Commands and errors

`install` (45b), `add`, `update` (45c) and `vendor` (45d) are built. The exact
command line is decided in each phase.

- `agentica add NAME URL --tag TAG` (or `--ref COMMIT`, the whole 40-digit id)
  adds the dependency to `agentica.toml`, rewrites the lock and fills the
  cache. **Built (45c).** The local name is always an argument (the package's
  own `name` is not read), and the options come last, in that order. Decided:
  - It adds one line to the manifest and changes no other byte, so comments,
    blank lines, key order and line endings stay. The line goes after the last
    entry of `[dependencies]`, or in a new `[dependencies]` table at the end
    of the file. The new text is read back as a manifest before anything is
    saved; a layout that the edit cannot handle (`dependencies = {}` inline, or
    dotted keys) is `PKG-MANIFEST-EDIT` and the user writes the line.
  - The lock lists every package of the build, so `add` fetches the new
    package and the dependencies in its manifest, and follows theirs. A
    locked package with the same source is kept (no git when it is cached); a
    name the lock lacks, or has with another source, is fetched. Two sources for
    one name are `PKG-SOURCE-CONFLICT`, at the manifest that asked second.
  - A name that the manifest has is `PKG-DEPENDENCY-EXISTS`: a pin changes by
    editing the manifest and `update NAME`. No manifest is
    `PKG-MANIFEST-MISSING`; `add` does not make one.
  - Nothing is written unless everything worked. The lock is written first
    (a lock with a spare package is good, a manifest the lock lacks is
    `PKG-LOCK-STALE`), then the manifest. A write that fails is `PKG-WRITE`; a
    file is written beside the old one and renamed into place, and a manifest
    that changed during the fetch is refused (`PKG-WRITE`). If only the
    manifest write fails, `agentica update` repairs the lock.
  - A name, URL, tag or commit that the manifest would refuse, and a wrong
    number of words, are usage errors (exit 2). A `--ref` that is a part of the
    id is refused: `git fetch` takes whole ids only. Tags are fetched from
    SHA-1 repositories; a SHA-256 repository works through a `--ref` only.
- `agentica install` (built, 45b) fills the cache from the lock and never
  changes the lock. A manifest that asks for more than the lock holds fails with
  `PKG-LOCK-STALE`. It takes no argument and works on the project of the working
  folder; with `--json` a success prints `{"ok":true}`, else one line for each
  package (`fetched NAME@VERSION` or `in the cache NAME@VERSION`). A project
  with no manifest is `PKG-MANIFEST-MISSING`. A cache that is already full needs
  no `git` and no network.
- `agentica update [NAME]` re-resolves one package, or all of them, from the
  manifest pins, and rewrites the lock. **Built (45c).** Decided:
  - With no name it fetches every tag pin again; with a name (a dependency of
    the manifest, else `PKG-DEPENDENCY-UNKNOWN`) only that one. A moved tag is
    the new commit in the lock, which is what `PKG-TAG-MOVED` of `install`
    asks for. A `ref` never moves, so a package pinned by a commit is not
    fetched again.
  - The result is every package of the build and no other, so a package that
    nothing asks for any more is dropped, and a lock that is missing or stale
    because the manifest was edited by hand is made right. A project with no
    dependency and no lock gets no lock.
  - The lock is the same bytes when nothing moved. The answer lists the
    `added`, `updated` and `removed` packages, or says `nothing to update`.
- `agentica vendor` copies the locked packages into `agc_libs/<name>/`, after
  it fills the missing cache entries. A CI job without network then builds from
  the copies, and the hash check proves they are the locked files. For a
  declared name, the build reads `agc_libs/<name>/` first and the cache second.
  A copy whose hash does not match is an error, never a silent fallback.
  `vendor` writes only the paths of locked packages. It leaves other files in
  `agc_libs/` alone, the `pkg/` libraries of 05b included. A declared name never
  reaches the `pkg/` search, because a `pkg/` import would load an unhashed
  copy. **Built (45d).** Decided:
  - It does what `install` does first (the same fetch, hash and manifest
    checks, the same `git` only for what the cache lacks), then copies from
    the cache, never from git: the copy is the hashed cache folder, so it is
    the locked files. It takes no argument and writes no lock.
  - The folder of a locked package is the package's to replace. A copy edited
    by hand, with a stale or added file, or a link of that name, is replaced by
    the locked files when `vendor` runs again; that is how a
    `PKG-HASH-MISMATCH` of a copy is repaired. The new copy is built in a
    hidden folder of `agc_libs/`, hashed, and swapped in with two renames.
  - It does not remove anything else. The folder of a package that is no
    longer locked stays (it is an ordinary `pkg/` library folder then), and the
    user deletes it. Not removing keeps the rule "writes only the paths of
    locked packages" and cannot delete a library installed by hand.
  - `agc_libs/` must be a real folder, never a link, and nothing is written
    through a link (`PKG-SYMLINK`). A write that fails is `PKG-WRITE`.
  - The `pkg/` library search skips `agc_libs/<name>/` for a locked name the
    importing manifest did not declare, so vendoring does not let the project
    import a package that only another package declared. The cost: a library
    installed by hand in `agc_libs/` under the name of a locked package is not
    found any more (the other roots still are).
  - The new folder is made with the ordinary mode; only its private staging
    parent is 0700. A killed `vendor` can leave `.tmp-*` or `.old-*` folders in
    `agc_libs/`, which are safe to delete.
  - The build looks at `agc_libs/<name>/` beside the manifest of the project
    for every locked name, those of packages too (the lock is one list). The
    manifest of the package is copied, so a build reads the names it declares
    from the copy. The stored names are the same as from the cache.
- The lock writer sorts the `[[package]]` tables by name and writes their keys
  in the order of 05b, so a rewrite with no change makes no diff.
- The package commands grant the run permission to their own process (45.14,
  question 8). `agentica FILE` never runs git.
- Codes of 45b, all with the lock and the key of the entry:
  - `PKG-FETCH`: git did not start or failed, the tag or the commit is not in
    the repository, a copied path is unsafe, or the cache cannot be written.
    Git's message goes in the help.
  - `PKG-TAG-MOVED`: the tag points to another commit than the lock says.
  - `PKG-PATH-COLLISION`: two copied `.agc` paths differ only in case, in a file
    or folder name.
  - `PKG-MANIFEST-MISSING`: `install` found no `agentica.toml`.

  The codes are in 05b and in the programming skill's diagnostics reference.

### 45.10 Native code

Packages are pure Agentica. A native package, such as a wrapper of the
SQLite C library, needs the FFI and a native library. The design is in
[issue #534](https://github.com/sonic182/agentica/issues/534): a prebuilt or
system library first, with its hash in the lock. Compiling at install, which
breaks "no code runs at install", comes later and needs its own grant.

### 45.11 Testing plan

**Built:** the `std/toml` tests (goldens from toml-test, an independent
`tomllib` peer, round trips), the manifest and lock tests in
`tests/test_spec_packages.py`, and the fetch tests of 45b in
`tests/test_spec_package_fetch.py` (end to end, offline, moved tag, hash
mismatch, fetch errors, links and case collisions) and the writer tests of 45c
in `tests/test_spec_package_add.py` (below), and the `vendor` tests of 45d in
`tests/test_spec_package_vendor.py` (copies and layout, a copy read before the
cache, an edited copy, other entries left alone, links, a build with no cache
and no git), which run through the CLI. The pending tests are below.

- The fetch and writer tests use a bare git repository in a temporary folder
  as the remote. 45b needs no knob of the tool: a throwaway `HOME` has a
  `.gitconfig` whose `url.<base>.insteadOf` sends `https://example.test/` to
  `file://` paths, as any user can. The commit and hash checks still apply to
  what it serves. No test touches the network or the real git config.
- Tests go through the CLI with `--json check`. They assert codes and spans, or
  file and key paths, never message text (AGENTS.md). Git tests need `git`: CI
  installs it and fails if it is missing.
- Each pending error code gets a test that asserts the code. The round trips
  of 45c compare bytes: a lock made by an independent Python writer goes
  through `update` unchanged, a lock written by `add` equals the Python
  writer's text, and a manifest keeps every byte but the new line, in several
  layouts (comments, CRLF, no final newline, sub-tables). Also: end to end (45b,
  45c: `add`, then `install`, then a program imports `pkg/name/mod` and
  prints); offline (45b: with the cache
  filled and no `git` on `PATH`, a build passes, which proves that a build never
  fetches); moved tag (45b: a fetched tag that does not peel to the locked
  commit gives `PKG-TAG-MOVED`).

### 45.12 Phases

- **45b. Fetch and install. Done.** The git fetch, the commit check, the hash
  check, the cache fill, `install` and the fetch errors (45.8, 45.9).
- **45c. Add and update. Done.** `add`, `update`, the lock writer and the
  manifest writer, with the rules of 45.7. The round trip of 45.11.
- **45d. Vendor. Done.** `vendor`, the `agc_libs/<name>/` layout, and the build
  order that prefers a vendored copy of a declared name (45.9).

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
