## 35. Self-hosted front end and a single binary

**Status:** planned, long-term. Decided by the owner on 2026-10-13: the front end is rewritten in Agentica, compiled to bytecode and embedded in the VM binary. The release then ships one file: `agentica-vm`, renamed to `agentica`. Racket is needed only to make the first bootstrap file. This work comes after the current order in [`docs/roadmap/README.md`](../roadmap/README.md); it is not in the near-term order. It settles the question that [§18](18-front-end-language.md) left open.

The idea in one paragraph: the owner wants one binary to distribute and a fast start. Today Racket gives neither. The front end (lexer, parser, linker, checker, lowering, bytecode writer, BDD driver, CLI) is ported to Agentica one stage at a time. Each stage is checked against the Racket stage on the whole corpus. When all stages are ported, the Racket front end compiles the new front end once, the new front end compiles itself, and its output must not change (a fixed point). A compiled front end is checked in as `stage0`, so a build needs no Racket. The VM binary carries the compiled front end and the `std/` sources as data.

### 35.1 Today

Measured by the owner on master on 2026-10-13:

- `agentica check hello.agc` takes about 0.5 s and 148 MB of RSS. Almost all of it is Racket start-up.
- The release is about 89 MB: `dist/agentica` is 17 MB, `dist/runtime/` (from `raco distribute`) is 66 MB, and `agentica-vm` is 7 MB.
- The Racket front end is about 5,600 lines after 7i: `src/lexer.rkt`, `parser.rkt` (with `ast.rkt`), `modules.rkt`, `checker.rkt` (with `builtins.rkt` and `builtin-types.rkt`), `lower.rkt`, `bytecode.rkt`, `main.rkt` and `bdd-driver.rkt`, plus the shared `source.rkt`, `token.rkt`, `diagnostic.rkt`, `version.rkt` and `vm-launch.rkt`.
- `src/main.rkt` compiles to a 0600 temporary `.agcb` and starts `agentica-vm` as a child. `agentica test` starts a runner VM written in Agentica (§31), so part of the tool is already Agentica.
- An `.agcb` holds the format version (3), the Agentica version, and the path and full text of every source file (`write-program`, `src/bytecode.rkt:203`). The paths are absolute (`path->complete-path`, `src/modules.rkt:9,15,26`). The loader rejects a file built for another Agentica version (`vm/loader.c:402`).

### 35.2 Goal and success criteria

The work is done when all of these hold:

- **One file.** The release archive has one executable, `bin/agentica`, and no `runtime/` directory. It needs only glibc (2.28 or newer), as `agentica-vm` does today (35.6).
- **Fast start.** `agentica check examples/hello.agc` takes at most 30 ms of wall time and at most 30 MB of peak RSS. `agentica check stdlib/bdd/gherkin.agc`, the largest file in the corpus today (575 lines), takes at most 100 ms. To measure them, extend the start-up check of `benchmarks/run.py` (`startup()`, which times `hello.agc` today; `make bench`) with these two commands, and record the numbers and the baseline machine in `docs/vm-benchmarks.md`. The targets hold on that machine. CI does not gate on time, because CI machines are noisy.
- **Same results.** Every golden fixture and every test passes with no `make goldens` diff.
- **Same diagnostics.** The same code and the same span for every diagnostic in the corpus and in the tests. Message texts stay the same too, unless a PR changes one on purpose and says so.

### 35.3 Bootstrap

**stage1** is the Agentica front end (a new top-level `compiler/` directory) compiled by another compiler: Racket at first, `stage0` later.

