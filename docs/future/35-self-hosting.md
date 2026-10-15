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
  The paths are relative to the project root (35.4, "Source paths"); they were
  absolute (`path->complete-path`) until that change, so the bytes depended on
  where the checkout lived. The loader rejects a file built for another
  Agentica version (`vm/loader.c:402`).

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
  driver, it sends the `std/` sources on the driver's stdin, and the driver
  writes them into its own private run directory and passes that path to the
  linker (decided in 7b: a folder made by Racket would stay behind when Racket
  is killed).

The step-7 BDD driver's `.agcb` is built once at `make exe` time and shipped in
the release archive until step 8 (owner decision). It is never compiled on each
run.

**The entry point (built in 8b).** `compiler/front_end.agc` is the program that
the binary runs as its front end. Its `main` reads the inputs
(`compiler/front_end_inputs.agc`) and calls `Cli.run`
(`compiler/front_end_cli.agc`), the one module that 8a replaces with the full
CLI; the C side does not change. The contract:

- **Arguments:** `--version V [--stdlib DIR] [--self PATH] -- WORDS...`. `V` is
  required: the Agentica version that the writer puts in every `.agcb` header
  (`Writer.write(root_dir, program, version)` refuses an empty one; there is no
  `VERSION` constant in `compiler/`). Without `--stdlib` the `std/` sources come
  from the binary (`FrontEnd.std_source`); with it, from the files of `DIR`.
  `PATH` is the path of the running binary (`Settings.self_path`, empty when
  the front end runs on `agentica-vm`), for a command that starts the binary
  again: 8d's `test` runs the test runner with `Process.spawn_captured` of
  `self_path`. C passes the target of `/proc/self/exe`, or `argv[0]` without
  `/proc`. `WORDS` are what the user typed after `agentica`, unchanged, so a
  user flag can never be taken for an input. The binary builds this list itself
  (it passes its own `AGC_VERSION` and path); `make` builds it for the
  bootstrap stages, which run on `agentica-vm` with `--stdlib stdlib`. C itself
  answers a lone `agentica --version`, before it opens a trace file or starts
  any front end.
- **Exit status:** 0 for success; 1 for a problem in the user's program (the
  plain diagnostic of `format-diagnostic`, on stderr, with the root file named
  as the user typed it and imported files by their canonical paths, as
  `src/main.rkt` does); 2 for a usage error, an input that cannot be read or an
  output that cannot be written, or a front end started wrongly. After
  `FrontEnd.hand_off`, the status of the program.
- **What it reads and writes:** it never reads standard input (the front end's
  runtime has none, so a read gives EOF and the program keeps the real one),
  opens no file the user did not name, and writes only the `-o` file of
  `compile` (and `--version` on stdout). It runs with no step limit and without
  `--allow-run`; the options the user typed reach only the program, through the
  `options` argument of the hand-off.
- **The words it understands in 8b:** `[--allow-run] [--max-steps N] [--seed N]
  [--flush-timeout MS] FILE.agc [ARGS...]` (compile in memory and hand the
  program to C to run), `compile FILE.agc -o OUT.agcb`, and `--version`.
  `check`, `doc`, `help` and `test` answer exit 2 and "not in this front end
  yet" until 8a. `--ai` and `--json` are 8a's too. The usage errors of this
  front end are its own and differ from the Racket CLI in a few places: a
  missing option value (`--max-steps` last), a repeated flag, a `--seed` of
  more than ten digits and the short usage text. They are 8a's to make equal
  (8a is the CLI), so no test pins them in 8b; the tests compare a bad value, an
  unknown switch, a missing file, a program that does not compile and
  `--version`.
