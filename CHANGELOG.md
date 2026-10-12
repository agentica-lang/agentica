# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `agentica-vm` traces its internals for VM developers:
  `AGENTICA_VM_TRACE=sched,io,proc,loader,gc` (or `all`) writes one
  `agc-trace` line per event (task spawns, turns and wakes, I/O jobs and
  `uv_run` waits, process spawns, exits, kills and signal watchers, loader
  table sizes and rejects, GC collections) to stderr, or to the file named
  by `AGENTICA_VM_TRACE_FILE`. Tracing never changes the exit code, stdout,
  or (with a file) stderr. `make vm TRACE=0` compiles the trace points out.

- The bytecode VM runs processes on Linux: every `Process` function, behind
  the VM's own `--allow-run` flag, which `agentica --vm` now passes through.
  Each call parks only its own task; reads and writes have their own locks;
  child stderr goes straight to the program's stderr. `Process.close`, the
  end of the run (also after `System.exit`, a runtime error or the step
  limit) and `SIGINT`, `SIGTERM` or `SIGHUP` to the VM or to `agentica --vm`
  kill and reap every running child. Children see only stdin, stdout and
  stderr. `examples/process-tool.agc` now runs on the VM.

- The bytecode VM runs tasks: `Task.spawn`, `Task.await` and `Task.sleep`
  on one scheduler with a FIFO run queue on the libuv loop. Tasks take
  turns of 2000 steps; long builtins and opcodes (`List.sort`,
  `String.join`, `JSON.encode`, string `+` and `==`, printing big values,
  String map keys) charge a turn-only cost, so a sleeping task or a stdin
  reader wakes within tens of milliseconds next to busy tasks, while step
  counts and `--max-steps` stay shared and unchanged. Stdin reads, file
  calls and sleeps park only their own task. Tasks that share a
  `FileHandle` take turns on it in order (a FIFO lock with a hand-off, and
  each waiter keeps its own timeout). Returning from `main` cancels
  pending tasks, and a failure or `System.exit` in any task ends the run.
  On the VM each task has its own `Random` generator, split from its
  parent at spawn. `make vm-latency` checks the wake latency (CI runs it
  after `make test`). `examples/concurrency.agc` now runs on the VM.

- License: Agentica is `Apache-2.0 WITH LLVM-exception` (`LICENSE`, `NOTICE`).
  Release archives include `LICENSE` and `NOTICE`, and Racket's licenses
  with Chez Scheme's `NOTICE` in `licenses/racket/`.

- The bytecode VM runs every `File`, `Dir` and `Path` builtin on Linux
  (`File.open`, `read_bytes`, `read_line`, `write`, `write_bytes`, `flush`,
  `close`, `read_text`, `write_text`, `append_text`, `stat`; `Dir.list`,
  `mkdir`; `Path.cwd`, `join`, `resolve`), with `FileHandle` values, the
  `FileInfo` record, timeouts, and the evaluator's error values, Racket
  messages included. `examples/file-summary.agc` now runs on the VM. Its
  blocking work runs on libuv (MIT), vendored as the git submodule
  `vm/third_party/libuv` at tag v1.53.0, built from source by the Makefile
  and linked statically; `agentica-vm --version` names it. A resource
  registry owns open handles and pending requests until libuv is done with
  them, thread-pool threads never touch GC memory, and descriptors are
  close-on-exec. Output is buffered 4096 bytes per handle, as Racket's
  file ports do. A job stuck in the OS (a read on a silent FIFO) does not
  hold the VM at exit. FIFOs and devices are not compared with the
  evaluator: with no peer the VM can give EOF or `ENXIO` where the
  evaluator times out, and four stuck calls fill libuv's thread pool so
  later file calls time out.

- The bytecode VM runs linked programs: relative, `std/` (such as
  `std/queue.agc`) and `pkg/` imports, linked by the front end into one
  bytecode file. A runtime error inside an imported file reports that
  file's path, line and column, as the evaluator does.