1. **Stage 1.** The Racket front end compiles `compiler/` to `stage1.agcb`.
2. **Embed.** `stage1.agcb` goes into the VM binary as data (35.6). The binary is now a full `agentica`.
3. **Fixed point.** That binary compiles `compiler/` to `stage2.agcb`, and `stage2` compiles it again to `stage3.agcb`. `stage2` and `stage3` must be equal byte for byte. While Racket exists, `stage1` must also equal `stage2`, since the two front ends must emit the same bytes (35.4, step 6).
4. **stage0.** A fixed-point output is checked in as `bootstrap/stage0.agcb`. `make` builds the VM, embeds `stage0`, uses it to compile `compiler/` (stage1), embeds the result, and checks the fixed point. A clone builds without Racket. It still needs what the VM build needs today: make, perl for OpenSSL, and the submodules.

**Checked in, not built from a release.** A release-built stage0 means downloading the previous release to build, which needs the network, a previous release for every platform, and a VM that still reads that file's format. A checked-in file keeps the build hermetic and offline, like CI today, and works in the private alpha, which has no stable releases to rely on. Zig (`zig1.wasm`) and OCaml (`boot/ocamlc`) do the same.

**Versions.** The loader checks the format version of every program. It checks the Agentica version of every program except the embedded front end, which C loads from its own data. So a version bump does not break the committed stage0, and stage0 is never refreshed for a version bump. The version is not a constant in `compiler/`: C passes it to the front end at start-up, and the front end writes it into each `.agcb` header. So `stage2` and `stage3`, made by the same binary, carry the same version, and the fixed-point check compares whole files. The committed stage0 is a seed, not compared with `stage2`.

**When stage0 changes.** Only when `compiler/` needs something stage0 cannot compile. Not on every compiler change. Each case takes two steps:

- **New syntax.** First, one PR teaches the compiler the syntax without using it in `compiler/`, and refreshes stage0 from the new compiler. Then a later PR uses the syntax in `compiler/`.
- **New `.agcb` format.** The old stage0 on the old VM compiles the new compiler (whose writer emits the new format). Then that compiler compiles itself, which gives the new stage0 in the new format. `make stage0` does both steps in a temporary worktree of the parent commit.

A refresh PR shows the source diff that made stage0 change, and CI checks the fixed point from the committed stage0.

**When Racket can be deleted.** When all of these hold:

- every step of 35.4 is done, and the self-hosted front end has been the default in one release;
- the fixed point runs in CI from the committed stage0;
- the per-stage goldens (35.4) pass without the Racket stages;
- no Makefile target, CI job or release step runs `racket` or `raco` except the test suite (`make version` reads the plain version file of step 8);
- `vm/tools/gen-unicode.rkt` is ported (its output, `vm/unicode_data.c`, stays checked in).

Then one PR deletes `src/*.rkt` and the `raco distribute` release steps, and tags the parent commit `bootstrap-racket`, the last commit that can make a stage0 from Racket. 18 of the 31 `tests/*.rkt` files require `src/` modules. In the same PR, the per-stage goldens replace the stage tests that call `src/` directly (`lexer-test`, `parser-test`, `modules-test`, `checker-test`, `bytecode-test`, `diagnostic-test` and the like), and those files are deleted. The other Racket tests (`vm-diff-common.rkt`, `examples-test.rkt`, `site-examples-test.rkt`, `cli-in-process.rkt` and the rest) drive only the binary. Replacing rackunit itself is a separate decision: the test suite stays on Racket until the owner chooses its replacement, because the choice changes the test rule in `AGENTS.md`.

### 35.4 Stages to port

One PR per step, in this order, each with differential tests against the Racket stage. This is the method of 21c to 21e (§31): during development a throwaway harness runs both stages over the whole corpus and compares their output; CI gets golden fixtures. The corpus is `examples/`, `stdlib/`, `tests/fixtures/`, the site examples, and every input of `tests/<stage>-test.rkt`, diagnostics included. Each golden is the Racket stage's output in a stable text form under `tests/fixtures/frontend/<stage>/`. While both stages exist, both must match it. After Racket is deleted, the goldens stay.

