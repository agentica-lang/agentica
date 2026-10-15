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
- An `.agcb` holds the format version (3), the Agentica version, and the path
  and full text of every source file (`write-program`, `src/bytecode.rkt:203`).
  The paths are absolute (`path->complete-path`, `src/modules.rkt:9,15,26`). The
  loader rejects a file built for another Agentica version (`vm/loader.c:402`).

### 35.2 Goal and success criteria

The work is done when all of these hold:

- **One file.** The release archive has one executable, `bin/agentica`, and no
  `runtime/` directory. It needs only glibc (2.28 or newer), as `agentica-vm`
  does today (35.6).
- **Fast start.** `agentica check examples/hello.agc` takes at most 30 ms of
  wall time and at most 30 MB of peak RSS.
  `agentica check stdlib/bdd/gherkin.agc`, the largest file in the corpus today
  (575 lines), takes at most 100 ms. To measure them, extend the start-up check
  of `benchmarks/run.py` (`startup()`, which times `hello.agc` today;
  `make bench`) with these two commands, and record the numbers and the baseline
  machine in `docs/vm-benchmarks.md`. The targets hold on that machine. CI does
  not gate on time, because CI machines are noisy.
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
- no Makefile target, CI job or release step runs `racket` or `raco` except the
  test suite (`make version` reads the plain version file of step 8);
- `vm/tools/gen-unicode.rkt` is ported (its output, `vm/unicode_data.c`, stays
  checked in).

Then one PR deletes `src/*.rkt` and the `raco distribute` release steps, and
tags the parent commit `bootstrap-racket`, the last commit that can make a
stage0 from Racket. 18 of the 31 `tests/*.rkt` files require `src/` modules. In
the same PR, the per-stage goldens replace the stage tests that call `src/`
directly (`lexer-test`, `parser-test`, `modules-test`, `checker-test`,
`bytecode-test`, `diagnostic-test` and the like), and those files are deleted.
The PR rewrites the others so that they use only the binary:

- `cli-in-process.rkt` loads `src/main.rkt` in the same process, and five test
  files go through it. It runs the binary as a child instead.
- `compile-file` in `vm-diff-common.rkt` builds every golden fixture with the
  Racket stages. It calls `agentica compile` instead.
- `site-examples-test.rkt` loads the lexer, parser, modules and checker. It uses
  `agentica check --json` instead.
- `vm-latency-test.rkt`, `vm-trace-test.rkt` and `bdd-integration.rkt` run
  `racket src/main.rkt` as a child. They run the binary instead.

Replacing rackunit itself is a separate decision: the test suite stays on Racket
until the owner chooses its replacement, because the choice changes the test
rule in `AGENTS.md`.

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
| 3 | Modules and linker (`src/modules.rkt`, `stdlib.rkt`) | The linked program dump, with `std/` and `pkg/` resolution. Needs the environment and real-path builtins (35.5) |
| 4 | Checker (`src/checker.rkt`, `builtins.rkt`, `builtin-types.rkt`) | The `CHECK-` diagnostic, and the type of each expression. The port must carry `CHECK-DECL-ORDER` (imports, then `struct` and `enum`, then `export def`, then `def`, in every file), which the Racket front end checks per file in `src/modules.rkt` before linking; the module port (step 3) and this one keep its span (the start of the first declaration out of place). It must also handle `Set[T]` (roadmap 8b, landed in `src/` before this step): the type `(Set T)` with an `Int` or `String` element (`CHECK-SET-ELEMENT-TYPE`), the rules of the `Set.*` rows of `builtins.rkt` (`CHECK-EMPTY-SET-TYPE` for `Set.new([])` with no expected type), `for` over a set, the printable and not-encodable cases, and the reserved name `Set`; `compiler/lexer.agc` already uses `Set` for its keyword table |
| 5 | Lowering (`src/lower.rkt`) | The IR in the form `--dump-ir` prints, or the `LOWER-` diagnostic |
| 6 | Bytecode writer (`src/bytecode.rkt`) | The `.agcb` bytes, equal |
| 7 | BDD driver (`src/bdd-driver.rkt`) | The `agentica test` tests (`tests/bdd-test.rkt`, `tests/bdd-integration.rkt`) |
| 8 | CLI driver (`src/main.rkt`, the output forms of `diagnostic.rkt`, `version.rkt`, `vm-launch.rkt`) | Exit codes, stdout and stderr of every CLI test. The single binary and embedding (35.6) land here, and the self-hosted front end becomes the default |

Notes:

- Each step feeds the next with Agentica output, so the Agentica pipeline up to
  step N is all Agentica, and step N compares only its own output.
- The checker stores the type of each expression in an `eq?` hash keyed by the
  node (the development skill's `references/vm.md`, "Pipeline and files").
  Agentica has no object identity, and a `Map` key is an `Int` or a `String`, so
  the parser gives each node an `Int` id in step 2, and lowering looks types up
  by id.
- The builtin catalog (`src/builtins.rkt`, `src/builtin-types.rkt`) moves to
  Agentica data in step 4. It remains the one description of the builtins, and
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
  single binary.
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
| Call depth | To check | The VM stops at call depth 10,000 (`RUNTIME-STACK-OVERFLOW`, `docs/vm/05-values-execution-builtins.md` §6.1). A recursive-descent parser or checker on deeply nested input can reach it where Racket does not. Use explicit stacks on the deep paths, or add a `PARSE-` nesting limit (a diagnostic change, decided in step 2). **Decided in step 2:** both parsers stop with `PARSE-TOO-DEEP` past 1,000 levels (up to about 8 VM frames per level, 1.25 times the limit at the tightest). It bounds the parser's calls, not the depth of its tree (see 35.9). |
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
  100). The checker of step 4 must not assume the tree is less than 1,000
  levels deep; it needs an explicit stack or its own depth check on the
  deep paths. The text printer of `compiler/parse.agc` is a test tool with
  the same caveat: it overflows the VM stack on very tall legal trees (30
  nested chains).
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