- The bytecode VM runs `JSON.decode` and `JSON.schema` for user structs,
  with the evaluator's error values and paths and byte-identical schemas
  (imported structs keep their linked `$defs` names). Deep and recursive
  values decode without C recursion. `examples/json-modules.agc` and
  `examples/mcp/stdio.agc` now run on the VM. The `.agcb` format is now
  version 3: a new Types section after Structs carries the JSON field
  types, and the loader validates it fully (indexes, counts, kinds, and
  cycles only through named structs, at most 1024 nested List and Map
  levels, unique names). A target that is a builtin record such as
  `Header`, or a struct with one in its fields, stays `LOWER-UNSUPPORTED`
  until 7h.

- The bytecode VM runs `Json` values and the `JSON` builtins that need no
  type table: `JSON.parse`, `encode`, `from`, `object`, `array`, `null`,
  `null?`, `get`, `at`, `string`, `int`, `float`, `bool` and `list`, with
  the evaluator's messages, key order, escapes and Float text. Integers
  outside 64 bits stay exact through parse and encode, and `JSON.float`
  converts them like the evaluator. Parsing uses the yyjson reader (MIT),
  vendored as the git submodule `vm/third_party/yyjson` at tag 0.13.0, so
  a VM build needs `git submodule update --init`.

- The bytecode VM runs the `Float`, `Time` and `Random` builtins:
  `Float.from_int`, `Float.to_int` and `to_int!` (also `n.to_f`,
  `x.to_i`, `x.to_i!`), `Time.now_ms`, `Time.monotonic_ms`,
  `Random.int` and `Random.float`, with the evaluator's errors and spans.
  The VM has its own generator (xoshiro256** seeded with splitmix64):
  `agentica --vm --seed N` (and `agentica-vm --seed N`) repeats its
  values, but they differ from the evaluator's for the same seed; without
  `--seed` the seed comes from OS entropy.

- The bytecode VM runs every `String` builtin: `length`, `upcase`,
  `downcase`, `trim`, `split`, `join`, `contains?`, `starts_with?`,
  `ends_with?`, `replace`, `slice`, `index_of`, `at`, `reverse`, `code`,
  `from_code`, `from_bytes`, `to_int`, `to_int!`, `to_float` and
  `to_float!`, with the evaluator's results, messages and spans. Lengths
  and indexes count code points; case mapping (special cases and final
  sigma) comes from tables generated from Racket; search, split and
  replace stay linear.

- The bytecode VM runs the `List` and `Map` library: `List.size`,
  `append`, `set`, `repeat`, `concat`, `take`, `drop`, `at`, `reverse` and
  `sort`, and `Map.has_key?`, `keys`, `values`, `size`, `put`, `get` (with
  and without a default) and `delete`, also as methods (`xs.size`,
  `m.keys`), with the evaluator's errors and spans. `Map.delete` removes
  the key from the HAMT and keeps the insertion order of the other keys.

- Ranges (Phase 8a): `a..b` includes `b`, `a...b` excludes it; both ends
  are `Int` and the value has the new builtin type `Range` (start, end and
  kind, no list inside). `for x in range` iterates without building a list
  and never overflows at the `Int` edges. `Range.size` (overflow at the
  receiver), `Range.to_a` (at most 1048576 values), `Range.include?`,
  `Range.each`, `Range.first` and `Range.last` (both `Result[Int]`), also
  as methods. `Int.times`, `Int.upto` and `Int.downto` take a block:
  `3.times do |i| ... end`. Each range `for` iteration and each callback
  call of `Range.each`, `times`, `upto` and `downto` costs one step, so
  `--max-steps` stops even an empty loop over a huge range. Ranges print
  as `1..5` / `1...5` and support `==`. Both the evaluator and the bytecode VM run them; the VM appends the
  `RANGE` and `RANGE_BOUNDS` opcodes (the `.agcb` format version does not
  change), and a `for` over a range literal allocates nothing.

- The bytecode VM runs function values: blocks (`do |x| ... end`) as
  closures that capture the values visible when they are made, `&name` of
  local and imported functions, `f.call(...)`, and `Fn` values in lists,
  maps and structs. `List.map`, `filter`, `reduce`, `each`, `any?`, `all?`
  and `sort_by` call their callbacks as resumable native frames, with the
  evaluator's step counts, call-depth limit, spans, early stops and stable
  `sort_by` order (NaN last). Closures for `Task.spawn`, HTTP and BDD stay
  unsupported on the VM. The `.agcb` format version does not change.
