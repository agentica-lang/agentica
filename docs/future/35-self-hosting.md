## 35. Self-hosted front end and a single binary

**Status:** planned, in the order of
[`docs/roadmap/README.md`](../roadmap/README.md). Decided by the owner on
2026-10-13: the front end is rewritten in Agentica, compiled to bytecode and
embedded in the VM binary. The release then ships one file: `agentica-vm`,
renamed to `agentica`. Racket is needed only to make the first bootstrap file.
On 2026-10-14 the owner put the port in the order: it starts at row 7.2.7 (the
freeze of the Racket front end), after rows 8 and 7.2.4 to 7.2.6
([§35.9](#359-order)). It settles the question that
[§18](18-front-end-language.md) left open.

The idea in one paragraph: the owner wants one binary to distribute and a fast
start. Today Racket gives neither. The front end (lexer, parser, linker,
checker, lowering, bytecode writer, BDD driver, CLI) is ported to Agentica one
stage at a time. Each stage is checked against the Racket stage on the whole
corpus. When all stages are ported, the Racket front end compiles the new front
end once, the new front end compiles itself, and its output must not change (a
fixed point). A compiled front end is checked in as `stage0`, so a build needs
no Racket. The VM binary carries the compiled front end and the `std/` sources
as data.

### 35.1 Today

Measured by the owner on master on 2026-10-13:

- `agentica check hello.agc` takes about 0.5 s and 148 MB of RSS. Almost all of
  it is Racket start-up.
- The release is about 89 MB: `dist/agentica` is 17 MB, `dist/runtime/` (from
  `raco distribute`) is 66 MB, and `agentica-vm` is 7 MB.
- The Racket front end is about 5,600 lines after 7i: `src/lexer.rkt`,
  `parser.rkt` (with `ast.rkt`), `modules.rkt`, `checker.rkt` (with
  `builtins.rkt` and `builtin-types.rkt`), `lower.rkt`, `bytecode.rkt`,
  `main.rkt` and `bdd-driver.rkt`, plus the shared `source.rkt`, `token.rkt`,
  `diagnostic.rkt`, `version.rkt` and `vm-launch.rkt`. 7i removes
  `runtime-values.rkt` with the other runtime modules, so it is not ported.
- `src/main.rkt` compiles to a 0600 temporary `.agcb` and starts `agentica-vm`
  as a child. `agentica test` starts a runner VM written in Agentica
  (`docs/bdd.md`), so part of the tool is already Agentica.
- An `.agcb` holds the format version (5), the Agentica version, and the path
  and full text of every source file (`write-program`, `src/bytecode.rkt:203`).
  The paths are absolute (`path->complete-path`, `src/modules.rkt:9,15,26`). The
  loader rejects a file built for another Agentica version (`vm/loader.c:402`).

### 35.2 Goal and success criteria

The work is done when these hold (the fast start below is a target, not a
condition):

- **One file.** The release archive has one executable, `bin/agentica`, and no
  `runtime/` directory. It needs only glibc (2.28 or newer), as `agentica-vm`
  does today (35.6).
- **Fast start (a target, not a condition).** `agentica check
  examples/hello.agc` should take at most 30 ms of wall time and at most 30 MB
  of peak RSS. `agentica check stdlib/bdd/gherkin.agc`, the largest file in the
  corpus today (575 lines), should take at most 100 ms. The owner decided on
  2026-10-15 that the bootstrap (steps 5 to 8) goes ahead even if the Agentica
  front end is slower than Racket: these numbers are not a condition for "the
  work is done" or for step 8. They are targets that are measured and tracked
  after the bootstrap, and optimisation comes after it. Candidates: the cost of
  VM calls and of `.with`, a VM profiler, module constants (section 44), and
  the JIT of roadmap row 9.1. To measure them, extend the start-up check of
  `benchmarks/run.py` (`startup()`, which times `hello.agc` today; `make
  bench`) with these two commands, and record the numbers and the baseline
  machine in `docs/vm-benchmarks.md`. CI does not gate on time, because CI
  machines are noisy.
- **Same results.** Every golden fixture and every test passes with no
  `make goldens` diff.
- **Same diagnostics.** The same code and the same span for every diagnostic in
  the corpus and in the tests. Message texts stay the same too, unless a PR
  changes one on purpose and says so.

### 35.3 Bootstrap

**stage1** is the Agentica front end (a new top-level `compiler/` directory)
compiled by another compiler: Racket at first, `stage0` later.

1. **Stage 1.** The Racket front end compiles `compiler/` to `stage1.agcb`.
2. **Fixed point.** `stage1` compiles `compiler/` to `stage2.agcb`, and `stage2`
   compiles it again to `stage3.agcb`. `stage2` and `stage3` must be equal byte
   for byte. While Racket exists, Racket's `stage1` must also equal `stage2`,
   since the two front ends must emit the same bytes (35.4, step 6).
3. **Embed.** From step 8, `stage2` goes into the VM binary as data (35.6). The
   binary is now a full `agentica`.
4. **stage0.** A fixed-point output is checked in as `bootstrap/stage0.agcb`
   once the self-hosted front end is the default. From then on `stage0` takes
   Racket's place in step 1. A clone builds without Racket. It still needs what
   the VM build needs today: make, perl for OpenSSL, and the submodules.

**Front-end inputs.** The front end's entry point takes two inputs besides the
user's arguments: the Agentica version, and a provider of `std/` sources. There
are two providers:

- **Embedded** (from step 8): C passes the version and grants the guarded
  builtins (35.5), which read the embedded `std/` sources and hand the compiled
  program to C.
- **Ordinary run**: the front end is an ordinary `.agcb` run by the VM, as in
  steps 3 to 7 and in the bootstrap before step 8. The version and the path of a
  `stdlib/` folder are passed as arguments, and the front end reads the sources
  with the `File` builtins. When Racket's `main.rkt` starts the step-7 BDD
  driver, it writes the `std/` sources into the driver's private temporary
  folder and passes that path.

The step-7 BDD driver's `.agcb` is built once at `make exe` time and shipped in
the release archive until step 8 (owner decision). It is never compiled on each
run.

**How `make` builds it.** Before step 8, `make` runs the stages as ordinary
programs on `agentica-vm`: Racket compiles `stage1`, then `stage1` and `stage2`
each compile `compiler/`, and `make` compares `stage2` with `stage3`. From step
8, a build-only flag, `--front-end FILE.agcb`, makes the binary load `FILE` as
its front end in place of the embedded one, with the embedded provider. `make`
links a first binary with `stage0` and the `std/` sources embedded, uses it to
compile `stage1`, uses `--front-end` with `stage1` and then `stage2` to compile
`stage2` and `stage3`, checks that they are equal, and links the final binary
with `stage2` embedded. The flag is for the build and the tests only; the CLI
help does not list it.

**Checked in, not built from a release.** A release-built stage0 means
downloading the previous release to build, which needs the network, a previous
release for every platform, and a VM that still reads that file's format. A
checked-in file keeps the build hermetic and offline, like CI today, and works
in the private alpha, which has no stable releases to rely on. Zig (`zig1.wasm`)
and OCaml (`boot/ocamlc`) do the same.

The release cut right before step 8 (35.4) is a fixed reference point. It does
not replace the checked-in stage0.

**Versions.** The loader checks the format version of every program. It checks
the Agentica version of every program except the front end that C loads itself:
the embedded one, or the file given to `--front-end`. So a version bump does not
break the committed stage0, and stage0 is never refreshed for a version bump.
The version is not a constant in `compiler/`: it is an input of the entry point,
and the front end writes it into each `.agcb` header. So `stage2` and `stage3`,
made in the same build, carry the same version, and the fixed-point check
compares whole files. The committed stage0 is a seed, not compared with
`stage2`.

**When stage0 changes.** Only when `compiler/` needs something stage0 cannot
compile. Not on every compiler change. Each case takes two steps:

- **New syntax.** First, one PR teaches the compiler the syntax without using it
  in `compiler/`, and refreshes stage0 from the new compiler. Then a later PR
  uses the syntax in `compiler/`.
- **A builtin or C-interface change** that stage0 uses: the same two steps.
  First the VM adds the new form next to the old one and stage0 is refreshed
  from a compiler that uses it. Then a later PR removes the old form.
- **New `.agcb` format.** The old stage0 on the old VM compiles the new compiler
  (whose writer emits the new format). Then that compiler compiles itself, which
  gives the new stage0 in the new format. `make stage0` does both steps in a
  temporary worktree of the parent commit.

A refresh PR shows the source diff that made stage0 change, and CI checks the
fixed point from the committed stage0.

**When Racket can be deleted.** When all of these hold:

- every step of 35.4 is done, and the self-hosted front end has been the default
  in one release;
- the fixed point runs in CI from the committed stage0;
- the per-stage goldens (35.4) pass without the Racket stages;
- no Makefile target, CI job or release step runs `racket` or `raco`, the test
  suite included (`make version` reads the plain version file of step 8, and
  the tests reach the binary alone at
  [§35.10](#3510-tests-move-to-python-unittest) phase 3);
- `vm/tools/gen-unicode.rkt` is ported (its output, `vm/unicode_data.c`, stays
  checked in).

Then one PR deletes `src/*.rkt` and the `raco distribute` release steps, and
tags the parent commit `bootstrap-racket`, the last commit that can make a
stage0 from Racket. It changes no test: the test rewrite is done before it, in
[§35.10](#3510-tests-move-to-python-unittest) phases 1 to 3. Today 23 of the 51
`tests/*.rkt` files require `src/` modules directly (16 of the 43 `*-test.rkt`).
The per-file rewrites that this section used to list (`cli-in-process.rkt`,
`compile-file` in `vm-diff-common.rkt`, the site examples, the latency and trace
tests, `bdd-integration.rkt`, now `tests/test_bdd_integration.py`) are phase 1
and 2 work there.

Replacing rackunit is decided: Python `unittest`, standard library only, in
phases that run beside steps 4 to 8
([§35.10](#3510-tests-move-to-python-unittest)). Phase 3 is the step-8 PR.

### 35.4 Stages to port

One PR per step, in this order, each with differential tests against the Racket
stage. This is the method of 21c to 21e (`docs/bdd.md`): during development a
throwaway harness runs both stages over the whole corpus and compares their
output; CI gets golden fixtures. The corpus is `examples/`, `stdlib/`,
`tests/fixtures/`, the site examples, and every input of
`tests/<stage>-test.rkt`, diagnostics included. Each golden is the Racket
stage's output in a stable text form under `tests/fixtures/frontend/<stage>/`.
While both stages exist, both must match it. After Racket is deleted, the
goldens stay.

| Step | Racket stage | Compared output |
|---|---|---|
| 1 | **Done** (PR #237): Lexer (`src/lexer.rkt`, with `source.rkt`, `token.rkt` and the diagnostic data of `diagnostic.rkt`) | Tokens as text lines (kind, value, span), or the one `LEX-` diagnostic |
| 2 | **Done** (PR #245): Parser (`src/parser.rkt`, `ast.rkt`) | The AST in a stable text form, or the `PARSE-` diagnostic. Today `--dump` is Racket's `pretty-print` of the checked tree, so step 2 adds a printer with the same output on both sides (`tests/frontend-parser-common.rkt`) |
| 3 | **Done** (PR #254): Modules and linker (`src/modules.rkt`, `stdlib.rkt`) | The linked program dump, with `std/` and `pkg/` resolution, or the first `CHECK-IMPORT-*`, `CHECK-DECL-ORDER` or `CHECK-REDEFINED-NAME` diagnostic with its file. Needs the environment and real-path builtins (35.5). It carries the privacy rule of `value.with(...)` (roadmap 15c) as data: each linked module lists the user structs it may update, and the text form prints the list on every update. The text form is `tests/frontend-modules-common.rkt` (Racket) and `compiler/link.agc` (Agentica) |
| 4 | **Done** (4a, the builtin catalog as Agentica data, PR #258; 4b, the checker, PR #263; module constants, §44, in PR 44a2-1, with `compiler/check_const.agc` and `compiler/const_walk.agc`): Checker (`src/checker.rkt`, `builtins.rkt`, `builtin-types.rkt`) | The `CHECK-` diagnostic, and the type of each expression. The port must carry `CHECK-DECL-ORDER` (imports, then constants, then `struct` and `enum`, then `export def`, then `def`, in every file), which the Racket front end checks per file in `src/modules.rkt` before linking; the module port (step 3) and this one keep its span (the start of the first declaration out of place). It must also handle `Set[T]` (roadmap 8b, landed in `src/` before this step): the type `(Set T)` with an `Int` or `String` element (`CHECK-SET-ELEMENT-TYPE`), the rules of the `Set.*` rows of `builtins.rkt` (`CHECK-EMPTY-SET-TYPE` for `Set.new([])` with no expected type), `for` over a set, the printable and not-encodable cases, and the reserved name `Set`; `compiler/lexer.agc` already uses `Set` for its keyword table. It must also carry `value.with(...)` (roadmap 15c, landed in `src/` and in `compiler/parser.agc`, which already parses it as `Update(StructUpdate)`): the receiver must be a struct (`CHECK-UNKNOWN-METHOD` otherwise); each name must be a field of it (`CHECK-UNKNOWN-FIELD`), given once (`CHECK-DUPLICATE-FIELD`), with a value of the field's type (`CHECK-TYPE-MISMATCH`; `[]` and `{}` take it); a field of `Fn` type named `with` is `CHECK-REDEFINED-NAME`; a bare update whose result is dropped is `CHECK-UNUSED-VALUE`; and a struct that its module keeps private cannot be updated from another module (`CHECK-IMPORT-NAME`; the linker decides what is visible, as data from the modules port of step 3, because the `visible` predicate of `src/` is a closure in the node). Lowering (step 5) emits one `struct-with` per update and the bytecode writer (step 6) writes its Updates section (format version 4). It carries module constants (§44, roadmap row 7.2.8; done in 44a2-1): the order, `CHECK-CONSTANT-CYCLE`, `CHECK-CONSTANT-EXPRESSION`, `CHECK-CONSTANT-TYPE` and the `CHECK-DECL-ORDER` rank of constants; the new import forms of §44.2 (`import Mod from "path"`, `import {A, B} from "path"`) are parser and linker changes that land in `src/` and `compiler/` together (44a0), and the checker sees no import, but one help text of `src/checker.rkt` shows the old form and the checker port carries the new text. Decided for deep trees (35.9): the linker of step 3 handles trees up to about 9,900 levels with one VM call per level, and the parser accepts trees much deeper than that, so both checkers stop with `CHECK-TOO-DEEP` at 1,000 levels of expressions and statements (one level for each, so it bounds the depth of the tree they recurse on; a diagnostic change in both front ends, made in 4b). |
| 5 | Lowering (`src/lower.rkt`) | The IR in the form `--dump-ir` prints, or the `LOWER-` diagnostic. The port must carry the lowering of module constants (§44.7, 44.8; done in `src/lower.rkt` by 44a2-2): scalar literal constants inlined, the other kept constants as zero-parameter functions, the `<start>` entry, the pruning by reachability from `main`, and the order of `Checked.constants` |
| 6 | Bytecode writer (`src/bytecode.rkt`) | The `.agcb` bytes, equal |
| 7 | BDD driver (`src/bdd-driver.rkt`) | The `agentica test` tests (`tests/test_bdd.py`, `tests/test_bdd_integration.py`) |
| 8 | CLI driver (`src/main.rkt`, the output forms of `diagnostic.rkt`, `version.rkt`, `vm-launch.rkt`) | Exit codes, stdout and stderr of every CLI test. The single binary and embedding (35.6) land here, and the self-hosted front end becomes the default |

Notes:

- Each step feeds the next with Agentica output, so the Agentica pipeline up to
  step N is all Agentica, and step N compares only its own output.
- The checker stores the type of each expression in an `eq?` hash keyed by the
  node (the development skill's `references/vm.md`, "Pipeline and files").
  Agentica has no object identity, and a `Map` key is an `Int` or a `String`, so
  the parser gives each node an `Int` id in step 2, and lowering looks types up
  by id. The Agentica checker (4b) keeps them in a `List[Type]` indexed by id
  (the ids are dense; `Unknown` marks a node with no type), and what a method
  call resolved to in a `Map[Int, Resolved]` (the `resolved` field and the
  synthetic nodes of `src/checker.rkt`, see the 4b status).
- The builtin catalog (`src/builtins.rkt`, `src/builtin-types.rkt`) moves to
  Agentica data in step 4 (4a, done: `compiler/builtins_data.agc`, generated
  from the Racket tables). It remains the one description of the builtins, and
  `agentica help` reads it.
- **Source paths.** A required change before step 6: both front ends store
  source paths relative to the project root, not absolute (35.1), so the bytes
  do not depend on where the checkout lives. The PR that makes the change also
  decides how diagnostics print the path.
- **No gap between the drivers.** The BDD driver is ported before the CLI. Until
  step 8, the Racket `main.rkt` compiles and runs the Agentica BDD driver on the
  VM, as it runs the BDD runner today, and passes it the VM's path. So
  `agentica test` always works. Releases before step 8 ship today's archive (the
  Racket front end and `agentica-vm`). The first release after step 8 is the
  single binary. A release is cut right before the step-8 PR merges, as a fixed
  starting point before the self-hosted front end becomes the default (owner
  decision, 2026-10-15). It is the last release with the Racket front end.
- **Step 8 in detail.** The diagnostic forms (`format-diagnostic`, the `--ai`
  text, `diagnostic->jsexpr`) move to Agentica; `vm/diag.c` already prints the
  same forms for runtime errors. The version moves from `src/version.rkt` to a
  plain file that the Makefile reads and passes to C as `AGC_VERSION`, as it
  does today. `vm-launch.rkt` (finding the VM, stopping the child) is deleted: a
  normal run has no child, and the BDD driver starts children of the same binary
  with `Process.spawn_captured`, whose close already sends `SIGTERM`, then
  `SIGKILL`.
- No language change lands in a stage while its port is open (35.7).
- **Open for step 8: reading source files.** `compiler/lex.agc` reads with
  `File.read_text`, which is strict UTF-8 with a 1 MiB limit. Racket's
  `file->string` replaces invalid bytes with U+FFFD and has no limit. So a
  source file with invalid UTF-8 gives different results on the two sides (the
  Agentica front end fails to read it). Step 8 has to decide: reject invalid
  UTF-8 in both front ends with a diagnostic, or decode with replacement in
  Agentica too (bytes from `File.read_bytes`, then a decoder). It is not
  decided here.

### 35.5 Language and VM prerequisites

| Need | Status | Notes |
|---|---|---|
| No quadratic `push` | Known, planned | `xs = xs.push(x)` copies the list. Fixed by 8d, a prerequisite (35.9). |
| No quadratic `+=` on `String` | Known, no plan | `s += x` copies the string. A compiler builds big strings (dumps, `--json`, messages). Collect parts in a list and `join` them. To check on the corpus whether that is enough; if not, a string builder becomes a new prerequisite. Shared one-character strings (§34, 7g) cut the lexer's allocations if it reads characters with `at` or `split("")`. |
| Efficient map for symbol tables | Known, ready | `Map` is a persistent HAMT (`vm/map.c`): `put` is O(log n) and copies nothing. Keys are `Int` or `String` only, hence the node ids of 35.4. |
| JSON key listing | Known, not needed | No API lists an object's keys (phase 10, §15). The front end writes JSON (`--json`, `help --json`) with the builders, and reads none of unknown shape. |
| Read files, directories and module paths | Known, ready | `File.read_text`, `File.stat`, `Dir.list` exist. `File.read_text` stops at 1 MiB and Racket has no limit, so a bigger source file is read with `File.open`, `File.read_bytes` in a loop, and `String.from_bytes`. Both builtins that step 3 needs are done (row 7.2.6 of the order, OS builtins in C, exception 1 of the std-first rule, no new flag): `System.env(name)` reads environment variables (`AGENTICA_PATH`, `XDG_DATA_HOME` and, as `System.env("HOME")`, the home directory; `src/modules.rkt:29-50`), and `Path.real(path)` resolves symbolic links, for module identity and the `pkg/` escape check (`normalize-path`, `src/modules.rkt:26,91-99`). `Path.real` is POSIX `realpath`, so it fails on a path that does not exist where `normalize-path` does not: the linker checks that a file exists first, as `file-exists?` does there. `Path.resolve` is lexical and does not resolve links. |
| Write binary `.agcb` output | Known, ready | Agentica has no byte type: `Bytes` is deferred (§12.5, §23.1), and bytes are `List[Int]`, written with `File.write_bytes` (1 MiB per call). An `Int` as 8 two's-complement bytes and a `Float` as its IEEE bits are `std/binary` (§23: `Binary.write_i64_be`, `Binary.write_f64_le`, `Binary.concat`), built on the `Int` and `Float` bit builtins; phase 13 (row 7.2.4 of the order) is done. To check: a 2 MB `.agcb` as `List[Int]` is 32 MB of values; if that is too slow or too big for the start-up target, `Bytes` becomes a prerequisite. |
| Process spawning for the BDD driver | Partly known | `Process.spawn_captured` exists (21a), and the environment builtin above reads `AGENTICA_VM` and `TMPDIR`. To check, one by one: a child environment without `AGENTICA_VM_METRICS*`, a private 0700 temporary directory with an `flock`'d lock, the `TMPDIR` mode check, an `lstat`-like builtin, the process's own PID, file modes for 0600 writes, and builtins that delete a file and remove a directory tree (`src/bdd-driver.rkt`). Each missing one is an OS builtin (exception 1). The path of the binary itself comes from C as an argument. |
| Handing the program to the VM | Known, missing | `agentica file.agc` must run the compiled program without a temporary file. A new builtin returns the bytes to C. C frees the front end's runtime and loads the program in a new one, so the user program never sees the compiler's heap or tasks, and `--max-steps`, `--seed` and `--allow-run` apply only to it. A second builtin reads an embedded `std/` source. Both are guarded in C at run time: they fail unless the running program is the embedded front end, which C knows because it loaded that program itself (from its own data, or from `--front-end`, 35.3). A linker rule like the std-only `HttpWire` check cannot work here, because `compiler/` is not in `stdlib/`. |
| Call depth | To check | The VM stops at call depth 10,000 (`RUNTIME-STACK-OVERFLOW`, `docs/vm/05-values-execution-builtins.md` §6.1). A recursive-descent parser or checker on deeply nested input can reach it where Racket does not. Use explicit stacks on the deep paths, or add a `PARSE-` nesting limit (a diagnostic change, decided in step 2). **Decided in step 2:** both parsers stop with `PARSE-TOO-DEEP` past 1,000 levels (up to about 8 VM frames per level, 1.25 times the limit at the tightest). It bounds the parser's calls, not the depth of its tree (see 35.9). **Decided in step 4:** both checkers stop with `CHECK-TOO-DEEP` past 1,000 levels of expressions and statements, which bounds the depth of the tree (3 to 4 VM frames per level in the checker, so at most about 4,000 frames). |
| Speed | To check | The VM must run the front end on the largest corpus file within the start-up target (35.2), including loading and validating the embedded `.agcb`. The JIT (7m) is not required if the numbers hold. Compiling `compiler/` itself is a build step and has no target, but its time is recorded. |
| Stack traces | Known, planned | A crash inside the compiler must show where it happened in `compiler/`. 14b (row 7.2.5 of the order, before the freeze) gives runtime errors a stack trace. |

### 35.6 Distribution

- **One file.** `agentica` is the VM binary with the front end inside.
  `agentica file.agc`, `check`, `compile`, `help`, `doc` and `test` keep their
  CLI. Running a compiled `.agcb` with today's VM flags becomes a subcommand of
  the same binary (its name is chosen in step 8). The separate `agentica-vm` and
  the `AGENTICA_VM` override go away; this is a breaking change for scripts that
  call `agentica-vm`, listed in that release's changelog.
- **Embedding.** One assembly file, built by the same compiler as the VM
  (`zig cc` in the release), uses `.incbin` to put two things into read-only
  data: the compiled front end (`stage2`, built from `stage0` at build time,
  35.3), and every `stdlib/` source with an index of path, offset and length.
  The list of `std/` modules moves from `src/stdlib.rkt` to a plain file that
  the Makefile reads. The `std/` modules stay as source, because the front end
  compiles imports from source, and `agentica doc` (row 22b, after the
  bootstrap) prints them (§32.5).
- **Linking.** As the release does today (the development skill's
  `references/ci.md`, "Release"): a pinned `zig cc` against glibc 2.28, checked
  with `objdump -T`, with Boehm GC, libuv, OpenSSL, yyjson and picohttpparser
  linked statically. glibc stays dynamic; a musl build stays separate (§18).
- **Size.** The VM is about 7 MB today. The front end adds an estimated 1 to 3
  MB, because an `.agcb` carries its source text. The target is under 12 MB,
  against 89 MB today.
- **Licenses.** The archive keeps `LICENSE`, `NOTICE` and `licenses/` with the
  VM's third-party licenses. Racket's and Chez Scheme's files leave the archive,
  because the binary no longer contains Racket.

### 35.7 Risks

- **Two front ends diverge during the port.** While a stage exists twice, a
  change to it must change both in the same PR, and the goldens catch a miss. To
  keep that rare, the port starts when no front-end feature is in flight, each
  step is one PR, and no language change touches a stage while its port is open.
- **Bootstrap trust and reproducibility.** stage0 is a binary file in Git that
  nobody reads. The output must be deterministic: no times, and relative source
  paths (35.4). CI checks the fixed point on every PR. While Racket exists, CI
  also checks that Racket's `stage1` equals the self-compiled `stage2`, a
  diverse double compile. After that, anyone can rebuild the chain from the
  `bootstrap-racket` tag.
- **VM bugs break the compiler.** The compiler is now the biggest program the VM
  runs, and a VM bug can miscompile it, which then hides in stage0. Every VM PR
  runs the self-compile and the fixed point, also under the `vm-sanitizers` job
  (ASan and GC stress). A stage0 refresh is its own PR; a VM change that needs
  one follows the two steps of 35.3.
- **Debugging the compiler on the VM.** A compiler bug looks like a runtime
  error in `compiler/`, not in the user's program. The front end reports it as
  an internal error with its own code (as `LOWER-INTERNAL` does today) and the
  stack trace of 14b, and asks for a bug report. The dump flags (`--dump-ir`,
  and the token and AST dumps of steps 1 and 2) keep each stage visible, and
  `AGENTICA_VM_TRACE` works on the compiler as on any program.

### 35.8 Decided against

- **Embed Racket CS in the VM binary** (`racketcs.h`, `raco ctool --c-mods`):
  one file, but it fixes neither start-up nor the 40 to 60 MB size.
- **Port the front end to Chez Scheme:** it embeds small and starts fast, but it
  is a full port with no lasting gain over self-hosting.
- **Rewrite in OCaml:** the best option outside Agentica (its ADTs and pattern
  matching fit the stages; native, small, about 5 ms start-up, the C VM linked
  statically), but it adds a toolchain and a second language to maintain
  forever.
- **Rewrite in Rust:** its enums and `match` fit the stages too (§18), but it
  has the same cost as OCaml, a new toolchain and a second language forever,
  with slower builds.
- **Rewrite in Go:** no sum types, so the AST and the checker fit it badly
  (§18).
- **`raco exe --orig-exe` as an interim single file** (§18, the 7i item in
  `docs/roadmap/07-vm.md`): one 68 MB file that still starts in about 0.6 s. The
  owner waits for self-hosting instead.

### 35.9 Order

The port is in the order of `docs/roadmap/README.md`, decided by the owner on
2026-10-14. It starts with step 8 of that order (row 7.2.7): that row freezes
the Racket front end and begins step 1 of 35.4. Its prerequisites are the rows
before it: faster lists (8d, row 8), binary data (phase 13, row 7.2.4), stack
traces (14b, row 7.2.5), and the environment and real-path builtins (row
7.2.6). Order step 11 no longer decides the front end, and the options of §18
are closed. The steps of 35.4 are PRs, not rows of the roadmap.

Status on 2026-10-15 (PR #237): the freeze of row 7.2.7 is in force, and step 1
is done. `compiler/` holds the lexer and an entry program that prints the token
text form; the goldens are in `tests/fixtures/frontend/lexer/`, and
`tests/frontend-lexer-test.rkt` checks the Racket printer and the Agentica
lexer against them. The port needed no language or VM change. Notes for the next
steps:

- A `String` indexes by character, like a Racket string, so offsets and columns
  need no conversion. The lexer splits the input once into code points
  (`split("")` and `String.code`) and reads them by index.
- An `Int` literal can be larger than 64 bits in Racket (the checker then
  reports `CHECK-INT-RANGE`). The Agentica token keeps such a value as its
  digits (`Huge`), because an `Int` cannot hold it.
- Racket's `char-graphic?` has no builtin in Agentica.
  `compiler/unicode_table.agc` is generated by `tools/gen-lexer-unicode.rkt`,
  and the test checks it.
- Measured on `stdlib/bdd/gherkin.agc` (575 lines): the Agentica lexer on the
  VM takes 40 ms and 8 MB of RSS as a process (37 ms inside the process). The
  Racket lexer takes 35 ms inside its process (20 ms when warm), but the
  process takes 0.55 s and 105 MB with Racket's start-up.
- The lexer was then rewritten with lookup tables (a Map of character
  classes, Sets of name and number characters, string stops, keywords and
  block openers) and small `scan_*` functions under a `while` over the index.
  On the same VM the same file lexes in 29 ms instead of 33 ms (best of 30
  runs), and a 1 MB file of mixed source in 1.66 s instead of 1.93 s. A
  tail-recursive `step(state)` version with `.with` was about 3-6% slower and
  was not kept.

Status on 2026-10-15 (PR #245): step 2 is done. `compiler/` also holds the
AST (`ast.agc`) and the parser (`parse_base.agc`, `parser.agc`), and an entry
program that prints the tree in a text form with a node id on every node; the
goldens are in `tests/fixtures/frontend/parser/`. Notes:

- Agentica has no mutable state, so each parse function takes the token
  position and the next node id and returns the node with the new position and
  id. A failure is a `Result` error that holds a packed diagnostic, so `try`
  stops at the first error.
- Node ids are dense and in post-order (a child before its parent, the program
  last), not pre-order: the parser builds trees bottom-up, and pre-order would
  need a second pass. Map keys stay `Int`.
- Nesting limit: `PARSE-TOO-DEEP` at 1,000 levels in both parsers (a parser
  rule in `src/`, allowed by the owner's relaxed freeze defaults of
  2026-10-15). A chain operator or suffix counts a level, and what follows the
  k-th link of a chain starts k levels deeper. With the limit raised, the
  Agentica parser overflows the VM stack at: `Result.Ok(` or `M.f(` nested
  1,665 levels, `f(` or lists 1,998, parentheses or interpolations 2,498,
  `if` 3,328, `case` 4,992, `do` blocks 1,427 (4 counted levels each, so 249
  fit under the limit). `==` and `<` add no level but cost parser frames:
  nested `M.f(1 == 1 < ` (also `Result.Ok(`, `E.V(`) overflows at 1,247 levels,
  and `f(1 == 1 < `, `[1 == 1 < `, `P(a: 1 == 1 < ` at 1,426, about 8 frames
  per level. The tightest margin is 1.25 times (legal input at 998 still
  passes); the parser's stack is not shared with later passes, so this is
  enough. Explicit stacks were not needed. Racket alone handled one million
  nested parentheses.
  The limit bounds the parser's calls, not the depth of the tree: the right
  operand of the first link of a chain hangs below the whole chain, so nested
  chains give deeper trees (1,990 levels for two nested chains, 89,000 for
  100). The checker of step 4 does not assume the tree is less than 1,000
  levels deep: it has its own limit, `CHECK-TOO-DEEP` (see the 4b status). The
  text printer of `compiler/parse.agc` is a test tool with the same caveat: it
  overflows the VM stack on very tall legal trees (30 nested chains).
- Measured on `stdlib/bdd/gherkin.agc` (4,354 tokens): the Agentica parser
  takes 15 ms on the VM after the 37 ms of the lexer, so the front end so far
  uses 53 ms of the 100 ms budget of `check`. Printing the tree takes 28 ms
  more and is not part of `check`. The process peaks at 9.6 MB of RSS (15 MB
  with printing). The Racket parser takes 2.3 ms in its process. Nothing is
  quadratic: a 10,000-statement file, a 20,000-element list and 3,000 `elsif`
  groups parse in linear time.
- The Agentica parser matches the Racket parser on the 285 files of
  `examples/`, `stdlib/` and `tests/fixtures/vm/`, on 300 generated inputs and
  on the 245 goldens.

Status on 2026-10-15 (PR #254): step 3 is done. `compiler/` also holds the
module loader and linker (`modules.agc`, `resolve_import.agc`, `resolve.agc`,
`rewrite.agc`, `linker.agc`, with `declarations.agc`, `import_path.agc`,
`suggest.agc`, `link_env.agc` and `link_failure.agc`) and an entry program,
`link.agc`, that prints the linked program; the goldens are 157 fixture folders
in `tests/fixtures/frontend/modules/` (a folder with a `root.agc`, the files it
imports and an optional `fixture.env`, plus `NAME.linked`). The port needed no
language or VM change. Notes for the next steps:

- `Linker.link_file(path, settings)` gives `Linking.Done(Linked)` or
  `Linking.Failed(Failure)`. `Linked.modules` lists the files, root first, each
  file before the files its imports read; a file's declarations are rewritten
  (names get the prefix of their file, `@2::name`; the root keeps its names) and
  lose their `export`. `Linker.program(linked)` is the flat `Program` that the
  checker reads, with the id, span and module doc of the root. A `Failure` has
  the `file` the diagnostic is in, because a `Span` has no file in `compiler/`.
- Settings are explicit: the `stdlib/` folder (a `std/NAME` import is the file
  `stdlib/NAME.agc`) and the three environment variables (`Env`). The std
  registry of `src/stdlib.rkt` and the folder must list the same files; a test
  checks it. The tables the linker takes from `builtins.rkt` and
  `checker.rkt` (reserved type names, bare builtin names, builtin enums,
  std-only modules) were `compiler/module_names.agc`, generated by
  `tools/gen-module-names.rkt`; step 4a replaced them with the builtin
  catalog (below).
- The privacy rule of `value.with(...)` is data: the linker sets
  `StructUpdate.visible` to the sorted linked names of the user structs the
  file may update (its own and the exported structs of the files it imports
  directly; builtin records are always allowed and not listed). Step 4 refuses
  an update of any other user struct (`CHECK-IMPORT-NAME`). The text form
  prints it as ` visible=[...]`; Racket gets the list by calling the predicate
  on every user struct of the program.
- Node ids are one numbering: the root is parsed from 0 and each file from the
  next free id of the file read before it, in the order Racket reads files. A
  file takes ids for its imports and exports too, so the linked declarations
  leave gaps. `link.agc --ids` prints the range of each file.
- A call `Enum.Variant(x: 1)` is a `Construct` for the parser; the linker turns
  it into an `EnumConstructor` whose `named` list holds the arguments (`args`
  is empty), as Racket does with `named-arg` nodes. The checker refuses it
  (`CHECK-ENUM-POSITIONAL-ARGS`).
- The loader keeps its own stack, so a chain of 3,000 files or a file with
  2,000 imports uses no VM call depth. The rewrite recurses on the tree: about
  one VM call per level (`rewrite_expr` tail-calls `rewrite_compound`), so it
  handles trees up to about 9,900 levels and fails with
  `RUNTIME-STACK-OVERFLOW` near 10,800 (12 chains of 900 links nested in the
  right operand of each first link). The parser accepts such files (35.9, step
  2), and Racket links them. The checker of step 4 refuses a tree deeper than
  1,000 levels (`CHECK-TOO-DEEP`), so later passes never see one.
- Differences from Racket. A source file over 1 MiB, or with invalid UTF-8,
  cannot be read (`File.read_text`, see the open item of 35.4 for step 8) and
  is `CHECK-IMPORT-IO` "cannot read import". The message of the root file's own
  read error is the system's text, so it differs, and the golden comparison
  skips it. An unset `HOME` leaves the user library folder out of the `pkg/`
  search (Racket asks the system for the home folder). `Path.real` fails on a
  missing file where `normalize-path` accepts a missing last part, so the
  loader checks the folder first and a missing file is "cannot read import" at
  once, with the same code and span. For the same reason a symbolic link to a
  missing folder (a dangling link used as a folder part of an import) is
  "cannot read import" in Agentica where Racket says "cannot resolve import",
  again with the same code and span. The tests pin the Agentica side of the
  invalid UTF-8 case (the fast tier) and of the 1 MiB limit (the slow tier);
  the `HOME` user root is tested in the fast tier on the Agentica side only,
  because Racket's `find-system-path` ignores a replaced environment.
- Measured on `stdlib/bdd/gherkin.agc` (575 lines, 2 files with
  `std/test/report`): 0.12 s and 11.7 MB of RSS as a process, 0.04 s of that
  for loading the second file. On `stdlib/test/runner.agc` (7 files, 3,598
  lines, 9,400 nodes): 0.29 s and 16.4 MB. The loop is the lexer and parser;
  rewriting the trees costs little. Nothing is quadratic.
- The Agentica linker matches the Racket linker on the 157 fixtures (which
  include every input of `tests/modules-test.rkt` that links files), the 322
  files of `examples/`, `stdlib/` and `tests/fixtures/`, the 307 programs of the
  site, and the large inputs of the slow tier (chains of 3,000 files, 2,000
  imports, cycles, and deep trees).

Status on 2026-10-15 (PR #258): step 4a is done. The checker (step 4) is split
in PRs that each hold their tests and docs: 4a is the builtin catalog, which the
linker already needed (the name tables) and the checker needs for every call;
4b and 4c are the checker.

- `compiler/types.agc` has the `Type` enum, the lists headed by a name of
  `src/checker.rkt` (`'Int`, `'(List T)`, `'(Struct "Point")`) as variants, and
  `to_text` (`type->string`) and `display_name` (the `@N::` prefix of a linked
  name is left out of messages). `Type.Var` is a type variable of a builtin
  signature; `(Await R)` of the Racket rows is `Type.Enum("Await", [R])`, which
  prints the same.
- `compiler/builtin_model.agc` has the data structs (`Builtin` with its
  `alternatives`, `Named`, `Record`, `EnumDef`) and the `Rule` enum: the rule
  symbols of `builtins.rkt` in CamelCase, `Plain` for no rule. A test checks the
  variants against the rows.
- `compiler/builtins_data.agc` is generated by `tools/gen-builtins-data.rkt`
  from `src/builtins.rkt`, `src/builtin-types.rkt` and `reserved-type-names` of
  `src/checker.rkt` (rows in functions of at most 40, to stay under 60 lines).
  It replaces `module_names.agc` and `tools/gen-module-names.rkt`. A fast test
  fails when the file is out of date: run `racket tools/gen-builtins-data.rkt`
  after changing a row, a record, an enum or a reserved name.
- `compiler/builtins.agc` builds a `Catalog` once per run: a `Map` of the
  builtins by name, `Set`s for the bare names, the opaque and handle types and
  the reserved names, `Map`s for the records and enums, the public names (all
  but the std-only modules) sorted, and the std-only table. `lookup`, `ref`
  (with an arity: the form among the alternatives), `std_only_name?`,
  `signature` and `form_signature` are map accesses or short loops, never scans
  of the table. Building the catalog takes 2.6 ms (210 rows); the linker's
  `Settings` holds one.
- `suggest.agc` has `did_you_mean_among`, the full `did-you-mean` of
  `builtins.rkt` (linked-name prefix, shared candidates). It skips candidates
  whose length differs by more than the limit before it computes a distance.
- The text form of the catalog is `tests/frontend-catalog-common.rkt` (Racket)
  and `compiler/catalog.agc` with `catalog_text.agc` (Agentica): one line per
  form (signature, the parameter and result types with their variants written
  out, rule, implementation, effects, description), the records, the enums and
  the name tables, then the answer to each probe (`near:`, `ref:`, `std:`,
  `type:`, `sig:` and `disp:` questions, listed in the common file). The golden
  is `tests/fixtures/frontend/catalog/catalog.text`; the Agentica output on the
  VM equals it.
- Not in 4a: `agentica help` still reads the Racket catalog (step 8), and the
  method tables, the foreign-name help texts and the rules of the checker
  (`method-aliases`, `foreign-names`, the `case` on `builtin-rule`) go with the
  checker in 4b.

Status on 2026-10-15 (PR #263): step 4 is done except module constants; 4b is
the whole checker, so there is no 4c. `compiler/` holds `check_register.agc`
(the declarations), `check_stmt.agc` (functions, blocks, statements and `case`),
`check_expr.agc` (expressions), `check_call.agc` and `check_method.agc` (calls,
enum constructors, struct construction and update, methods and fields), the
rules of the builtins in `check_rules.agc`, `check_list.agc` and
`check_collections.agc`, the helps in `check_help.agc` and `check_names.agc`,
the state in `check_state.agc`, `check_types.agc` and `check_failure.agc`,
`check_flow.agc` and `check_unused.agc`, and `checker.agc` with the entry
`check.agc` (3,760 lines of Agentica for the 1,900 of `src/checker.rkt`). The
text form is the linked program of step 3 with ` type=T` at the end of the line
of each expression and block and ` resolved=...` on a method call or field
access that names a builtin; a failure prints the diagnostic line and its notes
(`expected`, `actual`, `callee`, `signature`, `labels`) and the file. Goldens
are in `tests/fixtures/frontend/check/` (58 fixtures, one for every reachable
`CHECK-` code and every rule of the builtin table);
`tests/frontend-check-common.rkt` prints the Racket text. Notes:

- The state is an immutable `Cx` (the declarations, the catalog, the help
  tables, the text of each file) and a threaded `St` (types, resolutions, names
  in scope, result type, loop depth, the block being checked, the nesting
  depth). The names in scope are one persistent `Map`: a scope is a snapshot,
  closing a scope puts the snapshot back, and nothing is deleted (a `Map`
  delete is O(n)). A binding records the depth it was introduced at, which
  answers `CHECK-CAPTURED-ASSIGNMENT` (a block cannot assign a name whose depth
  is at or below the depth where the block began). The cycle between
  expressions and statements goes through one function field of `Cx`
  (`expression`), because a module cannot import a module that imports it.
- A failure is a packed `Problem` in the `Result` error, so `try` stops at the
  first diagnostic. `Type.Unknown` is the expected type when there is none
  (`#f` in Racket).
- The mutated fields of `src/checker.rkt` become data. A method call or field
  access that names a builtin is recorded by node id as `Resolved`: `Self(T)`
  (`to_s` on a String), `Text(T)` (`to_s`, an interpolation), `Inspect(T)` or
  `Call(name, T)`, each with the type of the receiver. Racket keeps these as the
  `resolved` field of the node: a typed-target for `Self`, an `interpolation`
  for `Text`, an `inspection` for `Inspect` and a call whose first argument is
  the receiver for `Call`. Lowering (step 5) reads the list of types and the
  `Resolved` map. The call that checks a builtin method takes the receiver as an
  already checked argument, a `TypedTarget` expression the parser never makes.
- `compiler/check_tables.agc` is generated by `tools/gen-check-tables.rkt` from
  the tables in `src/checker.rkt` (`method-modules`, `method-aliases`, the
  foreign-name helps); a fast test fails when it is out of date.
- `CHECK-TOO-DEEP` is new in both checkers (a diagnostic change that relaxes the
  freeze of row 7.2.7: without it a legal program could reach the VM call limit
  in the Agentica checker, and in the later passes). Each expression and
  statement being checked is one level; the node that would be the 1,001st gets
  the diagnostic (help: split the code into smaller functions or simpler
  expressions). The checker needs up to 5 VM frames per level, measured by
  burning frames before the check and finding the depth that still passes. The
  worst case is a builtin with the nested call as its first argument
  (`List.append`, `Map.put`, `Set.add`, `List.concat`, `List.take`, `List.set`:
  5, 4,952 frames at 990 levels). Enum constructors, `String.trim`, `while`,
  `for`, `case`, `-x`, `!x`, `ok(ok(...))`, `Map.get`, `List.at` and
  `List.repeat` take 4; `if`, method chains, calls and lists take 3; a block
  inside a block takes 6 for each block (the parser allows about 240 of them).
  So the limit costs up to about 5,000 of the 10,000 frames, a margin of about
  2 times. A later pass that recurses on the tree must measure its own frames
  per level: at 1,000 levels it can use about 9 before the VM limit, and the
  margin shrinks as the limit grows.
- The Racket checker had a crash in `unify-type!`: a generic enum where another
  generic enum was expected (`Wrap.Holder(Other.Item(1))` where `Box[T]` is
  wanted) compared the enum names as types and raised a Racket exception. It is
  now `CHECK-TYPE-MISMATCH` in both, with a test.
- `CHECK-BLOCK-TYPE`, `CHECK-INTERNAL` and `CHECK-MODULE-CONTEXT` cannot be
  reached from source (a block follows a call that gives its parameter types;
  the other two guard impossible nodes), so no fixture ends in them.
- Measured on the VM (best of 5, the check alone, after the link): the wrapper
  of `stdlib/bdd/gherkin.agc` (2 files, 32,000 characters) 33 ms and 16 MB of
  RSS for the whole process, link included (98 ms to lex, parse and link it);
  `stdlib/test/runner.agc` as `std/test/runner` (76,000 characters) 78 ms; a
  generated program of 1,000 functions (630,000 characters, 25,000 lines) 1.2 s,
  and 200 functions take a fifth of that, so it is close to linear. Racket
  checks the same in 6 ms, 13 ms and 0.15 s.
  So the lexer, parser, linker and checker together take about 131 ms on
  gherkin, over the 100 ms target of 35.2; the checker is a quarter of it. The
  target is not a condition (35.2): the bootstrap goes ahead and the speed is
  tracked after it. These numbers were measured while other agents were loading
  the machine, so a re-measure on a quiet machine is planned.
- Where a table or a loop made a difference: the types in a `List` indexed by
  node id instead of a `Map` keyed by id took the check of the generated program
  from 1.83 s to 1.24 s (a `Map.put` costs about 5 us at 5,000 entries and a
  `List.set` about 1.6 us in the same loop), runner 103 ms to 78 ms and gherkin
  38 ms to 33 ms. One `.with` instead of three per expression made no
  measurable difference (a `.with` of the 10-field state costs 0.3 us). The
  method tables, the help tables and the catalog are built once (under 1 ms),
  never per lookup.
- The Agentica checker matches the Racket checker on the 530 programs of
  `tests/checker-test.rkt`, the 24 files of `examples/`, the 235 of
  `tests/fixtures/vm/`, every `std/` module, `compiler/` itself, the 58
  fixtures, trees around the limit and a generated program, and on 5,200 mutated
  programs in a one-time run (the slow tier repeats 1,500; the fast tier has the
  fixtures). Same codes,
  spans, messages, helps and notes, and the same types.
- Module constants (`NAME = expr` at top level, section 44) landed in both
  checkers with PR 44a2-1. `Checked.constants` holds the linked names in
  initialization order, and the check text has a last line
  `constant-order [...]` when the program has constants. The Racket `check`
  does not return the order (its API is unchanged): a lowering calls
  `constant-order` of `src/constants.rkt` on the linked program.
- The list of types is built from repeats of at most 1,048,576 slots, because
  `List.repeat` halts with `RUNTIME-INVALID-COUNT` above that count and a
  program of about 5.7 MB of source has more node ids. One file is limited to
  1 MiB, so such a program is several files joined by imports.

### 35.10 Tests move to Python unittest

**Status:** started on 2026-10-15, decided by the owner the same day. Phase 0
is PR #261 (branch `tests/unittest-phase0`). Roadmap row 7.2.9
([`docs/roadmap/README.md`](../roadmap/README.md)) tracks the phases. They run
beside steps 4 to 8 of [§35.4](#354-stages-to-port) and
[§44](44-module-constants.md).

The suite is rackunit: 51 `.rkt` files in `tests/` (43 named `*-test.rkt`, the
rest helpers and integration tests), about 11,800 lines. Most of it runs the
binary, reads its output and compares it with a golden or a peer. The Python
standard library does that well (`subprocess`, `difflib`, `socket`,
`tempfile`), and the translation is close to line by line. The repo already has
19 Python peers in `tests/fixtures/` and two `unittest` modules in
`tests/eval/`. `unittest` is part of the standard library, so the tests add no
package, no lock file and no install step.

`AGENTS.md` keeps its rule of standard library only, with no test frameworks.
Only the list of frameworks changes: rackunit and Python `unittest` during the
migration, and `unittest` alone at the end. Phase 0 changes that rule, the
two-tier rule and the `tests/` line of the map in `AGENTS.md`, and the test
references of the development skill.

Considered and rejected:

- Keeping Racket as a test-only reference: a second implementation that falls
  behind every language change.
- C: about twice the migration work.
- Zig: pre-1.0, and it breaks between versions.
- Rust and OCaml: new heavy toolchains.
- Agentica-only tests as the base: they stay for the stdlib and for user
  programs through `agentica test`, but not as the base.
- pytest with pytest-xdist: it adds packages to pin and install for what
  `make -j` and `unittest` already do; adopt it later only if a real need shows
  up.

**The harness.** The tests are black-box. A test runs the product CLI, runs
`agentica-vm` directly when it checks the VM alone, and runs the stage programs
of `compiler/` while they exist. The product CLI is `racket src/main.rkt` until
step 8, and the single binary after it. A test compares the output with a golden
or a peer: tokens, AST text, linked text, diagnostics (code and span, never
message text), `.agcb` bytes, CLI exit codes, stdout and stderr.

- `tests/agentica_test.py` is the shared helper. It holds the binary and CLI
  paths, the environment variables that exist today (`AGENTICA_VM_BINARY`,
  `AGENTICA_REQUIRE_VM`, `AGENTICA_FIXTURES`, `AGENTICA_SWEEP`), process runs
  with timeouts, `compile_agc`, `run_vm`, and temporary directories that are
  removed after the run. It stays small: a helper goes in only when a second
  module needs it.
- Programs are compiled by the product CLI, never by a Racket module loaded into
  the test process. The rackunit helpers do load `src/` in process today
  (`vm-diff-common.rkt`, `cli-in-process.rkt`), so each area that moves stops
  using them.
- Peers (Node, Python, curl) stay standard library only, as they are today. A
  peer runs as its own child process.
- The translation is mechanical. `check-equal?` becomes `assertEqual`, a
  `test-case` becomes a test method, and `(module+ slow ...)` becomes the
  `@slow` mark of the helper.
- The two tiers are exclusive, as the rackunit submodules are. `make test` runs
  the fast cases only. `make test-slow` sets `AGENTICA_TEST_SLOW=1`, which runs
  only the `@slow` cases, as `raco test --submodule slow` does. A case of the
  other tier is skipped visibly.
- A missing VM follows the rule of `AGENTS.md` as it does today: a local run
  skips it visibly, and CI fails when `AGENTICA_REQUIRE_VM=1`.
- Parallel runs come from make. Each test module is one
  `python3 -m unittest tests.test_<area>` process, run by make with
  `make -k -O -j`, so one failure does not hide the others. No runner script is
  needed. Tests that open sockets use port 0 and clean up their children. If a
  case ever needs more, it is a tiny stdlib script for the summary and subset
  selection.
- `make test TESTS=...` selects files of either kind: a `.rkt` file goes to
  rackunit, a `.py` file to unittest.

A test lives in one framework only. Each area PR deletes the `.rkt` files it
replaces, and the docs that name a moved file change in the same PR. Finding
them: search `docs`, `.agents` and `AGENTS.md` for `rackunit`, `raco test` and
`-test.rkt`. The CI targets keep working in every PR. During the migration, new
tests are written in unittest unless they need the in-process Racket front end
(the live comparisons of the steps of [§35.4](#354-stages-to-port)), which stay
in rackunit until phase 3.

**Phases.**

- **Phase 0** (PR #261, started 2026-10-15): the helper, the make targets above,
  the rule changes in `AGENTS.md` and the development skill, and one small area
  as the proof: `tests/vm-bits-test.rkt` (42 lines) moves to
  `tests/test_vm_bits.py`.
- **Phase 1:** areas that do not need the Racket front end as an oracle: VM and
  runtime fixtures, network and process tests, BDD, and CLI. One area per PR.
  Tests that go through `cli-in-process.rkt` run the product CLI as a child
  instead, with the same output. A test that calls a front-end module directly
  waits for phase 2. Done: the small VM runtime tests (PR #264, 2026-10-15:
  monotonic clock, logger, test protocol, channel, child channel and the C
  style check, 13 cases), then the network tests (PR #266: TCP, HTTP and TLS,
  19 cases), the VM I/O tests (PR #267: stdout, stop signals and
  `File.each_line`, 35 cases) and the process, BDD and BDD integration tests
  (PR #269: 26 fast cases and 5 slow ones, which run the CLI as a child),
  the file system tests (PR #274: 21 cases), the VM trace, latency and
  `std/binary` tests (PR #276: 17 cases; the latency test runs alone, by
  `make vm-latency`), and the examples and CLI tests (PR #279: 17 fast cases
  and 1 slow one).
  `tests/vm-stack-test.rkt` stays, because `make goldens` writes its sidecars.
  `tests/unit-test-test.rkt` waits for phase 2: it calls
  `run-agentica-test` of `src/bdd-driver.rkt` to set a test timeout that the CLI
  has no flag for.
- **Phase 2:** the golden parts of the front-end tests move to `unittest`: the
  Agentica output compared with the goldens in `tests/fixtures/frontend/`. The
  live comparisons with the Racket stages stay in rackunit until phase 3. A file
  with both kinds is split, and each case keeps one framework.
- **Phase 3,** with the step-8 PR. Before that PR, every live comparison (corpus
  files, generated inputs, the large inputs of the slow tier) is frozen into a
  golden, so no coverage is lost. Generated inputs are checked in as fixture
  files or, when they are too big for that, a seeded stdlib script writes them
  and the golden records their SHA-256. The PR then removes the rackunit files,
  every make target that only runs rackunit, and the CI steps that use those
  targets. Other `raco` calls stay until the deletion PR (`raco exe` for
  `dist/agentica`, `raco make`, `raco distribute`), because the build still uses
  Racket. The test suite no longer needs Racket. The fixed-point check of
  [§35.3](#353-bootstrap), stage2 and stage3 equal byte for byte, runs in CI
  from the committed `stage0`. The release cut before the step-8 PR, which
  [§35.4](#354-stages-to-port) defines, is taken from the commit before this
  phase, so that release still has the rackunit live comparisons. The deletion
  of `src/*.rkt` and of the `raco distribute` steps follows the conditions of
  [§35.3](#353-bootstrap).
