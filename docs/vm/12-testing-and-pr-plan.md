## 12. Testing and first PRs

### 12.1 Tests

- 7c `tests/lower-test.rkt`: one test per form (ops, slots, captures, spans).
  7d `tests/bytecode-test.rkt`: write, read back, compare; every example
  compiles. In the slice there is no Racket reader: the C loader is the
  only reader, and every differential test sends writer output through it.
  `tests/bytecode-test.rkt` checks step merging, that the opcode list matches
  `vm/agc.h`, that an out-of-subset program gets `LOWER-UNSUPPORTED`, and the
  `compile` exit codes; `tests/lower-test.rkt` comes with the wider lowering.
- `tests/vm-diff-*-test.rkt` (from the first VM PR, completed in 7f; four
  shards of `tests/vm-diff-common.rkt`) run each
  program on the evaluator in-process (as `tests/examples-test.rkt` does,
  formatting with `src/diagnostic.rkt`) and on `dist/agentica-vm` with
  `--json`, and compare exit code, stdout, the program's own stderr and
  the diagnostic code (black-box parity, 1). With `--json` the diagnostic
  is the last stderr line: it is parsed as JSON for the code and removed
  before stderr is compared. Each fixture also runs once on the VM in the
  plain and `--ai` formats: exit code and stdout must equal the full run's,
  stderr must start with the full run's program stderr, and the rest must
  name the same code (`error[CODE]` or an `[CODE]` line) or be empty when
  there is no diagnostic. Inputs: `examples/`, `tests/eval/tasks/*` reference
  solutions and hidden cases, and `tests/fixtures/vm/` with one program per
  runtime code and error span.