- The bytecode VM runs the `IO` and `System` builtins: `IO.inspect`,
  `gets`/`IO.gets` (EOF is an error value), `gets!`/`IO.gets!`
  (`RUNTIME-END-OF-INPUT` at the call span), `IO.read`, `IO.read_bytes`
  (0..1048576 bytes, else an error value), `IO.flush`, `IO.eof?`,
  `System.args` and `System.exit`, with the evaluator's line endings (LF,
  CR, CRLF), U+FFFD for invalid UTF-8 input and exit-code rules. Stdin is
  read with blocking reads through one buffered input layer; it moves to
  libuv with the scheduler. `agentica --vm` now passes stdin through when
  it is not a file stream.
- The bytecode VM runs `Map[K, V]` values: map literals (an empty one with
  a known type too; a repeated key keeps its first position and takes the
  last value), `m[key]` with `RUNTIME-KEY-NOT-FOUND` at the index span, and
  the `{k: v}` text and debug forms in insertion order, as on the
  evaluator. Maps are a persistent HAMT with SipHash-1-3 keyed per run. The
  `.agcb` format version does not change.
- The bytecode VM runs `Result[T]` values: `ok(x)`, `ok()`, `error(m)` (and
  `Result.Ok`/`Result.Err`), `Result.ok?`, `Result.unwrap!` (with
  `RUNTIME-UNWRAP-ERROR` at the call span), `Result.unwrap_or`,
  `Result.message`, `try` (an error returns from the current function),
  and `ok(v)`/`error(m)` patterns in `case`. Results print as `ok(v)`,
  `ok()` and `error("msg")`, as on the evaluator. The `.agcb` format
  version does not change.
- `agentica --vm file.agc [args...]` runs a program on the bytecode VM
  (tested on Linux only). It compiles to a temporary bytecode file (random
  name, mode 0600, in the system temp directory), runs `agentica-vm` from
  next to the executable (or `dist/` in a checkout; `AGENTICA_VM` overrides
  it), and passes `--max-steps`, `--ai`, `--json`, program arguments, the VM's stdout, stderr and exit code through. The
  evaluator stays the default. Options the VM does not support yet exit 2 with `--vm`.
- The bytecode VM has tail calls: `return f(...)` of a user function (local
  or imported, in any branch, `case` arm or loop body) replaces the current
  frame, so tail recursion and mutual recursion run at any depth there. Step
  counts and `--max-steps` behave as before. The evaluator has no tail
  calls, so a deep tail-recursive program still stops there with
  `RUNTIME-STACK-OVERFLOW`; this is a documented difference. Non-tail
  recursion keeps the 10000 call-depth limit on both. The `.agcb` format
  version does not change.
- The bytecode VM runs structs, enums and `case`: struct construction (fields
  in any order, evaluated as written), field access, generic and recursive
  enums, nullary variants with or without `()`, struct and enum values in
  locals, parameters, returns and lists, imported types, and `case` with
  literal, `_` and variant patterns (payload bindings and `_` discards).
  They print as `Name(f: v)` and `Enum.Variant(a)` through `puts`, `print`,
  `IO.warn`, interpolation, `to_s` and `inspect`, with the same names as the
  evaluator, and deep values print without C recursion. The `.agcb` format
  is now version 2: it carries the struct and enum tables.
- A documentation website in `site/`, built with Hugo and a small custom
  theme. It has its own user docs: Getting started, a Language tour in short
  pages, and one Library page per builtin module, each function with a small
  example and its output. `docs/grammar.md` is published as the language
  specification. `tests/site-examples-test.rkt` checks and runs every
  example on the site and compares its output.
  `make site` builds it, `make site-serve` serves it, and
  `.github/workflows/pages.yml` deploys it to GitHub Pages from `master`.
- A CI workflow, run by hand, fuzzes the VM loader and interpreter with 5 million
  mutants and a random `FUZZ_SEED`, and uploads the crashing input on failure.
- The bytecode VM runs List code: `List[T]` of Int, Float, Bool, Nil, String
  and nested lists in locals, parameters and returns, list literals (long
  ones are built in chunks of 255), `for x in xs` with `break` and `next`,
  indexing `xs[i]` with `RUNTIME-INDEX-OUT-OF-RANGE` at the index, and the
  `[a, b]` text through `puts`, `print`, `IO.warn`, interpolation, `to_s`
  and `inspect`. Deeply nested lists print without C recursion.