| Step | Racket stage | Compared output |
|---|---|---|
| 1 | Lexer (`src/lexer.rkt`, with `source.rkt`, `token.rkt` and the diagnostic data of `diagnostic.rkt`) | Tokens as text lines (kind, value, span), or the one `LEX-` diagnostic |
| 2 | Parser (`src/parser.rkt`, `ast.rkt`) | The AST in a stable text form, or the `PARSE-` diagnostic. Today `--dump` is Racket's `pretty-print` of the checked tree, so step 2 adds a printer with the same output on both sides |
| 3 | Modules and linker (`src/modules.rkt`, `stdlib.rkt`) | The linked program dump, with `std/` and `pkg/` resolution. Needs the environment and real-path builtins (35.5) |
| 4 | Checker (`src/checker.rkt`, `builtins.rkt`, `builtin-types.rkt`) | The `CHECK-` diagnostic, and the type of each expression |
| 5 | Lowering (`src/lower.rkt`) | The IR in the form `--dump-ir` prints, or the `LOWER-` diagnostic |
| 6 | Bytecode writer (`src/bytecode.rkt`) | The `.agcb` bytes, equal |
| 7 | BDD driver (`src/bdd-driver.rkt`) | The `agentica test` tests of §31.11 |
| 8 | CLI driver (`src/main.rkt`, the output forms of `diagnostic.rkt`, `version.rkt`, `vm-launch.rkt`) | Exit codes, stdout and stderr of every CLI test. The single binary and embedding (35.6) land here, and the self-hosted front end becomes the default |

Notes:

- Each step feeds the next with Agentica output, so the Agentica pipeline up to step N is all Agentica, and step N compares only its own output.
- The checker stores the type of each expression in an `eq?` hash keyed by the node (the development skill's `references/vm.md`, "Pipeline and files"). Agentica has no object identity, and a `Map` key is an `Int` or a `String`, so the parser gives each node an `Int` id in step 2, and lowering looks types up by id.
- The builtin catalog (`src/builtins.rkt`, `src/builtin-types.rkt`) moves to Agentica data in step 4. It remains the one description of the builtins, and `agentica help` reads it.
- **Source paths.** A required change before step 6: both front ends store source paths relative to the project root, not absolute (35.1), so the bytes do not depend on where the checkout lives. The PR that makes the change also decides how diagnostics print the path.
- **No gap between the drivers.** The BDD driver is ported before the CLI. Until step 8, the Racket `main.rkt` compiles and runs the Agentica BDD driver on the VM, as it runs the BDD runner today, and passes it the VM's path. So `agentica test` always works. Releases before step 8 ship today's archive (the Racket front end and `agentica-vm`). The first release after step 8 is the single binary.
- **Step 8 in detail.** The diagnostic forms (`format-diagnostic`, the `--ai` text, `diagnostic->jsexpr`) move to Agentica; `vm/diag.c` already prints the same forms for runtime errors. The version moves from `src/version.rkt` to a plain file that the Makefile reads and passes to C as `AGC_VERSION`, as it does today. `vm-launch.rkt` (finding the VM, stopping the child) is deleted: a normal run has no child, and the BDD driver starts children of the same binary with `Process.spawn_captured`, whose close already sends `SIGTERM`, then `SIGKILL`.
- No language change lands in a stage while its port is open (35.7).

### 35.5 Language and VM prerequisites

| Need | Status | Notes |
|---|---|---|
| No quadratic `push` | Known, planned | `xs = xs.push(x)` copies the list. Fixed by 8d, a prerequisite (35.9). |
| No quadratic `+=` on `String` | Known, no plan | `s += x` copies the string. A compiler builds big strings (dumps, `--json`, messages). Collect parts in a list and `join` them. To check on the corpus whether that is enough; if not, a string builder becomes a new prerequisite. Shared one-character strings (§34, 7g) cut the lexer's allocations if it reads characters with `at` or `split("")`. |
| Efficient map for symbol tables | Known, ready | `Map` is a persistent HAMT (`vm/map.c`): `put` is O(log n) and copies nothing. Keys are `Int` or `String` only, hence the node ids of 35.4. |
| JSON key listing | Known, not needed | No API lists an object's keys (phase 10, §15). The front end writes JSON (`--json`, `help --json`) with the builders, and reads none of unknown shape. |
| Read files, directories and module paths | Known, partly missing | `File.read_text`, `File.stat`, `Dir.list` exist. `File.read_text` stops at 1 MiB and Racket has no limit, so a bigger source file is read with `File.open`, `File.read_bytes` in a loop, and `String.from_bytes`. Missing, both needed by step 3: reading environment variables (`AGENTICA_PATH`, `XDG_DATA_HOME` and the home directory, `src/modules.rkt:29-50`), and a real-path builtin that resolves symbolic links, for module identity and the `pkg/` escape check (`normalize-path`, `src/modules.rkt:26,91-99`). `Path.resolve` is lexical and does not resolve links. Both are OS builtins (exception 1 of the std-first rule). |
| Write binary `.agcb` output | Known, partly missing | Agentica has no byte type: `Bytes` is deferred (§12.5, §23.1), and bytes are `List[Int]`, written with `File.write_bytes` (1 MiB per call). An `Int` as 8 two's-complement bytes and a `Float` as its IEEE bits need phase 13 (§23: the `Int` bit builtins, `Float` bits, `std/binary`). Phase 13 is a prerequisite. To check: a 2 MB `.agcb` as `List[Int]` is 32 MB of values; if that is too slow or too big for the start-up target, `Bytes` becomes a prerequisite. |
| Process spawning for the BDD driver | Partly known | `Process.spawn_captured` exists (21a), and the environment builtin above reads `AGENTICA_VM` and `TMPDIR`. To check, one by one: a child environment without `AGENTICA_VM_METRICS*`, a private 0700 temporary directory with an `flock`'d lock, recursive delete, and the `TMPDIR` mode check (`src/bdd-driver.rkt`). Each missing one is an OS builtin (exception 1). The path of the binary itself comes from C as an argument. |
| Handing the program to the VM | Known, missing | `agentica file.agc` must run the compiled program without a temporary file. A new builtin returns the bytes to C. C frees the front end's runtime and loads the program in a new one, so the user program never sees the compiler's heap or tasks, and `--max-steps`, `--seed` and `--allow-run` apply only to it. A second builtin reads an embedded `std/` source. Both are guarded in C at run time: they fail unless the running program is the embedded front end, which C knows because it loaded that program from its own data. A linker rule like the std-only `HttpWire` check cannot work here, because `compiler/` is not in `stdlib/`. |
| Call depth | To check | The VM stops at call depth 10,000 (`RUNTIME-STACK-OVERFLOW`, `docs/vm/05-values-execution-builtins.md` §6.1). A recursive-descent parser or checker on deeply nested input can reach it where Racket does not. Use explicit stacks on the deep paths, or add a `PARSE-` nesting limit (a diagnostic change, decided in step 2). |
| Speed | To check | The VM must run the front end on the largest corpus file within the start-up target (35.2), including loading and validating the embedded `.agcb`. The JIT (7m) is not required if the numbers hold. Compiling `compiler/` itself is a build step and has no target, but its time is recorded. |
| Stack traces | Known, planned | A crash inside the compiler must show where it happened in `compiler/`. 14b (order step 7.5) gives runtime errors a stack trace. |

### 35.6 Distribution

- **One file.** `agentica` is the VM binary with the front end inside. `agentica file.agc`, `check`, `compile`, `help`, `doc` and `test` keep their CLI. Running a compiled `.agcb` with today's VM flags becomes a subcommand of the same binary (its name is chosen in step 8). The separate `agentica-vm` and the `AGENTICA_VM` override go away; this is a breaking change for scripts that call `agentica-vm`, listed in that release's changelog.
- **Embedding.** One assembly file, built by the same compiler as the VM (`zig cc` in the release), uses `.incbin` to put two things into read-only data: the compiled front end (stage1, built from `stage0` at build time, 35.3), and every `stdlib/` source with an index of path, offset and length. The list of `std/` modules moves from `src/stdlib.rkt` to a plain file that the Makefile reads. The `std/` modules stay as source, because the front end compiles imports from source and `agentica doc` prints them (§32.5).
- **Linking.** As the release does today (the development skill's `references/ci.md`, "Release"): a pinned `zig cc` against glibc 2.28, checked with `objdump -T`, with Boehm GC, libuv, OpenSSL, yyjson and picohttpparser linked statically. glibc stays dynamic; a musl build stays separate (§18).
- **Size.** The VM is about 7 MB today. The front end adds an estimated 1 to 3 MB, because an `.agcb` carries its source text. The target is under 12 MB, against 89 MB today.
- **Licenses.** The archive keeps `LICENSE`, `NOTICE` and `licenses/` with the VM's third-party licenses. Racket's and Chez Scheme's files leave the archive, because the binary no longer contains Racket.

### 35.7 Risks

- **Two front ends diverge during the port.** While a stage exists twice, a change to it must change both in the same PR, and the goldens catch a miss. To keep that rare, the port starts when no front-end feature is in flight, each step is one PR, and no language change touches a stage while its port is open.
- **Bootstrap trust and reproducibility.** stage0 is a binary file in Git that nobody reads. The output must be deterministic: no times, and relative source paths (35.4). CI checks the fixed point on every PR. While Racket exists, CI also checks that Racket's `stage1` equals the self-compiled `stage2`, a diverse double compile. After that, anyone can rebuild the chain from the `bootstrap-racket` tag.
- **VM bugs break the compiler.** The compiler is now the biggest program the VM runs, and a VM bug can miscompile it, which then hides in stage0. Every VM PR runs the self-compile and the fixed point, also under the `vm-sanitizers` job (ASan and GC stress). A stage0 refresh is its own PR, never part of a VM change.
- **Debugging the compiler on the VM.** A compiler bug looks like a runtime error in `compiler/`, not in the user's program. The front end reports it as an internal error with its own code (as `LOWER-INTERNAL` does today) and the stack trace of 14b, and asks for a bug report. The dump flags (`--dump-ir`, and the token and AST dumps of steps 1 and 2) keep each stage visible, and `AGENTICA_VM_TRACE` works on the compiler as on any program.

### 35.8 Decided against

- **Embed Racket CS in the VM binary** (`racketcs.h`, `raco ctool --c-mods`): one file, but it fixes neither start-up nor the 40 to 60 MB size.
- **Port the front end to Chez Scheme:** it embeds small and starts fast, but it is a full port with no lasting gain over self-hosting.
- **Rewrite in OCaml:** the best option outside Agentica (its ADTs and pattern matching fit the stages; native, small, about 5 ms start-up, the C VM linked statically), but it adds a toolchain and a second language to maintain forever.
- **Rewrite in Rust:** its enums and `match` fit the stages too (§18), but it has the same cost as OCaml, a new toolchain and a second language forever, with slower builds.
- **Rewrite in Go:** no sum types, so the AST and the checker fit it badly (§18).
- **`raco exe --orig-exe` as an interim single file** (§18, the 7i item in `docs/roadmap/07-vm.md`): one 68 MB file that still starts in about 0.6 s. The owner waits for self-hosting instead.

### 35.9 Order

Long-term, after the current order in `docs/roadmap/README.md`. Order step 11 no longer decides the front end, and the options of §18 are closed. Before step 1 starts: faster lists (8d), binary data (phase 13), stack traces (14b) and the start-up measurement (7g, 7j). The roadmap gives the steps of 35.4 a phase number when it schedules them.