- Every program also runs on the VM under a sweep of `--max-steps`
  limits. The test finds each program's total step count T with the
  evaluator and sweeps every limit from 1 to T when T is at most 2000;
  above that (the call-depth program, about 60,000 steps) it sweeps 1 to
  300, 50 evenly spaced limits, T - 1 and T; then it adds the larger of
  2T + 100 and T + 4000 (two turns of `AGC_TURN_STEPS`, so a task fixture
  does not depend on when Racket first preempts a thread). For
  each limit the VM must either give the full run's outcome, or stop with
  exit 1 and `RUNTIME-STEP-LIMIT` with a stdout and stderr that are
  prefixes of the evaluator's full run. Once the VM finishes at one limit
  it must finish at every larger one, and it must finish at that last limit. The
  evaluator runs once per program, not once per limit. This allows other
  step counts and spans but catches a wrong code, extra output, and
  over-charging (not finishing by the last limit). It cannot catch an ignored
  limit, since these programs finish anyway: the runaway programs in
  `tests/fixtures/vm/step-limited/` do (`while true`, non-tail recursion,
  a self tail call, mutual tail calls, a `while true` whose body is only dead
  code, a `while` inside a `List.each` block, a loop inside a
  closure called through a function value, and the counting builtins).
  Each must stop with exit 1 and `RUNTIME-STEP-LIMIT` on both backends at
  every tested limit, their stdouts and program stderrs must be prefixes
  of one another, and neither may print what follows the loop. On Linux every
  VM run in the sweep and the runaway test has a 60-second timeout
  (`timeout --foreground -k 5 60` in the batch script, so the VM stays in
  the batch's process group; `#:timeout` in `run-process`), so a VM that
  ignores the limit fails with the fixture and limit named instead of
  hanging. After the first run in a batch that times out (status 124 or
  137) the script skips the rest and records them as 124 with empty
  output, so a hanging VM costs one timeout per fixture, not one per
  limit. The inputs are
  `tests/fixtures/vm/` only. This covers 2.1 and 4.4, so the IR needs no
  step test. `Random` fixtures print only what both backends share, since
  seeded sequences differ by design (7.4).
- Corpora: Float text has a fixed table in `vm/tests/float_text_test.c`
  (values picked from a 708k-value comparison with Racket, 2.2) and the
  `tests/fixtures/vm/float-text.agc` differential fixture. Write escapes
  are checked where the data is made: `vm/tools/gen-unicode.rkt` compares its C
  rule with Racket's `write` for every code point and the joiner contexts
  (2.3) and refuses to generate otherwise. On the C side,
  `vm/tests/text_test.c` checks the range lookup at every range edge, a few
  debug forms, and that the debug form of every adjacent pair of scalar
  values is valid UTF-8 with an exact character count; the
  `string-inspect` fixture compares with the evaluator. Split, trim and
  case mapping join with the `String` library. `make vm-test` builds every
  `vm/tests/<name>_test.c` listed in `VM_TESTS`.
- Extreme Int corpus under UBSan: `INT64_MIN`, -1, 0, n, n+1, `INT64_MAX` for
  every Int parameter of every builtin. Deep-value corpus: a depth-1,000,000
  enum chain and nested JSON array, printed and encoded
  (`vm/tests/json_test.c` parses and encodes depth-1,000,000 arrays and
  objects). A program's lists
  are only as deep as their types, which are written in the source (there
  are no user generics), whether built by one literal (capped near 65,000
  levels by registers, 3.5) or by chained bindings, so
  `vm/tests/text_test.c` builds a depth-1,000,000 list in C and prints it,
  and a depth-1,000,000 chain of enum payloads wrapped in structs: enough to
  overflow an 8 MB C stack even at about 48 bytes per frame, so a recursive
  printer would crash. The GC stress build uses depth 1,000 for both, since
  there the test is about GC safety while printing, not depth; the
  printer walks lists, structs and enums with one explicit `agc_alloc`'d
  stack (7.3). Recursive enums can be built to any depth in a loop; the
  `enums-case` fixture builds one and walks it with `case`.
- File programs (7h) are hermetic: a fixture whose `.args` holds `@tmp`
  gets a new empty directory under the shard's work directory for every
  run, evaluator and VM alike (directory names have the same length, so
  cut forms match), the argument is replaced by its path, the path is
  replaced back by `@tmp` in stdout and stderr before the comparison, and
  the directory is deleted afterwards. The fixtures use long timeouts, so
  a loaded machine does not turn a slow write into a timeout.
- Tasks, processes and network programs join in 7h, with the independent
  counterparts the current tests use.

### 12.2 PR plan

Each PR keeps its own tests and docs and ticks its roadmap items.

1. **Vertical slice** (done). `#:types` in the checker; `src/lower.rkt`,
   `src/bytecode.rkt` and `vm/` for Int, Bool, their operators (including
   `and`/`or`, comparisons and every Int rule of 2.2), `if`, `while`,
   `break`/`next`, functions, calls, returns, steps and `puts` of plain
   strings and Ints; the loader with full validation and the fuzz driver;
   `--dump-ir`, `agentica compile`; `make vm`, the Linux and sanitizer CI
   jobs, the VM differential test (now `tests/vm-diff-*-test.rkt`).
2. **Float** (done). Float ops, comparisons and Float text (2.2), Nil, and
   `puts`/`print` of Float, Bool and Nil.
3. **Strings and printing** (done). Strings, interpolation, debug forms, the
   write-escape generator, the three diagnostic formats, exit codes, the GC
   stress run.
4. **macOS and Windows CI** (done). `make vm vm-test` and the differential
   and bytecode tests on `macos-15` and `windows-2025` (MSYS2 UCRT64 gcc),
   `wmain` with UTF-8 arguments, binary stdio, LF checkouts, and libgc built
   with upstream's defines (no executable heap pages).
5. **Data.** Too big for one review, so it lands as five PRs:
   - **5a Lists** (done). `List[T]` values, list literals (chunked above
     255 elements, 3.3), `for x in xs`, indexing `xs[i]` with
     `RUNTIME-INDEX-OUT-OF-RANGE` at the index span, and the text and debug
     forms `[a, b]` for every value type the VM has, through `puts`,
     interpolation, `to_s` and `inspect`. The checker rejects `==` on lists,
     so there is no list equality. List library functions stay in item 6b.
   - **5b Structs, enums, `case`** (done). User structs and enums (generic
     and recursive too, imported ones with their declared display names),
     construction, field access, `case` with literal, `_` and variant
     patterns, their text and debug forms, and format version 2 with the
     struct and enum tables. The checker rejects `==` on them, so
     there is no struct or enum equality. Result patterns stay in 5c.
   - **5c Result values, `try`** (done). `Result[T]` values, `ok(...)`,
     `ok()` and `error(...)`, the `Result.*` builtins (`ok?`, `unwrap!`
     with `RUNTIME-UNWRAP-ERROR` at the call span, `unwrap_or`,
     `message`), `try` (`TRY`), Result patterns in `case` (`IS_OK`,
     `RESULT_VALUE`), and the text and debug forms `ok(v)`, `ok()` and
     `error("msg")`. No format bump: the three opcodes are appended.
   - **5d Maps** (done). `Map[K, V]` values as a persistent HAMT plus
     the evaluator's reversed key list (5.1), map literals (empty typed
     ones too; above 255 entries extended with `Map.put`, 3.3), `m[key]`
     with `RUNTIME-KEY-NOT-FOUND` at the index span, and the `{k: v}` text
     and debug forms in insertion order. `vm/tests/map_test.c` checks
     20,000 keys, order, replacement, persistence, full 64-bit hash
     collisions, keys that share 60 hash bits, and a depth-1,000,000
     nested map printed. No format bump: `MAP` and `MAP_GET` are appended.
     There is no `for` over a map (the checker rejects it); Map library
     functions stay in item 6b.
   - **5e Closures** (done). Blocks (`block-lit`) as closures with
     snapshot captures (3.4), `&name` of local and imported functions,
     `.call` (`CALL_VALUE`, `CLOSURE`), `Fn` values in lists, maps and
     structs, and the resumable `List` builtins (`map`, `filter`,
     `reduce`, `sort_by`, `each`, `any?`, `all?`) as native frames
     (4.3). No format bump: the function table always had its captures
     field, and the two opcodes are appended. Closures passed to
     `Task.spawn`, HTTP or BDD stay `LOWER-UNSUPPORTED` until 7h.