- The bytecode VM builds and passes its tests on macOS and on Windows
  (MSYS2 UCRT64 gcc, `dist/agentica-vm.exe`); CI runs both. On Windows the
  VM takes its arguments as UTF-16 (`wmain`) and opens the input file with
  `_wopen`, so non-ASCII file paths load, and writes all three streams in binary mode. Git checks out text files with LF
  on every platform (`.gitattributes`).
- The bytecode VM runs String code: String values in locals, parameters and
  returns, `+`, `==` and `!=`, interpolation, `x.to_s` and `x.inspect` of
  Int, Float, Bool, Nil and String (the debug form is Racket's `write`,
  from data generated by `vm/gen-unicode.rkt`), and `IO.warn`. Runtime
  diagnostics also come in the `--ai` and `--json` formats
  (`agentica-vm --ai|--json`), and `make vm-gc-stress` runs the
  differential tests on a build that collects every 64 allocations.
- The bytecode VM runs Float and Nil code: Float literals, `+ - * /`, unary
  minus and comparisons with the evaluator's IEEE behavior (NaN, infinities,
  `-0.0`, division by `0.0` and `-0.0`), `nil` and `==`/`!=` on Nil, and
  `puts`/`print` of Float, Bool and Nil with the evaluator's Float text.
- First slice of the bytecode VM (`docs/vm.md`): `agentica compile file.agc
  -o file.agcb` and `--dump-ir`, and `dist/agentica-vm` (`make vm`), a C11
  VM with the Boehm GC (vendored as a pinned submodule) that runs Int and
  Bool code, `if`/`while`/`break`/`next`, functions, calls, `return` and
  `puts` with the same output, steps, limits and plain diagnostics as the
  evaluator. Programs outside that subset get `LOWER-UNSUPPORTED`.
- `x.inspect` on every data value: the `IO.inspect` text as a `String`, as
  in Ruby. A bare `inspect(x)` gets a hint toward `x.inspect`.
- `to_s` on every data value (Bool, nil, lists, maps, Results, structs,
  enums, Json), giving the same text as interpolation; `Json` gives its JSON
  text.
- `break` and `next` in `while` and `for` loops, each alone on its line;
  outside a loop or across a block they are `CHECK-LOOP-CONTROL`.
- `Result.Ok(x)` / `Result.Err(m)` as values and `ok(v)` / `error(m)` as
  `case` patterns, so both spellings work in both places.
- A nullary enum variant without parentheses: `Command.Show`, `M.Shape.Dot`.
- Top-level `print`, `gets` and `gets!` (`gets`/`gets!` may drop their
  parentheses), like Ruby's.
- Ruby forms seen in evaluations: an optional `do` after `case`, `while` and
  `for` headers; a one-line case arm (`1 -> puts("one")`); module functions
  without arguments, builtin or through an import alias, may drop the
  parentheses (`IO.gets!`, `IO.eof?`).
- Hints for `let`/`var`/`const`, `match`, `when`, `then`, `fn`/`lambda`, a
  `do` block with no call, `loop do`, `if x do`, trailing `if`/`while`
  modifiers, `Module.fn arg`, `Hash.new`/`Array.new`, `break`/`continue`/`next`
  (also `break if x`), `Result.Ok(x)` used as a value, and an enum variant
  without parentheses.
- Hints for habits from other languages: `len`, `str`, `print`, `input`,
  `range`, `int`/`float`, `None`/`null`, `elif`/`else if`, Python-style
  string methods, and a `Result[T]` used where `T` is expected.
- Blocks and closures: `xs.map do |x| x * 2 end` as the last argument of a
  call, capturing values when created; usable anywhere a `Fn` is, including
  `Task.spawn`, HTTP callbacks and `BDD.step`. New diagnostics
  `CHECK-BLOCK-TYPE`, `CHECK-BLOCK-TARGET` and `CHECK-CAPTURED-ASSIGNMENT`.
