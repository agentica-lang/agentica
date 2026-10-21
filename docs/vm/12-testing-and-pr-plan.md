## 12. Testing and the PR plan

### 12.1 Tests

- **VM goldens:** eight `tests/test_vm_diff_*.py` shards run
  `tests/fixtures/vm/` with `dist/agentica run --json`. Each `.expected` pins
  exit code, stdout, program stderr, diagnostic code and steps. The last stderr
  line is parsed for the diagnostic and removed before comparison. Plain and
  `--ai` runs must match exit/stdout; stderr starts with program stderr, with
  only the same diagnostic code (or nothing) after it. See
  `tests/vm_diff_support.py`.
- Fixtures may use `.stdin` and `.args`; `process-*` needs `--allow-run`.
  `make goldens` rewrites expected output and refuses timeouts, signals and
  `RUNTIME-INTERNAL`; review intended golden changes.
- Every run uses `LC_ALL=C.UTF-8` and `LANG=C.UTF-8` for stable OS error text.
- **Step sweep:** fixture goldens record steps `T`; the VM may charge less, but
  may not overcharge by more than `max(10, T / 10)`. Each limit must produce the
  golden outcome or exit 1 with `RUNTIME-STEP-LIMIT` and stdout/stderr prefixes
  of the golden. Full sweeps test every limit through `T` when `T <= 200`; for
  larger `T`, they include 1–100, limits spaced `T / 50` apart (at most 50),
  `T - 1`, `T` and `L = max(2T + 100, T + 4000)`. The VM must complete by
  `L`; completion at any limit requires completion at every larger one.
  `make test` defaults to the full sweep; PR CI samples, release and weekly runs
  use the full schedule.
- `tests/fixtures/vm/step-limited/` covers runaway loops (including dead code,
  blocks and closures), recursion/tail calls, tasks and counting builtins; each
  must stop with `RUNTIME-STEP-LIMIT` without printing past the loop. Linux runs
  have a 60-second timeout; only the first timeout per fixture waits the full
  duration.
- Other coverage includes CLI styles/flags, signals, inherited descriptors,
  invalid UTF-8, long/deep values, extreme Ints and independent network/process
  peers. C-test ownership, fixture coverage, and sampled sweep limits and
  spacing are listed in:
  [vm-tests](../../.agents/skills/agentica-development/references/vm-tests.md).
- Filesystem fixtures get a fresh scratch directory per run and clean it up.
  VM goldens are timing-free: timeout behavior belongs in
  `tests/test_vm_http.py`. Network/process peers use standard libraries only
  and run in CI.

### 12.2 PR plan

All items are done; `docs/roadmap/07-vm.md` is the active checklist. Keep these
item numbers: other docs cite them.

1. Vertical slice: Int/Bool, control flow, functions, loader, CLI and
   differential tests.
2. Float, comparisons and Float text (§2.2).
3. Strings, printing, diagnostics, exit codes and GC stress.
4. macOS and Windows C tests.
5. Data: 5a Lists; 5b structs/enums/case; 5c Result/try; 5d Maps; 5e closures.
6. Library: 6a IO/System; 6b String/List/Map/Float/Time/Random builtins.
7. JSON: `parse`/encode/builders, then decode/schema (format v3, §4.6).
8. Filesystem/libuv (`File`, `Dir`, `Path`) on Linux.
9. Tasks and per-task `Random`, one scheduler.
10. Processes behind `--allow-run`.
11. TCP (`Socket`, `Listener`).
12. TLS with vendored OpenSSL.

Also done, not numbered: ranges (8a), tail calls (`TAIL_CALL`, §4.3) and linked
programs; the front end links modules, so the VM needed no new code.

### 12.3 Plan for HTTP and TlsContext

Current status and remaining gates live in
[`docs/future/30-hybrid-http.md`](../future/30-hybrid-http.md) (§30, row 7.4)
and [`docs/future/29-tls-context.md`](../future/29-tls-context.md) (§29.9, row
7.4). Streaming and
the HTTP benchmark precede `TlsContext`. Testing continues to follow §12.1:
timing-free goldens, timeout tests in `tests/test_vm_http.py`, and standard-
library-only peers.

## 13. Open questions

- **Heap cap.** `--max-steps` does not bound memory (§1); a hostile or runaway
  file can reach the out-of-memory exit (§6.3). A cap such as `--max-heap N`
  via `GC_set_max_heap_size` is undecided. yyjson uses libc `malloc` outside the
  GC heap, so any cap must also bound it, for example with a counting
  `yyjson_alc` passed to `yyjson_read_opts`.