6. **Library.** Two PRs:
   - **6a IO and System** (done). Blocking stdio; it moves to libuv
     resumable builtins with the scheduler (7h). `IO.inspect`, `IO.gets`
     (and `gets`), `IO.gets!` (and `gets!`, `RUNTIME-END-OF-INPUT` at the
     call span), `IO.read`, `IO.read_bytes` (0..1 MiB, else an error
     value), `IO.flush`, `IO.eof?`, `System.args` and `System.exit`, all
     through the input layer of 7.3. `agentica --vm` now passes a non-file
     stdin through. Fixtures with a `.stdin` and an `.args` file next to
     them feed the differential test.
   - **6b** `String`, `List`, `Map`, `Float`, `Time`, `Random` (done; `Random` with
     its own seeded generator, 7.4). `List` and `Map` are done: plain C builtins (no native
     frames), the evaluator's messages and spans (`RUNTIME-INDEX-OUT-OF-RANGE`
     for `at`/`set`, `RUNTIME-INVALID-COUNT` for `take`/`drop` and
     `repeat`, at the argument span), `Map.get` as a Result with the
     key's debug form in the message, and `List.sort` through the same
     merge sort as `sort_by` with the items as their own keys. Lists stay
     arrays, so `append` and `set` copy (O(n)); `repeat`, `concat`,
     `take`, `drop` and `reverse` are one pass, and `repeat` is capped at
     1048576 before allocating. `vm/tests/map_test.c` covers `delete`
     (persistence, order, collision nodes, shared prefixes, deleting to
     empty); the `list-library`, `map-library` and `list-*` error
     fixtures cover the rest. The `String` part is done too: every
     `String.*` builtin of the catalog in `vm/strings.c` (2.3), the case
     and final-sigma tables in `vm/unicode_data.c`,
     `vm/tests/string_test.c` (UTF-8 helpers, search, case, number
     parsing edge cases) and the `string-*` fixtures (non-ASCII text,
     empty strings, every runtime code and span).
     `Float`, `Time` and `Random` are done too
     (`vm/numbers.c`, its own builtin table): `Float.to_int` fails at
     the call with `RUNTIME-INVALID-NUMBER` (`cannot convert +nan.0 to
     Int`, `+inf.0`, `-inf.0`) or `RUNTIME-INTEGER-OVERFLOW`, as an error
     value without `!`; `Time.now_ms` is `timespec_get` and
     `monotonic_ms` `CLOCK_MONOTONIC` (`QueryPerformanceCounter` on
     Windows), both floored to milliseconds; `Random` is the VM's own
     xoshiro256** generator of 7.4, and `agentica --vm` passes `--seed`. Fixtures:
     `float-convert`, `float-to-int-*`, `time` (shape only),
     `random` (black-box) and `random-invalid-range`.
7. **JSON.** Parse, extract, encode, builders, typed decode, schema.
   The VM Json tree, with its big-integer node from §5, must follow the number rules of `docs/future/15-adapters-and-json-inspection.md` §15.2.
   Two PRs:
   - **Part 1** (done). `JSON.parse` over the yyjson reader (2.6, 10),
     the extractors (`get`, `at`, `string`, `int`, `float`, `bool`,
     `list`, `null?`), `JSON.encode` and the builders (`from`, `object`,
     `array`, `null`) in `vm/json.c`, the `Json` value (5.1) with its text
     and debug forms, and `Json` in `vm-type?`. No format bump.
     `vm/tests/json_test.c` checks the sign of zero,
     escapes, key order and dedupe on 5,000 keys, and depth-1,000,000
     arrays and objects parsed and encoded (and a list as deep through
     `JSON.from`; 100,000 under ASan, 1,000 under GC stress); the `json-*` fixtures cover round trips, every parse
     message, the number fixtures of docs/future/15-adapters-and-json-inspection.md §15.2, the builders,
     extract errors, `RUNTIME-JSON-ENCODE` from `encode` and `from`,
     `RUNTIME-UNWRAP-ERROR` on a missing key, and a 1,024-deep array and
     object (kept small for the GC stress and sanitizer runs; the C test is
     the deep guard).
   - **Part 2** (done). `JSON.decode` and `JSON.schema` (2.7) in
     `vm/json_typed.c`, with the Types section and format version 3 (4.6)
     and its loader rules (8). The type argument lowers to the struct's
     linked name (3.3). Fixtures: `json-decode` (nested, recursive, list
     and map fields, imported structs, big integers to Float, a round
     trip), `json-decode-errors` (every error kind with its path, and the
     parse errors), `json-schema` (several structs, recursion through
     lists and maps, an imported struct beside a local one of the same
     name) and `json-decode-deep` (a 1,000-level recursive value and a
     path error at the bottom).