- `List.each`, `List.any?` and `List.all?`.
- String interpolation: `"total: #{n + 1}"`, with `\#` for a literal `#`.
- Methods on builtin values (`s.strip.size`, `xs.push(1)`, `r.ok?`), resolved
  by type to module functions, with Ruby aliases (`to_i`, `to_s`, `size`,
  `strip`, `include?`, `push`, `join`).
- `tests/eval/diagnostics.py` summarizes the diagnostics agents saw in
  evaluation runs.
- `!`, `&&` and `||` as spellings of `not`, `and` and `or`, and compound
  assignment `+=`, `-=`, `*=`, `/=`, `%=`.
- Embedded Agentica standard library with an immutable String FIFO at
  `std/queue.agc`; executable releases need no separate stdlib installation.
- `pkg/` imports with project-local, `AGENTICA_PATH`, user-data, and system
  library roots, deterministic precedence and path-containment checks.
- `List.sort` and `List.sort_by`: stable ascending sorts over `Int`, `Float`
  and `String` values or keys.
- `String.index_of`, `String.at`, `String.reverse`, `String.code`,
  `String.from_code`, `Float.from_int`, `Float.to_int` and `Float.to_int!`.
- `Time.now_ms`, `Time.monotonic_ms`, `Random.int` and `Random.float`, with
  `--seed N` for repeatable runs, also passed through `agentica test`.

### Changed

- Programs run on the bytecode VM by default: `agentica file.agc` compiles
  in-process and runs `agentica-vm` with `--max-steps`, `--seed`,
  `--allow-run`, `--ai`, `--json` and the program arguments. A program that
  uses `TCP`, `TLS`, `HTTP` or `BDD` runs on the legacy Racket evaluator
  after one notice line on stderr, none with `--json` (`agentica: the VM
  does not support the builtin HTTP.get yet; running on the legacy
  evaluator`); `agentica test` and the programs it drives stay on the
  evaluator until BDD runs on the VM.
  `--vm` is accepted and does nothing. A missing VM exits 2 with
  `agentica: cannot find the VM at PATH`. Seeded `Random` values differ from
  the evaluator's, each task has its own generator, and deep tail calls no
  longer overflow. The evaluator is frozen and will be deleted (roadmap 7i).
- `make test` and `make exe` build the VM first. The VM differential tests
  are golden tests now: each fixture in `tests/fixtures/vm/` has a
  `<name>.expected`, and `make goldens` rewrites them from the VM.
- The Linux release archive ships `agentica-vm` in `bin/` next to
  `agentica`, built against glibc 2.28, with the licenses of bdwgc, libuv,
  yyjson and the Unicode data in `licenses/`.

- `Process.spawn` looks up a bare command name (no `/`) in `PATH` and never
  adds the current directory (empty entries are skipped; an explicit `.`
  entry still works, as in the shell); a name with `/` is a path relative
  to the working directory (`grammar.md`, Processes). On the VM, a file
  that is found but cannot be executed is an error `Result` from `spawn`.
- `agentica --vm` now stops the VM with `SIGTERM` (then `SIGKILL` after 2
  seconds) when it is interrupted, and the VM's parent-death signal is
  `SIGTERM`, so the VM can kill its children first.
- Breaking: `Range` is now a reserved type and module name. A user
  `struct Range`, `enum Range` or `import ... as Range` is
  `CHECK-REDEFINED-NAME`; rename it.

- `String.split` keeps every empty part. Before, it dropped empty parts at
  the ends (`"a\n".split("\n")` gave `["a"]`) but kept them in the middle;
  now it gives `["a", ""]`, and `join` after `split` gives back the text.
- `vm/gen-unicode.rkt` moved to `vm/tools/gen-unicode.rkt`; `make vm-unicode`
  runs it from there and writes the same `vm/unicode_data.c`.
- CI runs its checks on pull requests only, and only on Linux; pull
  requests that change only docs, the site or Markdown skip it. A push to
  `master` runs no checks: it only warms the compiled Racket files cache and
  the `vm/unicode_data.c` check cache, so new pull requests start warm.
  Compiled Racket files are cached per job; `vm-sanitizers` and the site
  examples job fall back to the `test` job's cache. The macOS and Windows VM jobs moved to
  `.github/workflows/platforms.yml` and the fuzz workflow no longer runs
  weekly; both run by hand. The site is built only on `master`, by the
  Pages workflow. The Linux workflows run on a self-hosted runner.
