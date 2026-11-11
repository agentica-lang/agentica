## 12. Testing and the PR plan

### 12.1 Tests

- **VM goldens:** eight `tests/test_vm_diff_*.py` shards run
  `tests/fixtures/vm/` with `dist/agentica run --json`. Each `.expected` pins
  exit code, stdout, program stderr, diagnostic code and steps. The last stderr
  line is parsed for the diagnostic and removed before comparison. Plain and
  `--ai` runs must match exit/stdout; stderr starts with program stderr, with
  only the same diagnostic code (or nothing) after it. See
  `tests/vm_diff_support.py`.
- Fixtures may use `.stdin` and `.args`. `make goldens` rewrites expected output
  and refuses timeouts, signals and `RUNTIME-INTERNAL`; review intended golden
  changes. Every run uses `LC_ALL=C.UTF-8` and `LANG=C.UTF-8` for stable OS
  error text.
- **Step sweep:** fixture goldens record steps `T`; the VM may charge less, but
  may not overcharge by more than `max(10, T / 10)`. Each limit must produce the
  golden outcome or exit 1 with `RUNTIME-STEP-LIMIT` and stdout/stderr prefixes
  of the golden. Full sweeps test every limit through `T` when `T <= 200`; for
  larger `T`, they include 1 to 100, limits spaced `T / 50` apart (at most 50),
  `T - 1`, `T` and `L = max(2T + 100, T + 4000)`. The VM must complete by
  `L`; completion at any limit requires completion at every larger one.
  `make test` defaults to the full sweep; PR CI samples, release and weekly runs
  use the full schedule.
- `tests/fixtures/vm/step-limited/` covers runaway loops (including dead code,
  blocks and closures), recursion/tail calls, tasks and counting builtins; each
  must stop with `RUNTIME-STEP-LIMIT` without printing past the loop.
- C-test ownership, fixture coverage, and sampled sweep limits are listed in the
  development skill's
  [vm-tests](../../.agents/skills/agentica-development/references/vm-tests.md).
- VM goldens are timing-free: timeout behavior belongs in
  `tests/test_vm_http.py`. Filesystem fixtures get a fresh scratch directory per
  run. Network and process peers use standard libraries only (AGENTS.md).

## 13. Open questions

- **Heap cap** (#1113). `--max-steps` does not bound memory (§1); a hostile or
  runaway file can reach the out-of-memory exit (§6.3). yyjson uses libc
  `malloc` outside the GC heap, so a cap must also bound it.
