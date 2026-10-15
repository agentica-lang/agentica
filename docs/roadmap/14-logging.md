## Phase 14: Logging and debugging

Specified in [`docs/future/24-logging.md` section
24](../future/24-logging.md#24-logging-and-debugging). Three small PRs, on the
VM only. 14a is in order step 7.1, right after 7h processes and before TCP and
TLS, to speed up debugging of the rest of 7h; 14b is order row 7.2.5 (taken out
of row 7.5 by the owner on 2026-10-14, before the freeze of row 7.2.7), and it
goes first: it adds no API, and agents get the most from it. 14c is order step
7.5, a new feature after 7i. It no longer waits for default parameter values
(15a, row 7.5a): until then its API has two functions per level (decided on
2026-10-15). 14c follows the library rule (after the order table): the module is
Agentica code, and its native part is the std-only registry `LogRegistry`, a
new exception to the std-first rule (decided on 2026-10-15; the rule lists it
now). Its two builtin types, the record `LogEvent` and the enum `LogLevel`, are
builtins too (§24.2, "Types").

- [x] 14a VM tracing (`docs/future/24-logging.md` §24.4): `vm/trace.h` and
  `vm/trace.c`, `AGENTICA_VM_TRACE` (and `AGENTICA_VM_TRACE_FILE`) with the
  categories `sched`, `io`, `proc`, `tls` (its trace points came with the TLS
  PR; the TCP PR added its events to `io`), `loader` and `gc`; one `write(2)`
  per `agc-trace` line; `make vm TRACE=0` compiles it out (built in the
  `vm-sanitizers` job on manual CI runs and when the trace files change); the
  Makefile `unexport`s both variables and the VM test runners remove them;
  `tests/vm-trace-test.rkt` traces to a file and checks that exit code, stdout
  and stderr do not change. Docs: `docs/vm/` and the development skill. Done: as
  built in `docs/vm/08-loader-and-cli.md` §9 ("VM tracing (as built)"); `tls` is
  defined and has no trace points yet.
- [x] 14b Stack traces on runtime errors (`docs/future/24-logging.md` §24.3),
  always on in the plain, `--ai` and `--json` formats: names and places per
  frame, the tail-call mark, merged repeats, at most 20 lines, the spawn place
  of a failing task. Fixed expected stderr in the three formats. Docs:
  `grammar.md` §7, `docs/vm/02-reference-behavior.md` §2.5 and
  `docs/vm/05-values-execution-builtins.md` §6.1, the programming skill's
  diagnostics reference. Done: as built in
  `docs/vm/05-values-execution-builtins.md` §6.1 (`agc_stack_capture` in
  `vm/diag.c`, called by `agc_fail`; the `tail` flag of the frame; `spawn_span`
  of the task);
  `vm/tests/stack_test.c` for the walk, the merge, the cut and hostile frames,
  `tests/vm-stack-test.rkt` with the exact stderr of the fixtures
  `tests/fixtures/vm/stack-trace-*.agc` in the three formats (`make goldens`
  rewrites them), and the 32 goldens with a task crash line now hold its stack.
- [x] 14c `std/logger` (`docs/future/24-logging.md` §24.2): `stdlib/logger.agc`
  (the levels `debug`, `info`, `warning` and `err`, one function and one `_meta`
  function per level, `log` and `log_meta`, `enabled?`, `level`, `set_level`,
  `attach`, `detach`, `handlers`, the built-in handlers `stderr_text` and
  `stderr_json`, the formatters, the default `console` handler and `time_text`);
  the builtin record `LogEvent` and the builtin enum `LogLevel` in
  `src/builtin-types.rkt`; the std-only registry `LogRegistry` (ten native
  functions on the VM runtime, rows in `src/builtins.rkt`, names in
  `vm-builtins` and `std-only-modules`, and its reserved name in
  `src/checker.rkt`); one line in `src/stdlib.rkt`; and the std-only help in
  `src/modules.rkt`, which names `std/logger` for `LogRegistry`. Each line is
  one `IO.warn` call (24.1). No flags, no grammar change, and no change to
  `CHECK-IMPORT-NAME` in this PR (the "did you mean" help landed as its own PR,
  D9, §24.2, "The freeze"). Tests: goldens with exact stderr (levels, handler
  levels, quoting, field order), attach and detach across tasks, a handler that
  halts crashes only its task, the async handler example end to end, a Python
  peer for the JSON lines, and `Logger.time_text` against Python `datetime`
  vectors.
  Docs: `references/logger.md` of the programming skill with its row in the
  table, `site/content/library/io-and-system/logger.md` with runnable examples,
  the VM notes on the runtime field, and the CHANGELOG entry. Its Racket parts
  are data under the freeze (§24.2, "The freeze"), so the PR may land before,
  during or after row 7.2.7. The registry exception and the freeze are the
  owner's decisions of §24.2. Its two-line change in `src/lower.rkt` for the
  enum field of `LogEvent` relaxes that list for those lines, and the PR says so
  and why (§24.2, "Decided"). Done: `vm/logger.c` (the ten `LogRegistry`
  builtins over `vm->rt->log`), `stdlib/logger.agc`, goldens
  `tests/fixtures/vm/logger-*.agc`, `tests/std/logger_test.agc` for the
  registry, `tests/vm-logger-test.rkt` with the Python peer
  `tests/fixtures/logger-peer.py`, and the benchmark
  `benchmarks/programs/logger-disabled.agc`.

**Done when:** a VM developer can trace the scheduler, I/O, processes and TLS
without editing C; a runtime error shows its call stack; and the site page's
`std/logger` examples run.