8. **7h part 1: event loop and files** (done, Linux). libuv v1.53.0 as a
   submodule built by the Makefile, the resource registry and the one-task
   loop of 10.2.2, and every `File`, `Dir` and `Path` builtin with
   `FileHandle` and `FileInfo` (2.8). `agentica-vm --version` names libuv.
   The `files-*` fixtures run each backend in its own temporary directory
   (an `.args` entry `@tmp`, 12.1), and `vm/tests/loop_test.c` checks the
   registry, a completed job, a timed-out job that is dropped later, and
   closing the loop. `examples/file-summary.agc` runs on the VM.

Phase 8a (ranges, done) added the `Range` value (5.1), `RANGE` and
`RANGE_BOUNDS` (4.2), the counter loops of 3.3, the `Range` builtins and
the counting native frames of 4.3, with loader rules (8) and the `ranges`,
`range-size-overflow`, `range-to-a-count` and `times-callback-error`
fixtures.

Outside this list, the **tail-call** PR (done) added `TAIL_CALL`: a
`return f(...)` of a user function reuses the frame (3.3, 4.2, 4.3, 6.1),
with loader rules (8), the `tail-calls` fixture, and a VM-only test of a
loop and a mutually recursive pair one million calls deep.

The **linked programs** PR (done) needed no new code: `compile` and
`--vm` already link through `src/modules.rkt`, and the Sources section
already held every file. It added the `linked` fixture (nested relative
imports, a `pkg/` module from `tests/fixtures/vm/agc_libs/`, imported
structs, enums and blocks, and `RUNTIME-INDEX-OUT-OF-RANGE` raised inside
`lib/stock.agc`), the `std-queue` fixture, the `same-basename` fixture
(`lib/a/m.agc` and `lib/b/m.agc` with blocks at the same line and column,
so two functions are named `block@m.agc:2:17`), `--vm` CLI runs of
`linked` in the three formats,
and loader asserts for spans in a second source. No format bump.

9. **7h tasks** (done, Linux). The split structures of 10.2.3 with N=1,
   the scheduler and turn costs of 10.2.1, `Task.spawn`, `await` and
   `sleep`, per-task `Random` (7.4), stdin and file jobs that park only
   their task (10.2.2), the `task-*` fixtures, and the latency test
   (`tests/vm-latency-test.rkt`, `make vm-latency`) with its
   `AGENTICA_VM_TEST_NO_TURN_COST=1` counter-check. No format bump: the
   Task builtins are new import keys only.

10. **7h processes** (done, Linux). Every `Process` builtin behind the VM's
    own `--allow-run`, which `agentica --vm` now passes through (10.4).
    External jobs complete from libuv callbacks (10.2.2). The harness runs
    fixtures named `process-*` with `--allow-run` on both sides; they spawn
    `/bin/sh` and `cat` (`process-streams`, `process-limits`,
    `process-timeouts`, `process-tasks`), and `spawn-denied` checks the
    error without the flag. A CLI test checks the `PATH` rule on both
    backends, and CI diffs `examples/process-tool.agc` on both. No format
    bump: the `Process` builtins are new import keys only.

7e is done when every example runs on the VM with the same results, except
those that need files, processes, tasks or the network by name:
`file-summary`, `process-tool`, `concurrency`, `tcp_echo`, `http_get` and
`http_server`.

## 13. Open questions

- **Random seeding**: resolved in PR 6b: the VM uses its own
  xoshiro256** generator, so seeded sequences differ from the evaluator
  by design (7.4).
- **Heap cap**: `--max-steps` does not bound memory (1), so a hostile or
  runaway file reaches the out-of-memory exit. Before 7i runs untrusted
  bytecode by default, decide on a cap such as `--max-heap N` through
  `GC_set_max_heap_size`, and whether the evaluator gets a matching limit for the one release it
  stays behind a flag. yyjson allocates its parse document with libc
  `malloc`, outside the GC heap, so such a cap must bound it too (for
  example with a counting `yyjson_alc` passed to `yyjson_read_opts`).
- **BDD on the VM**: decided; handlers move to the VM in 7h, and
  the evaluator is removed in 7i (roadmap).