- **The hand-off:** `FrontEnd.hand_off(program, options, arguments)` takes the
  bytes of the program (`List[Int]`), the VM option words (`--max-steps N`,
  `--seed N`, `--flush-timeout MS`, `--allow-run`, `--source-root DIR`, `--ai`,
  `--json`, as `agentica-vm` takes them, each once; `--driver-pid` is refused,
  because only the process that started the binary can name itself) and the
  program's arguments. It ends the front end's run and does not return, except
  with an error when a byte is not 0 to 255, a word has a character 0, or there
  are more than 64 options or 1,048,576 arguments. The front end checks the
  options (their messages are the Racket CLI's); C checks them again and refuses
  a bad one with exit 2. A front end is trusted with them: one that is loaded
  with `--front-end` can hand over `--allow-run`, so the flag is for the build
  and the tests only.

**How `make` builds it.** In 8b the stages are make targets, built in
`build/stage/` (`make stage1`, `stage2`, `stage3`). Racket compiles
`compiler/front_end.agc` to `stage1.agcb`. `stage1` and then `stage2` each
compile it again, as ordinary programs on `agentica-vm` with `--stdlib stdlib`.
`make fixed-point` checks `stage2 == stage3` and, while Racket exists,
`stage1 == stage2`. It then links `dist/agentica-next` with `stage2` and the
`std/` sources embedded, and checks that this binary, compiling the front end
with its own embedded sources, writes `stage2` again. CI runs it in the `test`
job and in `vm-sanitizers` (35.7). The binary is beside `agentica-vm` and the
Racket CLI, not the default.

From 8d the bootstrap changes: `make` links a first binary with `stage0` and the
`std/` sources embedded, uses it to compile `stage1`, uses `--front-end` with
`stage1` and then `stage2` to compile `stage2` and `stage3`, checks that they
are equal, and links the final binary with `stage2` embedded. The build-only
flag `--front-end FILE.agcb` makes the binary load `FILE` as its front end in
place of the embedded one, with the embedded provider; 8b builds it and the
tests use it. It is for the build and the tests only; the CLI help does not list
it.

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
the embedded one, or the file given to `--front-end` (`agc_load_front_end`,
built in 8b; the program that the front end hands over gets the full check). So
a version bump does not break the committed stage0, and stage0 is never
refreshed for a version bump. The version is not a constant in `compiler/`: it
is an input of the entry point, and the front end writes it into each `.agcb`
header. So `stage2` and `stage3`, made in the same build, carry the same
version, and the fixed-point check compares whole files. The committed stage0 is
a seed, not compared with `stage2`.

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
[§35.10](#3510-tests-move-to-python-unittest) phases 1 to 3. Today 22 of the 31
`tests/*.rkt` files require `src/` modules directly (9 of the 13 `*-test.rkt`):
the Racket stage tests, the live comparisons `frontend-*` and their helpers. The
per-file rewrites that this section used to list (`cli-in-process.rkt`,
`compile-file` in `vm-diff-common.rkt`, the site examples, the latency and trace
tests, `bdd-integration.rkt`, now `tests/test_bdd_integration.py`) are done
(phases 1 to 3, status below).

Replacing rackunit is decided: Python `unittest`, standard library only, in
phases that run beside steps 4 to 8
([§35.10](#3510-tests-move-to-python-unittest)). Phase 3 is 8c and 8d of
step 8 (35.4).

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
| 5 | **Done** (PR #282): Lowering (`src/lower.rkt`) | The IR in a text form of its own (not `--dump-ir`, see the status note below), or the `LOWER-` diagnostic. The port carries the lowering of module constants (§44.7, 44.8; done in `src/lower.rkt` by 44a2-2): scalar literal constants inlined, the other kept constants as zero-parameter functions, the `<start>` entry, the pruning by reachability from `main`, and the order of `Checked.constants`. The text form is `tests/frontend-lower-common.rkt` (Racket) and `compiler/lower.agc` (Agentica) |
| 6 | **Done** (PR #286): Bytecode writer (`src/bytecode.rkt`) | The `.agcb` bytes, equal (not a text form: the test compares the bytes of `compiler/bytecode.agc` with the ones Racket writes; see the status note below). The port writes every section as `src/bytecode.rkt` does, format version 5 with the Updates and Globals sections, and has its `BYTECODE-` diagnostics |
| 7 | **Done** (7a, the OS builtins the port needs, audited in 35.5, PR #288; 7b, the driver, PR #294): BDD driver (`src/bdd-driver.rkt`) | The `agentica test` tests (`tests/test_bdd.py`, `tests/test_bdd_integration.py`, `tests/unit-test-test.rkt`). The port is `compiler/bdd.agc` over the `compiler/bdd_*.agc` modules; see the status note below |
| 8 | **8a done** (PR #299): CLI driver (`src/main.rkt`, the output forms of `diagnostic.rkt`, `version.rkt`, `vm-launch.rkt`) | Exit codes, stdout and stderr of every CLI test. The single binary and embedding (35.6) land here, and the self-hosted front end becomes the default |

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
- **Source paths. Done.** Both front ends store source paths relative to the
  project root, not absolute (35.1), so the bytes do not depend on where the
  checkout lives. The rules:
  - The project root is the folder of the entry file (the root file of the
    link), the same folder that anchors `agc_libs/`. Resolution is unchanged;
    only the stored form changes. `src/source.rkt` (`stored-source-names`,
    used by `ir->bytecode`) and `Paths.stored_name` in
    `compiler/import_path.agc` (the `name` of a `LinkedModule`) compute it the
    same way.
  - A file inside the root is stored as its path from there, joined with `/`
    and with no `./` (`main.agc`, `lib/util.agc`). The entry file is its own
    file name. A `std/` module keeps its `std/NAME.agc` key, and a user file
    under a `std/` folder is `./std/NAME.agc`.
  - An import that goes above the root with `../` is allowed, as before, and
    keeps the `..` parts (`../shared/x.agc`). A `pkg/` library found outside
    the root (the user or system library folders) is stored the same way, so
    its path depends on how deep the project is; vendor libraries in
    `agc_libs/` for reproducible bytes. Only a file on another drive
    (Windows) stays absolute.
  - Compile-time diagnostics (plain, `--ai`, `--json`) print as before, from
    the front end's own source names: the entry file as written on the command
    line, imported files by their canonical path. They are never stored.
  - Runtime diagnostics and stack traces read the stored names from the
    `.agcb`, and `agentica` prints them as before for the entry file: it passes
    `--source-root DIR` to the VM, where DIR is the folder of the entry file
    seen from the working directory (built from the canonical folder, so `..`
    names stay right through links; absolute when the entry was typed as an
    absolute path; not passed when the entry is in the working directory).
    The VM puts `DIR/` before every stored name that is relative and does not
    start with `std/`, once, after the load (`agc_program_set_source_root` in
    `vm/loader.c`); a user file under a `std/` folder is stored as
    `./std/NAME.agc` so it is not taken for a standard module. So
    `agentica examples/hello.agc` shows `examples/hello.agc:3:5`, as before,
    and an import shows `examples/lib/util.agc` where it showed an absolute
    path.
    `agentica test` passes the option for the step program and for each test
    file too. `agentica-vm x.agcb` alone prints the stored names.
  - The stored name of a file is built from its canonical path, so a link in
    the way of the entry (a linked folder or file) changes nothing.
  - The text forms of `compiler/` print the stored path (`module "path"`,
    ` file="path"`), so the Racket oracle and the Agentica linker agree on
    the `..` case (`tests/frontend-modules-test.rkt`).
  - `tests/test_source_paths.py` compiles one program from two folders and
    checks that the two `.agcb` are equal byte for byte.
- **No gap between the drivers.** The BDD driver is ported before the CLI. Until
  step 8, the Racket `main.rkt` compiles and runs the Agentica BDD driver on the
  VM, as it runs the BDD runner today, and passes it the VM's path. So
  `agentica test` always works. Releases before step 8 ship today's archive (the
  Racket front end and `agentica-vm`). The first release after step 8 is the
  single binary. A release is cut right after step 7b merges, as a fixed
  starting point before the self-hosted front end becomes the default (owner
  decision, 2026-10-15). It is the last release with the Racket front end, and
  step 8 (split below) comes after it.
- **Step 7 status (7b).** The driver is `compiler/bdd.agc` (the program) over
  `bdd_driver.agc` (the run), `bdd_options.agc` (the arguments),
  `bdd_discover.agc` (walking the test paths), `bdd_compile.agc` (the pipeline
  of steps 3 to 6 from a file to the bytes of its `.agcb`, with the first
  problem of any stage), `bdd_rundir.agc` (the temporary directory, the lock and
  the sweep), `bdd_runner.agc` (starting the runner and reading its report),
  `bdd_report.agc` (the usage and infrastructure reports), `bdd_files.agc`,
  `bdd_source_root.agc` and `diagnostic_json.agc` (the `--json` form of a
  diagnostic, for step 8 as well). `src/bdd-driver.rkt` is now the hand-off and
  nothing else: it finds `agentica-bdd-driver.agcb` (built by `make` into
  `dist/`, next to the VM and the executable, and in the release archive),
  writes a private copy of it (a VM started with `--driver-pid` reads only a
  private file and deletes it), starts it on the VM with `--driver-pid`, sends
  it the `std/` sources on stdin and returns its stdout and exit code to
  `main.rkt`. The old Racket driver is not kept as an oracle: the tests of
  `agentica test` are end-to-end and independent of it, and the two were
  compared once, on 25 runs (all three formats, relative and absolute paths,
  compile errors in a test file and in the step program, usage errors, `--only`,
  links, a missing path), with equal exit codes and reports except for the
  random seed and the path of a `--steps` file that has `..` parts, which the
  new driver makes lexically simple (as it does for the paths of the tests). The
  freeze (row 7.2.7) is relaxed for `src/` only as the hand-off needs:
  `src/bdd-driver.rkt` shrinks to the hand-off, and the `test` branch of
  `src/main.rkt` passes the words after `test` to it (the driver reads them,
  usage errors included). The runner (`stdlib/test/runner.agc`) gains one
  configuration field, `report_path`.
- **Step 8 in detail.** The diagnostic forms (`format-diagnostic`, the `--ai`
  text, `diagnostic->jsexpr`) move to Agentica; `vm/diag.c` already prints the
  same forms for runtime errors. The version moves from `src/version.rkt` to a
  plain file that the Makefile reads and passes to C as `AGC_VERSION`, as it
  does today. `vm-launch.rkt` (finding the VM, stopping the child) is deleted: a
  normal run has no child, and the BDD driver starts children of the same binary
  with `Process.spawn_captured`, whose close already sends `SIGTERM`, then
  `SIGKILL`.
- **Step 8 is four PRs**, decided by the owner on 2026-10-15. One PR would be
  too large to review, and it would block on any failure of the release build.
  The release cut comes first, right after step 7b merges, with Racket still the
  default and the Agentica BDD driver in place. The four PRs:
  - **8a, the CLI driver.** The driver and the diagnostic forms (plain, `--ai`,
    `--json`) move to Agentica, with the plain version file. It runs as an
    ordinary `.agcb` and is compared with the Racket CLI (exit codes, stdout,
    stderr). Not the default yet.
  - **8b, the single binary. Done** (PR #298). The `.incbin` embedding of
    `stage2` and of the `std/` sources (35.6), the two builtins that hand the
    compiled program to C and read the embedded `std/` sources (35.5), the
    build-only `--front-end FILE` flag, and the `make` stages `stage1`, `stage2`
    and `stage3`, with the fixed-point check in CI (35.3). It builds the binary
    (`dist/agentica-next`) beside today's files, not as the default. It runs in
    parallel with 8a: it first fixed the entry point and the two builtins (the
    contract is in 35.3), and 8a plugs into them. 8a (done) replaced
    `compiler/front_end_cli.agc` with the full CLI and the diagnostic forms, and
    moved the version to the plain file `VERSION`. What 8d still does: it makes
    `dist/agentica-next` the `agentica` of the archive, adds the subcommand that
    runs a compiled `.agcb` with the VM flags (the binary has none yet), and
    switches the bootstrap to `stage0` (35.3).
  - **8c, tests only.** The first half of phase 3 (35.10): every live comparison
    with the Racket stages is frozen into a golden. It may run in parallel with
    8a and 8b.
  - **8d, the switch.** The single binary becomes the default and the only file
    in the release archive. `agentica-vm` and `AGENTICA_VM` go away (a breaking
    change, listed in the changelog), `src/vm-launch.rkt` is deleted,
    `bootstrap/stage0.agcb` is checked in and CI checks the fixed point from it,
    and the rackunit files with their make targets and CI steps are removed
    (the second half of phase 3).
  - No release with both front ends in between: it would keep two front ends
    alive longer (risk 1 of 35.7), and the private alpha has no external users
    who need it.
- **Step 8a status. Done** (PR #299). The command line is `compiler/cli.agc`,
  `Cli.run(settings, words, host, hand_off) -> Int` (the exit status), over
  `cli_options.agc` (the options in front of the command, read as Racket's
  `command-line` reads them), `cli_help.agc` and `cli_text.agc` (`help`, `-h`
  and the fixed texts), `cli_reply.agc` (what a command answers),
  `cli_host.agc` (the `Host` and the `Launch`), `pipeline.agc` (read, link,
  check, lower and write, shared with the BDD driver), `diagnostic_plain.agc`
  and `diagnostic_ai.agc` (the plain and `--ai` forms; the JSON form is
  `diagnostic_json.agc`) and `save_file.agc` (the `compile` output), all of
  them from or on top of 8b's. It has two homes, and both run the same
  module:
  - **The single binary** (`compiler/front_end_cli.agc`, which 8b left for 8a
    to replace): `dist/agentica-next` has `check`, `compile`, `help`, `-h`,
    `--ai`, `--json`, `--dump`, `--dump-ir` and the run of a program, with
    `hand_off` calling `FrontEnd.hand_off` with `Launch.bytes`, `Launch.flags`
    and `Launch.arguments`. C does not change. `test` answers status 2 and
    `the test command is not in the single binary yet: it cannot start the test
    runner (step 8d)`: the front end runs without `--allow-run` (it cannot start
    the runner) and the binary has no command that runs a compiled file with
    the VM options, which 8d adds.
  - **An ordinary program** (`cli_main.agc`, which `make cli` compiles to
    `dist/agentica-cli.agcb`): `tests/agentica-agcb` runs it on the VM as the
    `agentica` command, with `cli_spawn.agc` as the hand-off and the real `test`.
    `make test-cli` runs the tests of the product command line on it
    (`tests/test_examples.py`, `test_filesystem.py`, `test_process.py`,
    `test_source_paths.py`, `test_source_utf8.py`, `test_bdd.py`).
  Neither is the default: `bin/agentica` is still Racket.
  - **Inputs of `Cli.run`.** `settings` are 8b's `Env.Settings`: the Agentica
    version (`settings.version`, which the writer puts in every header), the
    provider of the `std/` sources (a folder, or the binary) and the path of the
    binary. `words` are what the user typed. `host` is `Host(vm, command,
    no_tests)`: the VM binary and the words that run the front end again (for
    `agentica test`), and the reason `test` cannot run, or an empty string.
    `hand_off` is `Fn[Host, Launch, Int]`; `Launch` holds the bytes, the VM
    option words (`--max-steps`, `--seed`, `--flush-timeout`, `--allow-run`,
    `--source-root`, `--ai` or `--json`, in the order `src/main.rkt` gives them)
    and the program arguments.
  - **The version file.** `VERSION` (one line) is the only source of the
    version: the Makefile reads it for `AGC_VERSION` and `make version`,
    `src/version.rkt` embeds it when it is compiled (so `raco exe` and `raco
    distribute` need no file at run time), and `EXE_INPUTS` and the stages of
    the bootstrap depend on it. `compiler/` has no `VERSION` constant: the
    writer takes the version (8b's `Writer.write(root_dir, program, version)`),
    and the BDD driver takes `--version V` (`src/bdd-driver.rkt` passes it)
    instead of asking the VM for it.
  - **`test`** calls the BDD driver in the same process (`Driver.run_with`),
    with the settings of the command line and the options in front of `test`;
    it does not read the `std/` sources from stdin. The driver is no longer a
    program on `AGENTICA_VM`: only the runner and the programs under test are.
    The Racket `src/bdd-driver.rkt` still starts it as a program and sends the
    sources on stdin (`Driver.run`).
  - **Limits of the hand-off of an ordinary run** (`cli_spawn.agc`; the single
    binary has none of them). It writes the program to a new 0600 file in the
    temporary directory, starts `agentica-vm --driver-pid PID -- FILE ARGS` with
    `Process.spawn` under `/bin/sh` (so that a SIGTERM to the command line
    reaches the program's VM as a SIGTERM and it stops its own children, not as
    the SIGKILL that a plain child gets), and removes the file. A `Process` is a pipe, so (1) the
    program's stdin and stdout pass through this process one byte at a time
    (`Process.read_bytes` and `IO.read_bytes` wait for a whole count; a larger
    read would hold back a reply of an interactive program), which gives about
    3.5 MB in 7 seconds; (2) the stdout goes through that copy while the stderr
    is inherited, so with `2>&1` the two streams can come out of order; (3) a
    `--flush-timeout 0` message that Racket prints is missing; (4) a broken
    pipe on the stdout is reported against `cli_main.agc`, not against the
    program; (5) a failing read of this process's stdin ends the program's
    input, where Racket stops the VM and prints `RUNTIME-INTERNAL` ("cannot read
    standard input"). The messages for a temporary directory that cannot be
    written (named with a slash at its end) and for a missing VM (`AGENTICA_VM`
    made absolute, nothing else changed) are the same as Racket's.
  - **Deliberate differences.** (1) `--dump` and `--dump-ir` print the text
    forms of `compiler/check_text.agc` and `lower_text.agc`; Racket prints
    `pretty-print` of its structures and `format-ir`, which cannot be reproduced
    and leave out what the bytecode needs. (2) `-abc` is not read as three short
    options: `-h` is the only one (`-hx` is the help, `-xh` is `unknown switch:
    -x`, as in Racket). (3) An empty source file name is `cannot read ` (status
    2); Racket stops with a contract error. (4) With `AGENTICA_TEST_EXECUTABLE`
    set to the Agentica command line, two tests of `test_bdd.py` change: a
    crashing driver cannot be simulated with a fake `AGENTICA_VM`, and a
    temporary directory that cannot be written gives the driver's infrastructure
    report in the chosen format instead of the plain `cannot write a temporary
    file` line. (5) `test` in the single binary (above). Nothing else: the exit
    codes, stdout and stderr agree on the corpus (below). The usage errors that
    8b left different (a missing option value, a repeated flag, a `--seed` of
    more than ten digits, the usage text) now agree, and
    `tests/test_single_binary.py` compares them.
  - **Parity.** `racket src/main.rkt`, `tests/agentica-agcb` and
    `dist/agentica-next` give the same exit code, stdout and stderr for `--json
    check` of the 892 `.agc` files of `examples/`, `stdlib/` and
    `tests/fixtures/` (502 of them fail), for the plain and `--ai` forms of
    those 502, for `--max-steps 3000000` runs of the 25 files of `examples/` and
    the 242 of `tests/fixtures/vm/` (plain and `--json`), and for the cases of
    `tests/test_cli_parity.py` (options and their mistakes, the diagnostics of
    every stage, runs with stdin and arguments, `compile`, `help`, a 100 KB file
    that is not UTF-8; the class for the binary also checks that `puts` and
    `IO.warn` keep their order with `2>&1`). The `.agcb` that `compile` writes
    is byte for byte the same. `dist/agentica-next` passes the product tests of
    `test-cli` except those that run `agentica test`. Timings on a shared
    machine, one run each, Racket, the ordinary program and the binary, in
    seconds: `--version` 0.54, 0.03 and 0.00; `check hello.agc` 0.53, 0.03 and
    0.03; running `hello.agc` 0.58, 0.04 and 0.02; `check
    stdlib/bdd/gherkin.agc` 0.74, 0.13 and 0.12; `check compiler/parser.agc`
    0.84, 0.42 and 0.40; `check` of a 100 KB file with bad bytes 0.79, 0.40 and
    0.40.
- No language change lands in a stage while its port is open (35.7).
- **Reading source files. Done** (decided by the owner on 2026-10-15). The two
  front ends used to read differently: Racket's `file->string` replaced invalid
  bytes with U+FFFD and had no size limit, while `File.read_text` is strict
  UTF-8 with a 1 MiB limit. Now both read the same way:
  - Invalid UTF-8 in a source file is an error in both, the new stable
    diagnostic `LEX-INVALID-UTF8`, located in the file that has the bad bytes
    (the root file, or an imported file like any other lexer error). Its span
    starts at the first byte of the first sequence that does not decode, with
    the line and column of the characters decoded before it, and has length 1.
    "Does not decode" is the strict rule of `String.from_bytes`: no overlong
    form, no surrogate, nothing above U+10FFFF, no truncated sequence at the end
    of the file. The message and the help are equal on both sides. It is a bug
    fix in the frozen Racket front end, so both front ends changed in the same
    PR.
  - A source file has no size limit. `compiler/source_file.agc` reads a file
    with `File.open` and `File.read_bytes` in chunks of 256 KiB, decodes each
    chunk with `String.from_bytes` (the bytes of a character that a chunk
    cuts in two wait for the next chunk) and joins the pieces once, so nothing
    is quadratic. Only on the error path does it find the first invalid byte,
    with a small validator over the byte list, and it counts the lines and
    columns in a loop over that validated prefix, without copying it. `lex.agc`,
    `parse.agc` and both read sites of `modules.agc` use it. Racket reads the
    bytes in `src/source-file.rkt` (`file->string` is gone from the front end;
    the embedded `std/` sources are trusted and still read at compile time).
  - I/O errors keep their codes and spans: `CHECK-IMPORT-IO` at the start of
    the root file, or "cannot read import" at the import.

### 35.5 Language and VM prerequisites

| Need | Status | Notes |
|---|---|---|
| No quadratic `push` | Known, planned | `xs = xs.push(x)` copies the list. Fixed by 8d, a prerequisite (35.9). |
| No quadratic `+=` on `String` | Known, no plan | `s += x` copies the string. A compiler builds big strings (dumps, `--json`, messages). Collect parts in a list and `join` them. To check on the corpus whether that is enough; if not, a string builder becomes a new prerequisite. Shared one-character strings (§34, 7g) cut the lexer's allocations if it reads characters with `at` or `split("")`. |
| Efficient map for symbol tables | Known, ready | `Map` is a persistent HAMT (`vm/map.c`): `put` is O(log n) and copies nothing. Keys are `Int` or `String` only, hence the node ids of 35.4. |
| JSON key listing | Known, not needed | No API lists an object's keys (phase 10, §15). The front end writes JSON (`--json`, `help --json`) with the builders, and reads none of unknown shape. |
| Read files, directories and module paths | Known, ready | `File.read_text`, `File.stat`, `Dir.list` exist. `File.read_text` stops at 1 MiB and Racket has no limit, so a source file is read with `File.open`, `File.read_bytes` in a loop, and `String.from_bytes` (`compiler/source_file.agc`, 35.4). Both builtins that step 3 needs are done (row 7.2.6 of the order, OS builtins in C, exception 1 of the std-first rule, no new flag): `System.env(name)` reads environment variables (`AGENTICA_PATH`, `XDG_DATA_HOME` and, as `System.env("HOME")`, the home directory; `src/modules.rkt:29-50`), and `Path.real(path)` resolves symbolic links, for module identity and the `pkg/` escape check (`normalize-path`, `src/modules.rkt:26,91-99`). `Path.real` is POSIX `realpath`, so it fails on a path that does not exist where `normalize-path` does not: the linker checks that a file exists first, as `file-exists?` does there. `Path.resolve` is lexical and does not resolve links. |
| Write binary `.agcb` output | Known, ready | Agentica has no byte type: `Bytes` is deferred (§12.5, §23.1), and bytes are `List[Int]`, written with `File.write_bytes` (1 MiB per call). An `Int` as 8 two's-complement bytes and a `Float` as its IEEE bits are `std/binary` (§23: `Binary.write_i64_be`, `Binary.write_f64_le`, `Binary.concat`), built on the `Int` and `Float` bit builtins; phase 13 (row 7.2.4 of the order) is done. To check: a 2 MB `.agcb` as `List[Int]` is 32 MB of values; if that is too slow or too big for the start-up target, `Bytes` becomes a prerequisite. |
| Process spawning for the BDD driver | Known, ready (step 7a) | `Process.spawn_captured` exists (21a), and the environment builtin above reads `AGENTICA_VM` and `TMPDIR`. The audit of `src/bdd-driver.rkt` is the table under this one, and the OS builtins it found missing are done (step 7a: `vm/files.c`, `vm/tree.c`, `vm/process.c`; each is an OS builtin, exception 1 of the std-first rule, with no new flag). The path of the binary itself comes from C as an argument. |
| Handing the program to the VM | **Done** (8b) | `agentica file.agc` runs the compiled program without a temporary file. `FrontEnd.hand_off(program, options, arguments)` gives the bytes, the VM option words and the arguments to C and ends the front end's run. C retires the front end's runtime (children stopped, output flushed, event loop closed, one collection) and loads the program in a new one, so the user program never sees the compiler's heap or tasks, and `--max-steps`, `--seed` and `--allow-run` apply only to it. `FrontEnd.std_source(path)` reads an embedded `std/` source by its path in `stdlib/` (`queue.agc`, `bdd/gherkin.agc`). Both are guarded in C at run time: they fail with `RUNTIME-FRONT-END-ONLY` unless the running program is the front end that C loaded itself (from its own data, or from `--front-end`, 35.3), which C knows because only then does the runtime have an `agc_front_end`. They are in both builtin tables (`src/builtins.rkt`, `compiler/builtins_data.agc`) without the std-only mark: a linker rule like the std-only `HttpWire` check cannot work here, because `compiler/` is not in `stdlib/`. |
| Call depth | To check | The VM stops at call depth 10,000 (`RUNTIME-STACK-OVERFLOW`, `docs/vm/05-values-execution-builtins.md` §6.1). A recursive-descent parser or checker on deeply nested input can reach it where Racket does not. Use explicit stacks on the deep paths, or add a `PARSE-` nesting limit (a diagnostic change, decided in step 2). **Decided in step 2:** both parsers stop with `PARSE-TOO-DEEP` past 1,000 levels (up to about 8 VM frames per level, 1.25 times the limit at the tightest). It bounds the parser's calls, not the depth of its tree (see 35.9). **Decided in step 4:** both checkers stop with `CHECK-TOO-DEEP` past 1,000 levels of expressions and statements, which bounds the depth of the tree (3 to 4 VM frames per level in the checker, so at most about 4,000 frames). |
| Speed | To check | The VM must run the front end on the largest corpus file within the start-up target (35.2), including loading and validating the embedded `.agcb`. The JIT (7m) is not required if the numbers hold. Compiling `compiler/` itself is a build step and has no target, but its time is recorded. |
| Stack traces | Known, planned | A crash inside the compiler must show where it happened in `compiler/`. 14b (row 7.2.5 of the order, before the freeze) gives runtime errors a stack trace. |

The audit of the BDD driver's OS needs (step 7a). Each row is a need of
`src/bdd-driver.rkt`, the Agentica call that covers it, and whether that call
existed:

| Need | In `src/bdd-driver.rkt` | In Agentica | Result |
|---|---|---|---|
| A runner environment without `AGENTICA_VM_METRICS*` | `run-runner` clears both names in a copy of the environment | `Process.spawn_captured` | **Existing builtin, new rule.** The child environment of every `Process.spawn*` drops `AGENTICA_VM_METRICS` and `AGENTICA_VM_METRICS_FILE`, matched with their `=` (the rule of §28.5, done early because the driver cannot edit a child's environment). `System.env` still shows them to the program itself. The VM reads neither variable yet (phase 18), so nothing else changes. |
| A private 0700 temporary directory | `make-directory current #o700`, which fails when the name exists | `Dir.mkdir_private(path, timeout_ms)` | **New.** `Dir.mkdir` creates parents and accepts an existing directory, so it cannot claim a name. |
| Giving the run directory its final name | `rename-file-or-directory current directory`: the driver makes `agentica-bdd-new-<hex>`, locks a file in it, and only then renames it to `agentica-bdd-<hex>`, so a concurrent sweep, which looks at `agentica-bdd-<hex>` names only, never finds an unlocked directory | `Path.rename(from, to, timeout_ms)` | **New.** One `renameat2` with `RENAME_NOREPLACE`: it never replaces, so a name that is taken stays taken (plain `rename` replaces a file and an empty directory), and it is atomic. The lock follows the file, since it belongs to the open file and not to the path. A file system that lacks `RENAME_NOREPLACE` (some network file systems) answers with an error, which the driver reports as an infrastructure error. |
| Finding the temporary directory | `(find-system-path 'temp-dir)` (`bdd-driver.rkt`, line 245): `TMPDIR` when it is set and names a directory, else the first directory among `/var/tmp`, `/usr/tmp` and `/tmp` | `System.env("TMPDIR")` and `File.stat` | **Existing, no builtin.** The port walks the same list and takes the first path that `File.stat` says is a directory (a relative `TMPDIR` is kept as given, as in Racket). When none is a directory it reports an infrastructure error. |
| An `flock`'d lock file | `open-output-file ... #:exists 'error #:permissions #o600`, then `port-try-file-lock?` | `File.open(path, "create_private", ms)`, then `File.try_lock(handle, ms)` | **New** (the open mode and the lock). The lock belongs to the open file, so `File.close`, the end of the owning task and the end of the process release it, and no child inherits it (descriptors are close-on-exec). `ok(false)` says another handle or process holds it: the call never waits. |
| Locking the lock file of a possibly stale directory | `abandoned?` opens the file with `#:exists 'update` and tries the lock | `File.open(path, "read", ms)`, then `File.try_lock` | **Existing open, new lock.** `flock` does not need write access, so a read handle locks. |
| The `TMPDIR` mode check | `file-or-directory-stat` for `mode`, `user-id` and `group-id` of `TMPDIR` (links followed) and of the new directory | `File.stat` and `File.lstat` | **New `FileInfo` fields** `mode` (`st_mode & 07777`, so the sticky and setgid bits are in it), `user_id` and `group_id`, appended after `modified_seconds` in `File.stat`. |
| An `lstat`-like call | `file-or-directory-type path #t` and `file-or-directory-stat path #t` in `discover` and `abandoned?` | `File.lstat(path, timeout_ms)` | **New.** It returns `FileInfo` like `File.stat`, but a symbolic link is described itself (`kind` is `"link"`); `File.stat` then tells what the link names. |
| The process's own PID | `getpid`, given to the runner as `--driver-pid` | `System.pid()` | **New.** The child VM compares it with its parent (`bind_to_driver`), so the value must be the VM's own PID. |
| A 0600 write of the bytecode, the config and the lock | `write-private`: `#:exists 'error #:permissions #o600` | `File.open(path, "create_private", ms)`, `File.write_bytes`, `File.close` | **New open mode**, no new write builtin, so a file larger than 1 MiB is written in several calls. A VM started with `--driver-pid` reads only a private bytecode file (owner, one link, no group or other bits) and deletes it. |
| Delete a file, and remove the run directory tree | `delete-directory/files` on each child of the run directory, then on the directory | `Path.remove(path, ms)` | **New** (`vm/tree.c`), one builtin for both, named as §46.4 names it. It unlinks a file or a link itself; a directory it opens level by level with `O_NOFOLLOW` and empties with `unlinkat`, so a link inside the tree is removed as a link and its target is never touched. A missing path is `ok()`, like `#:must-exist? #f`. It refuses `/`, `.` and `..` (as the last part of a path), and a tree deeper than 128 levels. Like Racket's `delete-directory/files`, and Python's `rmtree`, it crosses mount points. A failure inside the tree names the entry that failed, as they do. A timeout returns the error but does not stop a removal that is running. |
| A random directory name | `crypto-random-bytes 16` | `Random.int` | **Existing, weaker.** The driver VM is not run with `--seed`, so the draws come from OS entropy, but `Random.int` has a 31-bit seed: the names can be guessed. That is only a denial of service, never a way in: a hostile local user could occupy the names the driver will draw, but `Dir.mkdir_private` is exclusive and 0700, so the driver can never end up in a directory it did not make. The port tries a bounded number of times (16), a new name each time, and after the last failure reports an infrastructure error that names the temporary directory and the last system error. Reading 16 bytes of `/dev/urandom` with `File.open` and `File.read_bytes` needs no new builtin and gives an unguessable name; step 7b picks one (decided below). |
| Walking the test paths | `directory-list`, `file-or-directory-type`, `directory-exists?`, `file-exists?` | `Dir.list`, `File.lstat`, `File.stat` | **Existing, with one gap.** `Dir.list` decodes names lossily, so `utf-8-name?` cannot tell a name with a bad byte from one with a real U+FFFD. The port treats a name with U+FFFD as not UTF-8 (a real U+FFFD in a file name is the only false report); step 7b records the choice. |
| Starting the runner and reading its output | `subprocess`, with a thread that copies each stream | `Process.spawn_captured`, `Process.output`, `Process.wait`, `Process.close` | **Existing, with one limit to check in 7b.** A captured stream keeps 1 MiB; the Racket driver keeps any size. A `--json` report of a very large run may pass it, and `Process.output` then marks it truncated. |
| Cleanup when a signal ends the driver | `dynamic-wind` and `stop-vm`: a break (Ctrl-C, SIGTERM) unwinds the driver, which removes its run directory and closes the lock | the VM's own end of run | **Existing, and a behavior change.** The VM does not unwind: a stop signal ends it between turns, kills its children and does not run the program's cleanup. A run stopped that way leaves its directory in the temporary directory until the next run's sweep removes it; the lock is what tells that sweep the directory is abandoned, since the process's end releases it. Until §46 gives a program a stop hook, step 7b records this as a known difference from the Racket driver. |

**Decided in step 7b.** The choices the audit left to the port:

- **(a) Random names.** The driver reads 16 bytes of `/dev/urandom` with
  `File.open` and `File.read_bytes` (a loop until it has 16) and writes them as
  32 hex digits, so a name cannot be guessed (`Random.int` has a 31-bit seed).
  It tries `Dir.mkdir_private` up to 16 times, each with a new name, and after
  the last failure reports `RUNTIME-BDD-INFRA` with the message `cannot make a
  private directory in TMPDIR: LAST SYSTEM ERROR`. The final name comes from a
  new draw, and a `Path.rename` that fails is an infrastructure error too.
- **(b) Lossy names.** `Dir.list` decodes a name with a byte that is not UTF-8
  as U+FFFD, so the driver treats every name with a U+FFFD as not UTF-8 (the
  only false report is a file whose name really has a U+FFFD). Such a name
  cannot be passed to `File.lstat`, so its kind is unknown: it is the error
  `the file name is not valid UTF-8` when its name fits (`.feature`,
  `_test.agc`), and a folder or file that does not fit is skipped. This is one
  difference from the Racket driver: it also reported a folder with a bad name,
  which it could tell was a folder.
- **(c) The 1 MiB of a captured stream.** A large `--json` run does pass it: a
  report of 1.6 MB (40 tests with long names) was cut to 1 MiB. Reading the
  stream in a loop does not help, because the VM keeps only 1 MiB of unread
  data and drops the rest, so a report written in one burst is cut even when
  the reader is waiting. The better way: the runner writes its report to a new
  file of the run directory (`report_path` in its configuration, mode 0600, in
  pieces of at most 1 MiB) and the driver reads that file with
  `compiler/source_file.agc`, which has no size limit. The report no longer
  travels on stdout, so there is no truncated report to handle. Stderr stays
  captured: 1 MiB of it is more than any diagnostic needs, and the driver shows
  only the last diagnostic of it. `tests/test_bdd.py` runs a report of more
  than 1 MiB.
- **(d) Signals.** The VM does not unwind: a stop signal (Ctrl-C, SIGTERM)
  ends the driver's VM between turns, which stops its children, and the run
  directory stays until the next `agentica test` sweeps it (the lock ends with
  the process). The Racket driver removed it before it ended. A Ctrl-C from
  the terminal reaches the whole process group, so the runner ends too and the
  driver often finishes its cleanup before the signal ends it; a `SIGTERM` to
  the driver alone does not. So the directory may stay: a known difference
  until §46 gives a program a stop hook. The same goes for a driver killed with
  SIGKILL, which the Racket driver also left behind. `--driver-pid` ties the
  driver's VM to `main.rkt` and the runner to the driver, so killing `main.rkt`
  still stops everything.
  Two small windows stay. A run killed between `Dir.mkdir_private` and the
  lock leaves `agentica-bdd-new-HEX` (the Racket driver left it too): the sweep
  removes such a directory when it passes the same checks as a final one (a
  directory of the user, with a real `lock` file whose lock it can take) and
  its mtime is over an hour old, so it never races a live run that is between
  `mkdir` and the lock. And a driver killed with SIGKILL before its VM has
  loaded the private copy of the driver's bytecode leaves that copy in the
  temporary directory; nothing sweeps it. Both are known gaps, closed with the
  stop hook of §46.
- **(e) The temporary directory.** `System.env("TMPDIR")` and `File.stat`, as
  Racket's `find-system-path 'temp-dir`: `TMPDIR` if it is a directory (a
  relative one is kept as given), else the first directory among `/var/tmp`,
  `/usr/tmp` and `/tmp`. `main.rkt` uses the same rule to put the copy of the
  driver's bytecode. When none is a directory, the driver reports an
  infrastructure error.

Other choices of the port:

- **The VM is gone.** When `main.rkt` cannot find or run the VM, nothing can
  run, not even the driver: it prints `agentica: cannot find the VM at PATH; run
  make vm or set AGENTICA_VM` on stderr and exits 2, as `agentica file.agc`
  does. The Racket driver printed an infrastructure report in the chosen
  format. The same for the driver file and for a `TMPDIR` that `main.rkt` cannot
  write (`cannot write a temporary file in DIR`).
- **A driver that crashes.** A runtime error in the driver itself (a bug)
  ends its VM with status 1 and prints nothing on stdout, which would look like
  "the tests failed". `main.rkt` turns that case (no stdout, status not 0) into
  status 2; the error stays on stderr.
- **Tests of `agentica test` with a fake VM.** `AGENTICA_VM` now names the VM
  that runs the driver too; a test that wants a fake runner VM makes a script
  that runs the real VM unless it is asked for `runner.agcb`.
- **Compile errors.** The driver reads each test file and the step program once
  with `compiler/source_file.agc` (an unreadable file is `cannot read the test
  file PATH`, an invalid one `LEX-INVALID-UTF8` at the bad byte) and then
  compiles it from its path, so the linker reads it again; the diagnostics
  (`file`, notes, help) are those of the Racket driver.

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
  bootstrap) prints them (§32.5). **Built in 8b:** `stdlib/MODULES` is the list
  (one path relative to `stdlib/` per line); `src/stdlib.rkt` reads it when it
  is compiled, and a test checks that it names every `stdlib/**/*.agc`.
  `vm/tools/gen-embedded.sh` writes `build/vm/<mode>/embedded.s` from it and
  from `build/stage/stage2.agcb`. The index holds only differences of labels
  inside one section, which the assembler turns into constants, so it needs no
  relocation (the layout is in `vm/embedded.h`). `make` compiles it with the
  VM's compiler and not through `ccache`, which cannot see the files that
  `.incbin` reads; a change of `stage2` or of a `stdlib/` file relinks the
  binary. Each `.incbin` has a comment with the SHA-256 of its file in the
  generated text, so a cache keyed on that text (the `zig cc` object cache)
  sees a changed front end. It is tried with gcc and clang here. `release.yml`
  builds it with the release toolchain (`zig cc`, glibc 2.28) by running `make
  fixed-point`, checks the glibc symbol versions and the static libraries, and
  runs `examples/hello.agc` and `examples/queue.agc` with it, without shipping
  it; step 8d ships it.
- **Linking.** As the release does today (the development skill's
  `references/ci.md`, "Release"): a pinned `zig cc` against glibc 2.28, checked
  with `objdump -T`, with Boehm GC, libuv, OpenSSL, yyjson and picohttpparser
  linked statically. glibc stays dynamic; a musl build stays separate (§18).
- **Size.** The VM is about 7 MB today. The front end adds an estimated 1 to 3
  MB, because an `.agcb` carries its source text. The target is under 12 MB,
  against 89 MB today. Measured in 8b on the dynamic development build: the
  embedded `stage2` is 3.2 MB and the 12 `std/` sources 0.17 MB, so
  `dist/agentica-next` is 4.2 MB against 0.78 MB for `agentica-vm`; the release
  link adds the static libraries to both, and the front end adds about 3.4 MB
  to the 7 MB of the VM.
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
  (ASan and GC stress). 8b wires the fixed point into the `test` job and into
  the ASan part of `vm-sanitizers` (about 75 s there, 1.8 GB of memory), where
  `vm-sanitize-test` then runs `tests/test_single_binary.py` on the sanitizer
  binary (the hand-off). The fixed point is a CI step and not a test, so it runs
  once. The GC-stress build is not run on it, because it collects every 64
  allocations. A
  stage0 refresh is its own PR; a VM change that needs one follows the two steps
  of 35.3.
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
- Differences from Racket. The message of the root file's own read error is
  the system's text, so it differs, and the golden comparison skips it. (A
  source file over 1 MiB, or with invalid UTF-8, is no longer a difference: see
  the item "Reading source files" of 35.4.) An unset `HOME` leaves the user
  library folder out of the `pkg/` search (Racket asks the system for the home
  folder). `Path.real` fails on a missing file where `normalize-path` accepts a
  missing last part, so the loader checks the folder first and a missing file is
  "cannot read import" at once, with the same code and span. For the same reason
  a symbolic link to a missing folder (a dangling link used as a folder part of
  an import) is "cannot read import" in Agentica where Racket says "cannot
  resolve import", again with the same code and span. The `HOME` user root is
  tested in the fast tier on the Agentica side only, because Racket's
  `find-system-path` ignores a replaced environment.
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
  `src/checker.rkt` (rows in functions of at most 55 lines, to stay under 60
  lines, joined by a chain of `rows = rows.concat(rows_N())` statements). It
  replaces `module_names.agc` and `tools/gen-module-names.rkt`. A fast test
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
  program of about 5.7 MB of source has more node ids.

Status on 2026-10-15 (PR #282): step 5 is done. `compiler/` also holds the
IR as data (`ir.agc`), the tables of `src/lower.rkt` (`lower_tables.agc`), the
state (`lower_state.agc`), expressions (`lower_expr.agc`), collections, enums
and structs (`lower_data.agc`), functions, blocks and statements
(`lower_stmt.agc`), the scan of what a function uses (`lower_scan.agc`), module
constants (`lower_const.agc`), the struct and enum tables (`lower_program.agc`),
and `lowering.agc` (`Lowering.lower(linked, checked, catalog)`:
`Lowered.Done(Program)` or `Failed(Problem)`), with the entry `lower.agc` and
`lower_text.agc` (3,000 lines of Agentica for the 1,100 of `src/lower.rkt`).
Notes:

- The text form is new, not `--dump-ir`. `--dump-ir` keeps only the start line
  and column of a span, leaves out the sources, the JSON field types of the
  structs and the file of each span, and prints a constant with Racket's `~s`;
  step 6 needs all of them to write the same bytes. The new form is
  `program SPAN entry=N globals=N`, one `source N "path" chars=N` for each file
  (the stored name of 35.4, "Source paths"), `struct sN "Name" ["f",...]` with
  ` types=[...]` when JSON can build it, `enum "Name" vN="Variant"/SIZE ...`,
  then each function as `fnN "name" params=P captures=C slots=S [entry] @ SPAN`
  followed by its labels (`  LN:`) and instructions
  (`    op ARGS @ SPAN ...`). A span is `FILE:LINE:COL-LINE:COL` with the index
  of its source, a register `rN`, a function `fnN`, a struct `sN`, a variant
  `vN`, a global `gN`, a label `LN`. A constant is `void`, `nil`, `true`,
  `false`, `int:N`, `float:bits:N` or a quoted string. A failure is the
  `ERROR` line with ` file="path"`. `tests/frontend-lower-common.rkt` prints it
  from `src/lower.rkt`.
- The IR is data: an `Instr` has an op name, integer arguments, an immediate
  for `const` and a builtin name for `call-builtin`, and a label is an `Instr`
  with the op `label`. A span has no file in `compiler/`, so each instruction
  carries the index of its file. Racket keeps the spans as objects.
- The function table is the one of `src/lower.rkt`: declared functions, the
  kept constants, `<start>` (when there are global slots), then the block
  functions in the order they are reserved (before their body is lowered, so a
  block gets a smaller index than the blocks inside it). The sources are listed
  in the order Racket first emits a span: the root, each function's module,
  then the modules of the kept constants.
- `LOWER-UNSUPPORTED` and `LOWER-INTERNAL` cannot be reached from a program
  that the checker accepts: every builtin implementation is in the VM list
  (`VM_BUILTINS` in `lower_tables.agc`; a test checks that it is the same set as
  `vm-builtins`), and a JSON target that cannot be decoded is
  `CHECK-NOT-DECODABLE`. The code paths stay, as in Racket, and no fixture ends
  in a `LOWER-` code.
- `Cx` (the declarations, the catalog and the types) holds two function fields,
  `expression` and `block`, because expressions, statements and blocks call one
  another and a module cannot import a module that imports it. `Fx` is the
  function being lowered (code, registers, labels, loop labels, the block
  functions made so far), threaded through the calls. The text of
  `check_text.problem_text` is now exported.
- Deep trees: lowering recurses on the tree, with at most 3 VM frames for each
  level (many calls are tail calls, so most shapes take 1 or 2): nested `if` and
  `while` 990 deep take about 3,000 frames, calls, method chains and `-x` about
  1,025, lists about 2,000, interpolations 2 for each level, a block about 4.
  The scans of constants and of the names a function reads are loops with a
  worklist. With `CHECK-TOO-DEEP` at 1,000 levels lowering uses about 3,000 of
  the 10,000 frames, and the checker (up to 5 frames for each level) is the
  bottleneck. The test starts the lowering 5,000 frames deeper (`--burn=5000`
  of `lower.agc`) on the deepest shapes and they still lower; with 8,000 the
  `if` chain overflows with `RUNTIME-STACK-OVERFLOW`, which shows that the burn
  works.
- The Agentica lowering matches the Racket one on the 26 fixtures, the
  examples, `tests/fixtures/vm/`, the `std/` modules and `compiler/` itself
  (the slow tier repeats all of them and the deep shapes). Same functions,
  registers, labels, spans, constants, structs and enums.

Status on 2026-10-15 (PR #286): step 6 is done. `compiler/` also holds the
bytecode writer: `bytecode_tables.agc` (the format version, the limits, the
Agentica version of the header and the opcode numbers), `bytecode_bytes.agc`
(little-endian integers, UTF-8 and the chunk lists), `bytecode_pool.agc` and
`bytecode_spans.agc` (the interned tables), `bytecode_types.agc` (the Types and
Decodable sections), `bytecode_function.agc` (one function),
`bytecode_failure.agc`, and `bytecode_writer.agc`
(`Writer.write(root_dir, program)`: `Written.Done(bytes)` or `Failed(Problem)`),
with the entry `bytecode.agc` (`FILE -o OUT` for each file; it prints
`wrote N bytes` or the `ERROR` line of lower.agc). About 800 lines of Agentica
for the 290 of `src/bytecode.rkt`. Notes:

- The test is byte equality. `tests/frontend-bytecode-test.rkt` makes the
  Racket bytes in its own process, runs the runner once over the fixtures and
  compares the files. The fast tier is the 26 lowering fixtures, `examples/`
  and `tests/fixtures/frontend/bytecode/` (UTF-8 text of 1 to 4 bytes, floats,
  a JSON field type 990 levels deep); it asserts that an instruction of every
  opcode and every section of the file appear, and that the constants hold all
  seven kinds. It also runs the Agentica `.agcb` and the Racket `.agcb` of two
  programs on the VM and compares what they print. The slow tier adds
  `tests/fixtures/vm/`, the `std/` modules, `compiler/` itself (the bootstrap
  check: the Agentica writer writes the compiler with the bytes Racket does),
  the deep shapes and a generated program. The two error fixtures of step 5
  (a check failure and an import failure) run the failure path of the runner:
  its `ERROR` line is the one of the lowering text form and no file is written.
- The limits and the `BYTECODE-INTERNAL` paths are tested on lowered programs
  that no source gives (`tests/fixtures/frontend/limits/limits.agc` builds 22
  of them for the Agentica writer, 4 of them in the slow tier because they
  write a million bytes or build 65,535 structs; the test builds the same for
  the Racket writer): the bytes or the code, the span, the file and the message of a limit
  must be equal. `BYTECODE-LIMIT` for nested List and Map levels in a JSON field
  type (1,024) cannot be reached from a source file, because the parser stops a
  type at 1,000 levels; the other limits (65,535 structs, enum variants, fields,
  payload items, constants, JSON field types, registers in a function, struct
  updates) need a program of tens of thousands of declarations or instructions.
  `BYTECODE-INTERNAL` cannot be reached from a lowered program; its message is
  the writer's own where Racket gives the text of its exception (the code and
  the span are the same).
- The file is built as a list of byte chunks that `Binary.concat` of
  `std/binary` joins once (`compiler/` imports a `std/` module for the first
  time). A small
  piece joins the last chunk, which costs O(piece) (`List.concat` with at most
  32 items on the right); a longer one, such as a source text, is a chunk. The
  tables of constants, struct updates, builtins and spans are filled while the
  functions are walked, because their entries are numbered in the order the code
  names them, so the writer encodes the functions first and puts the sections in
  file order after. A run of `step` is one instruction, cut at 65,535 as in
  Racket. The spans of a merged `step` keep the file of each one, which Racket
  gets from its span objects.
- No recursion over the program: the IR is flat, so the functions are `while`
  loops. Only the JSON field types recurse (`type_id`, `nesting`), with 1 VM
  frame for each level, and the writer stops them at 1,024 levels, so about
  1,040 of the 10,000 frames. Measured: starting the writer 8,950 frames deeper
  still writes the 1,024-level type, and 9,000 overflows with 995 frames of
  `type_id` on the stack.
- Speed (load average about 1.7): a generated program of
  1,500 functions (230,000 instructions, 8.2 MB of output) takes 17 s in the
  Agentica pipeline, 2.3 s of it lowering and 9 s the writer, against 10 s for
  the whole Racket `compile`. 6 s of the writer is the span table: one
  `Map[String, Int]` insert and lookup is about 9 µs at 275,000 entries; the
  final `Binary.concat` of the 8 MB is 1.1 s. The `.agcb` is a `List[Int]`,
  written in pieces of 1 MiB. For scale, `compiler/lower.agc` with everything it
  imports is 64,000 instructions.

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
  `tests/vm-stack-test.rkt` stayed because `make goldens` wrote its sidecars,
  and `tests/unit-test-test.rkt` because it called `run-agentica-test` of
  `src/bdd-driver.rkt` to set a test timeout that the CLI has no flag for; both
  moved in 8d-1 (below).
- **Phase 2:** the golden parts of the front-end tests move to `unittest`: the
  Agentica output compared with the goldens in `tests/fixtures/frontend/`. The
  live comparisons with the Racket stages stay in rackunit until phase 3. A file
  with both kinds is split, and each case keeps one framework.
- **Phase 3,** with step 8: 8c and 8d. Before 8d, every live comparison (corpus
  files, generated inputs, the large inputs of the slow tier) is frozen into a
  golden, so no coverage is lost. Generated inputs are checked in as fixture
  files or, when they are too big for that, a seeded stdlib script writes them
  and the golden records their SHA-256. Then 8d removes the rackunit files,
  every make target that only runs rackunit, and the CI steps that use those
  targets. Other `raco` calls stay until the deletion PR (`raco exe` for
  `dist/agentica`, `raco make`, `raco distribute`), because the build still uses
  Racket. The test suite no longer needs Racket. The fixed-point check of
  [§35.3](#353-bootstrap), stage2 and stage3 equal byte for byte, runs in CI
  from the committed `stage0`. The release cut after step 7b, which
  [§35.4](#354-stages-to-port) defines, is taken from the commit before this
  phase, so that release still has the rackunit live comparisons. The deletion
  of `src/*.rkt` and of the `raco distribute` steps follows the conditions of
  [§35.3](#353-bootstrap).
  **Status: 8c is done** (2026-10-15). Every live comparison is frozen under
  `tests/fixtures/frontend/frozen/` (`make frontend-freeze` writes it from the
  Racket stages while they exist) and `tests/test_frontend_<stage>.py` compares
  the Agentica stage with it: the fast cases are the fast-tier live
  comparisons, the rest are `@slow`. The corpus is a snapshot taken at the
  freeze, the inputs of the seeded Racket generators are checked in, and the
  inputs that are a formula (too big to check in) are rebuilt by the Python
  tests, which check the SHA-256 of each input. Agentica has no seeded random
  generator, so the scripts that write inputs are Python, standard library
  only. The rackunit files stay until 8d. Phase 2 is done too (PR #297, second
  part): the Agentica output against the goldens of
  `tests/fixtures/frontend/<stage>/` and the "every input has a golden" checks
  moved from the rackunit files to the same Python modules, and each moved case
  was removed from its rackunit file. The checks that read the Racket source
  are frozen as small lists under `frozen/` (the Unicode ranges, the `std/`
  registry, the checker tables, the `CHECK-` codes, the builtin rules,
  `VM_BUILTINS`, the opcodes, the `Rule` enum) and compared by Python. The
  accepted losses: the generated `compiler/builtins_data.agc` is not compared
  with a fresh generation (the catalog golden prints the same data), and the
  section fill of the bytecode corpus is read from the lowering goldens. After
  the Racket stages are gone, `tools/refreeze.py` rewrites the goldens from the
  Agentica stages and prints what changed. What 8d still removes: the
  rackunit files, whose remaining cases are the Racket printer against its
  goldens and the comparisons "while Racket exists".
  **Status: 8d-1 is done** (tests only, before the switch). The rackunit files
  that needed the Racket front end for a reason other than a live comparison now
  run the product CLI as a child (`tests.agentica_test.cli()`, so
  `AGENTICA_TEST_EXECUTABLE` picks `racket src/main.rkt`, `tests/agentica-agcb`
  or the single binary) and none of them imports Racket code:
  `tests/vm-diff-{1..8}-test.rkt` and the golden harness of
  `vm-diff-common.rkt` are `tests/test_vm_diff_{1..8}.py` over
  `tests/vm_diff_support.py` (`make goldens` and `make vm-golden-check` run it
  too; the goldens it writes are byte-identical to the checked-in ones);
  `vm-stack-test.rkt` is `tests/test_vm_stack.py`; `site-examples-test.rkt` is
  `tests/test_site_examples.py`; `stdlib-docs-test.rkt` is
  `tests/test_stdlib_docs.py`, which reads the doc lines from the source text;
  `unit-test-test.rkt` is `tests/test_unit_test.py`, where the hung-test case
  waits for the real 30 s deadline and is `@slow`;
  `stdlib-distribution-test.rkt` is `tests/test_stdlib_distribution.py`, which
  copies a built executable away from the checkout (`make test-distribution`);
  the cases of `modules-test.rkt` that run programs, and the `compile` exit-code
  case of `bytecode-test.rkt`, are `tests/test_modules.py` and
  `tests/test_vm_diff_8.py`; `cli-in-process.rkt` is gone. What is left in
  rackunit needs Racket on purpose: the stage tests (`lexer-test`, `parser-test`,
  `modules-test`, `checker-test`, `bytecode-test`, `diagnostic-test`), the live
  comparisons (`frontend-*`, frozen by 8c) and `vm-diff-common.rkt`, which is
  cut down to the three helpers the live comparisons use (the VM path,
  `compile-file` and `run-process`). The old byte comparison of the in-process `compile-file`
  with the CLI `compile` is dropped: `test_vm_diff_8.py` checks that the CLI
  gives the same bytes twice, and the front-end bytecode goldens compare the
  writers. `compile-file` itself stays in `vm-diff-common.rkt` for the live
  comparisons. 8d deletes these files with the rest.