- libgc is built with `NO_EXECUTE_PERMISSION` and `ALL_INTERIOR_POINTERS`,
  as its own build systems do: the heap is no longer writable and
  executable (macOS on arm64 refuses such pages), and interior pointers
  stored in GC objects and static data also count.
- `puts`, `print`, `IO.puts`, `IO.print` and `IO.warn` take any value with `to_s`, as
  in Ruby. Functions, tasks and resource handles have no `to_s`; printing or
  interpolating one is `CHECK-TYPE-MISMATCH`.
- Interpolating a `Json` value inserts its JSON text instead of `<Json>`.
- `IO.inspect` and interpolation show enum values as `Shape.Box(1, 2)`
  instead of a host struct.
- Docs: `case x` without `do` is the taught form (the `do` stays optional);
  BDD and enum diagnostic codes are documented; the README, roadmap,
  development skill and AGENTS.md match the current code. The `input`/
  `read_line` hints suggest `gets`.
- `print`, `gets` and `gets!` are reserved builtin names; a user function
  with one of these names no longer checks.
- The programming skill is split for token efficiency: the core language is in
  `SKILL.md`, and builtins, modules, JSON, files, processes, tasks, network,
  BDD, diagnostics and examples are separate references read on demand
  (`references/language.md` is gone).
- The programming skill and the `inventory`, `strings` and `result` examples
  teach the Ruby forms (methods, `!`/`&&`, `+=`, interpolation, blocks).
- A declaration's `end` must be followed by a blank line before the next
  declaration (`PARSE-MISSING-BLANK-LINE`).
- `#{` inside a string now starts an interpolation; write `\#{` for the
  old literal text.
- Ignoring the result of a builtin without effects is `CHECK-UNUSED-VALUE`.
- Field access on a non-struct value is a method call; unknown names are
  `CHECK-UNKNOWN-METHOD` (replaces `CHECK-NOT-A-STRUCT`).
- The Int/Float type-mismatch help now suggests `Float.from_int` and
  `Float.to_int!`.
- `Time` and `Random` are reserved builtin module names; declarations or
  import aliases with those names no longer check.

### Fixed

- `agentica-vm` started with stdin, stdout or stderr closed (`2>&-`) no
  longer aborts on a libuv assertion: on Linux it first fills the closed
  descriptor with `/dev/null` opened the other way round, so reads and
  writes on it still fail as before (a program that prints with stdout
  closed still ends with `RUNTIME-INTERNAL`).

- A file handle closed by a timeout no longer holds its lock in the
  evaluator: later operations give `filesystem: file handle is closed` at
  once and `File.close` gives `ok()`, instead of each waiting for its own
  timeout.
- The bytecode VM no longer does pointer arithmetic on a NULL buffer when
  `IO.read` reads an empty stdin (`agc_input_all`).
- A struct or enum declared in an imported module prints its declared name
  (`Point(x: 2)`, `Shape.Empty`) instead of the linker's internal
  `@2::Point` on both the evaluator and the VM, through `puts`,
  `IO.print`, `IO.warn`, interpolation, `to_s` and `inspect`, also nested
  in lists, maps, results and enum payloads. Checker messages (unknown
  types, type mismatches, unknown or missing fields, enum variants, arity
  and missing-return signatures) name imported types and functions the
  same way. Did-you-mean suggests only names of the same module (and
  builtins), by their declared names. Types with the same name from
  different modules print the same; `JSON.schema` keeps unique internal
  `$defs` keys.

### Security

- `Process.spawn` on Windows runs only `.exe` and `.com` programs
  (any case). Anything else is refused: `.bat`, `.cmd`, `.ps1`, no
  extension, names ending in a dot or space (`x.exe.`, `x.com `), and
  stream names (`x.bat::$DATA`). Before, only lowercase `.bat` and `.cmd`
  were refused, so `x.BAT` or `x.bat.` ran through `cmd.exe` and reopened
  argument injection (BatBadBut, CVE-2024-24576). The check uses the
  resolved path.

## [0.1.0] - 2026-10-04

First tagged release of the Agentica interpreter: a small statically typed
language, written in Racket, designed so an AI agent can write, run, and repair
programs from stable diagnostics.

