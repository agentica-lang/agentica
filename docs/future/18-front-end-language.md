## 18. Front-end implementation language

**Status:** decided and done. On 2026-10-13 the owner chose self-hosting in
Agentica for one binary and a fast start; the port landed through roadmap row
7.2.7, release 0.4.0 was the first with the self-hosted front end as its
default, and the Racket front end was deleted on 2026-10-16 (PR #313; the
parent commit of that merge is tagged `bootstrap-racket`). No Makefile target,
CI job or release step runs `racket` or `raco`. This file is the record of that
decision, of the method, and of what remains; live status is in
[`docs/roadmap/README.md`](../roadmap/README.md).

### 18.1 Decision

- While syntax was still changing, maintaining two front ends would double the
  work of every language change. Racket stayed the parity reference until 7i;
  golden-output tests replaced it when the evaluator was removed.
- Self-hosting gives the one-file distribution and dogfooding: the compiler
  becomes the biggest Agentica program there is.
- Baseline the goals were set against, measured on Linux x86_64 with Racket CS
  9.3 on 2026-10-13: `raco exe --orig-exe` produced a 68 MB executable (14 MB
  as `.tar.xz`) but startup stayed at about 570–630 ms in every mode, and the
  release was about 89 MB in three files (`dist/runtime/` from
  `raco distribute`). A proof embedded the VM bytes in the Racket executable
  (+144 KB) and unpacked them on first run; loading the VM as a shared library
  through the FFI was rejected (two garbage collectors, clashes over `exit` and
  stdio).

### 18.2 Bootstrap

The owner decided the plan on 2026-10-14. Each stage of the port was one PR,
checked against the Racket stage over the whole corpus, with goldens under
`tests/fixtures/frontend/<stage>/`: stage1 (the front end in `compiler/`,
compiled by Racket, later by `bootstrap/stage0.agcb`), stage2 (self-hosted,
byte-identical to stage1), then Embed (stage2 goes into the binary as data).
Determinism is a requirement: no timestamps, and source paths relative to the
entry file's folder. Refresh, fixed-point and format-version rules are in the
development skill's `references/ci.md`, "The checks of ci.yml…".

### 18.3 Port

Steps 1 (lexer), 2 (parser, with `PARSE-TOO-DEEP`), 3 (modules and linker),
4 (builtin catalog and checker, with `CHECK-TOO-DEEP`), 5 (lowering, with
module constants), 6 (bytecode writer), 7 (BDD driver) and 8 (command line,
single binary, goldens, the test suite and CI) are done; the per-PR record is
in git history (PRs #237 to #311, then #313; row 7.2.7 of the roadmap). Source
paths are stored relative to the entry file's folder.
Each stage carries its diagnostics and dumps (`--dump`, `--dump-ir`)
so a compiler bug is visible as a runtime error in `compiler/`, reported as an
internal code with a stack trace (roadmap 14b).

### 18.4 Prerequisites

The port needed these, all now part of the language or the VM (grammar and
`docs/vm/` are the current homes): O(1) `push`/`+=`, an efficient `Map`, JSON
key listing, file/dir/path builtins, `System.env`, binary output, process
spawning, call depth and stack traces, and the BDD driver builtins. The
isolation decisions (random names, lossy names, the 1 MiB capture, signals,
`TMPDIR`) are in [`docs/bdd.md`](../bdd.md), "Isolation and process
lifetime".

### 18.5 Goals and targets

- **One file.** The release archive has one executable, `bin/agentica`, with no
  `runtime/` directory, and needs only glibc (2.28 or newer).
- **Fast start (a target, not a condition; open).** `agentica check
  examples/hello.agc` at most 30 ms and 30 MB of peak RSS; `agentica check
  stdlib/bdd/gherkin.agc` at most 100 ms. The owner decided on 2026-10-15 that
  the bootstrap goes ahead even if the Agentica front end is slower than
  Racket, so these numbers are measured after it and are not a condition. The
  speed pass and the current numbers are roadmap row 3 and
  [`docs/vm-benchmarks.md`](../vm-benchmarks.md).
- **Same results, same diagnostics.** Every golden and test passes with no
  `make goldens` diff, and every diagnostic keeps its code and span.

### 18.6 Order

What is left of the port is the post-bootstrap work in
[`docs/roadmap/README.md`](../roadmap/README.md): the parser pass of the speed
targets, `agentica doc`, and the package system, FFI and JIT path
([§40.5](40-native-code.md#405-order)).

### 18.7 Tests

The suite is Python, standard library only (the repository rules in
`AGENTS.md`; design and make targets in the development skill's
`references/ci.md`).

### 18.8 Distribution

`agentica` is the VM binary with the front end inside: one assembly file built
with `.incbin` carries the compiled front end (stage2) and every `stdlib/`
source, with the module list in `stdlib/MODULES` and the layout in
`vm/embedded.h`. `agentica run` runs a compiled `.agcb`; the separate
`agentica-vm` and the `AGENTICA_VM` override are gone (breaking, in the
changelog). The BDD runner and default steps (`compiler/embedded/`) are embedded
too, so `agentica test` compiles nothing on each run. The release links the
static libraries and keeps `LICENSE`, `NOTICE` and `licenses/`, without Racket's
or Chez Scheme's files.

### 18.9 Decided against

- **Embed Racket CS in the VM binary** (`racketcs.h`, `raco ctool --c-mods`):
  one file, but it fixes neither start-up nor the 40 to 60 MB size.
- **Port the front end to Chez Scheme:** it embeds small and starts fast, but it
  is a full port with no lasting gain over self-hosting.
- **Rewrite in OCaml:** the best option outside Agentica (ADTs and pattern
  matching fit the stages; native, small, about 5 ms start-up), but it adds a
  toolchain and a second language to maintain forever.
- **Rewrite in Rust:** the same cost as OCaml, with slower builds.
- **Rewrite in Go:** no sum types, so the AST and the checker fit it badly.
- **`raco exe --orig-exe` as an interim single file:** one 68 MB file that still
  started in about 0.6 s; the owner waited for self-hosting instead.
- **A musl (Alpine) build:** stays separate from the glibc release.
