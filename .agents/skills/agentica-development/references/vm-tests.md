# VM tests: C tests, peers and goldens

Where VM tests live, what they cannot see, and the timing rules.

Read first: `references/vm.md`.

## Files

Each C test starts with a header comment on what it tests, and each Python
module with a docstring, so list them instead of keeping a copy here:

```sh
for f in vm/tests/*_test.c; do echo "== $f"; sed -n 1,5p "$f"; done
for f in tests/test_vm_*.py tests/test_process*.py; do echo "== $f"; head -3 "$f"; done
```

What the files cannot see, or how they must run:

- `vm/tests/job_test.c` holds the pool work with a semaphore, so the test
  orders the events. Not caught: the task recorded after the START post (a
  window of a few instructions, no hook) and `agc_io_finish` without its
  EXPIRED settle (same result on one thread).
- `vm/tests/inbox_test.c` catches a lost wake, not the order of publish and
  send (which holds by construction).
- `vm/tests/runq_test.c` orders by `agc_runq_stats` counts, never by time.
- `vm/tests/task_wake_test.c` is the wake against the park path in C;
  `threads_test.c` has the whole-run side.
- `vm/tests/test_support.h`: `agc_test_deadline(seconds)` (an alarm, so a
  broken park path fails a test instead of hanging `make vm-test`; none on
  Windows).
- `vm/tests/gc_thread_test.c` only runs the threads in the sanitizer build
  (no collector there).
- `vm/tests/text_test.c` and `map_test.c` build 1,000,000-deep values that
  overflow an 8 MB C stack if a printer recurses.
- `vm/tests/tree_test.c`: every real removal runs in a scratch directory that
  is also the working directory; the refused names are asked only of
  `agc_tree_refused`, never of a removal.
- `tests/test_vm_tcp.py` runs `dist/agentica run`, so `AGENTICA_VM_BINARY`
  picks the sanitizer or GC-stress binary. `test_vm_task_map.py` and
  `test_vm_latency.py` skip when it names another binary, and run alone
  (`PY_ALONE`).
- `tests/test_vm_stdout.py` runs on Linux, macOS and Windows; the merged-pipe
  order case is skipped under Wine, which does not tell the two descriptors of
  one pipe apart.
- `tests/test_vm_stack.py` keeps the `<name>.stack.*` sidecars; `make goldens`
  rewrites them, read the diff by hand.
- `tests/test_single_binary.py` needs only the binary, so the sanitizer job can
  run it; the fixed point is a make step, not a test.
- The golden shards: `references/vm-build.md`. Shard 8 runs the VM command
  line, the product CLI and the cases that need more than a fixture (process
  trees, signals, a FIFO, raw bytes in a path or an argument). Modules that
  fixtures import live in `tests/fixtures/vm/lib/` or, for `pkg/`, in
  `tests/fixtures/vm/agc_libs/`.

## Gotchas

- Each sweep limit is one VM start, and the start costs more than the run:
  the diff test runs every limit only up to 200 steps; above that it runs 1
  to 100, limits spaced steps / 50 apart, the steps minus 1 and the steps
  (`sweep_limits` in `tests/vm_diff_support.py`). Under ASan a start costs
  about 20 ms, so the sanitizer and GC-stress runs sample the sweep
  (`AGENTICA_SWEEP=sampled`).
- A race test proves that the race happens. It reads `Time.monotonic_ms()` in
  the program and retries when the margins do not hold: the hand-off case of
  `tests/test_vm_task_map.py` needs the send before the deadline and the sort's
  end after it, by 30 ms each, and runs up to three times.
- To hold the CPU past a deadline, use a builtin that does not yield, such as a
  plain `List.sort` of a big list (turn cost n·⌈log2 n⌉). `sort_by` with a block
  is resumable and can be switched out between its block calls
  (`docs/vm/10-io-scheduler.md` §10.2.1, "Builtins"), so it cannot hold a
  deadline.
- `socketserver` (and so `ThreadingHTTPServer`) listens with
  `request_queue_size = 5`. A test that opens more concurrent connections sets
  `request_queue_size = 32` on its server class (`tests/test_vm_task_map.py`).
- Timing margins go through `scaled()` (`tests/agentica_test.py`): it multiplies
  a value in seconds or milliseconds by `AGENTICA_TEST_TIMEOUT_SCALE`, so a slow
  runner widens every margin together.
- A golden or test that guards a fix must fail on the code before the fix. Build
  the parent commit's binary (a worktree of the parent, then `make`) and run the
  test with `AGENTICA_VM_BINARY=/absolute/path/dist/agentica`: the product CLI
  compiles with `dist/agentica` and the programs run on that binary. Modules
  that skip under `AGENTICA_VM_BINARY` (`tests/test_vm_task_map.py`) are checked
  by removing the fix, rebuilding and running them once.