### Added

- **Pipeline and CLI.** Lexer, parser, checker, and evaluator as separate
  modules, driven by `agentica`. Run a program, `check` it without running,
  `--dump` the checked tree, and query a builtin with
  `agentica help NAME --json`. Exit codes: `0` ran, `1` a diagnostic, `2` bad
  usage or an unreadable file.
- **Language core.** `Int`, `Float`, `Bool`, `String`, `Void`, and `Nil`;
  `List[T]`, `Map[K, V]`, `Result[T]`, and `Json`; structs with named fields;
  functions with `Fn[A, ..., R]` values; `if`/`elsif`/`else`, `while`, and
  `for`; full operator precedence; block scopes with a no-shadowing rule; and
  return analysis that requires every reachable path to return.
- **Builtin modules.** `String`, `List`, `Map`, `Result`, `IO`, `System`,
  `File`, `Dir`, `Path`, `JSON`, `TCP`, `TLS`, `HTTP`, `Process`, `Task`, and
  `BDD`, documented from one shared catalog that also types and executes them.
- **Typed JSON.** Decode JSON into declared structs and type expressions,
  encode structs, maps, and lists, extract values with located-path `Result`
  errors, build dynamic documents, and generate JSON schemas.
- **Result and propagation.** `ok`/`error`, the `Result` module, and `try`,
  which unwraps a success or returns the error from the enclosing
  `Result`-returning function.
- **File modules and imports.** Relative `.agc` imports with uppercase aliases,
  explicit `export`, private unexported names, canonical-path deduplication,
  and cycle rejection. Imported declarations share one evaluation, budget, and
  resource ownership.
- **Diagnostics for agents.** Stable stage-prefixed codes (`LEX-`, `PARSE-`,
  `CHECK-`, `RUNTIME-`), file/line/column, a source excerpt with a caret,
  secondary labels, and grounded `= help:` suggestions. `--ai` and `--json`
  print the same diagnostic as compact text or one JSON object.
- **Execution budget.** `--max-steps N` bounds expression and statement
  entries, including loop conditions; exhaustion is `RUNTIME-STEP-LIMIT`.
- **Concurrency.** Lightweight `Task.spawn`/`Task.await`/`Task.sleep` with
  supervision, cached results, cancellation, and a shared step budget.
- **Networking.** TCP, TLS, and a streaming HTTP/1.1 client and server, with
  bounded framing, connection pooling, trailers, and no transparent retries.
- **Processes.** `Process.spawn` and streamed stdin/stdout/stderr behind
  `--allow-run`, with timeouts, 1 MiB per-call bounds, and cleanup on every
  evaluation outcome.
- **BDD.** Gherkin `.feature` specs with typed Agentica step handlers, JSON
  scenario state, and supervised programs under test.
- **Files and paths.** Streamed and whole-file text/byte I/O, metadata,
  recursive `Dir.mkdir`, sorted `Dir.list`, and lexical `Path` helpers.
- **Examples.** `hello`, `classify`, `tasks`, `inventory`, `strings`, `echo`,
  `result`, `json`, `json-config`, `json-expenses`, `json-lines`,
  `knight-tour`, `traveling-salesman`, `maze-bfs`, `dispatch`, `concurrency`,
  `http_get`, `http_server`, `tcp_echo`, `process-tool`, and `json-modules`.
- **Agent tooling.** The `agentica-programming` skill (self-contained language
  reference for writing `.agc` programs), the `agentica-development` skill for
  changing the interpreter, and a Docker/Firejail evaluation harness under
  `tests/eval/`.
- **Release tooling.** `agentica --version`, a `make version` target, and a
  release workflow that builds a distributed executable and publishes a GitHub
  Release when a version tag is pushed.

### Changed

- Diagnostics name the operator token for unary and binary errors, and report
  internal checker states as `CHECK-INTERNAL`.
- `main()` returns `Void`; `nil` remains data and JSON null.
- Maps keep insertion order with immutable hashes; `Map.get/2` returns a
  `Result` and `Map.get/3` an eagerly evaluated default.

[unreleased]: https://github.com/sonic182/agentica/compare/0.1.0...HEAD
[0.1.0]: https://github.com/sonic182/agentica/releases/tag/0.1.0
