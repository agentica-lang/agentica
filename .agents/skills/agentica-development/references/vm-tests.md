# VM tests: C tests, peers and goldens

What each VM test file covers, and the golden sweep rules. The case lists are
in the files; this page says what a file is for and what it cannot see.

Read first: `references/vm.md`.

## Files

- `vm/tests/loader_test.c`: one assert per loader rule, with hostile Types,
  Updates (`STRUCT_WITH` against hostile receivers) and Globals sections;
  `agc_load_front_end` accepts another Agentica version and still refuses
  another format version or trailing bytes.
- `vm/tests/list_test.c`: the list API with Int, Float and boxed items at the
  32-way trie boundaries, mixed kinds, persistence of old versions, shared
  leaves, and a list kept alive only by interior pointers across forced
  collections (skipped under `AGC_NO_GC`).
- `vm/tests/map_test.c`: the HAMT (collisions, delete, persistence, a
  depth-1,000,000 nested map printed) and `shared_empties` (builtins that end
  empty return the run's shared object, and building on it leaves it empty).
- `vm/tests/random_test.c`: seeds repeat and differ, `Random` bounds, rough
  uniformity.
- `vm/tests/float_text_test.c`: Float text (`docs/vm/02-reference-behavior.md`
  §2.2).
- `vm/tests/string_test.c`: UTF-8 helpers, case mapping, KMP search, Int and
  Float parsing edge cases, and `shared_strings` (the String builtins return
  the shared empty and one-character Strings, not for a non-ASCII or longer
  result).
- `vm/tests/json_test.c`: sign of zero, escapes, key order and dedupe, deep
  arrays and objects, `JSON.from` on a deep list (smaller depths under
  `AGC_NO_GC` and `AGC_GC_STRESS`); parse statuses and number edge cases live
  in the `json-*` fixtures.
- `vm/tests/budget_test.c`: under `AGC_NO_GC`, an allocation past
  `agc_set_alloc_limit` longjmps once, and `agc_release_all` clears the limit.
- `vm/tests/text_test.c`: write-escape ranges, String debug forms
  (`docs/vm/02-reference-behavior.md` §2.3), list text, and 1,000,000-deep
  list and enum/struct chains (hand-built `agc_program` tables) that overflow
  an 8 MB C stack if the printer recurses.
- `vm/tests/task_cancel_test.c`: `agc_task_cancel` on the real scheduler, with
  hand-built bytecode programs (a one-line source and a span table, since a
  crash prints its diagnostic) and test builtins. Every cancel state, a job
  whose timer fired before the cancel, `RUNTIME-TASK-CANCELLED` at the await
  span, the move of children, pool jobs with a `more` step
  (`agc_io_start_then`), a writer cancelled in the FIFO of a full stdout
  buffer (the bytes that arrive are never the cancelled one's), the `Task.map`
  cases (caller cancelled while parked, per-item deadlines, closes still
  pending when an item settles or times out), the end hook of a task (runs
  once, when `agc_task_close_done` brings `closing` to 0), timed awaits, and
  `test_woken_while_parking` (wake before park: queued once).
- `vm/tests/runq_test.c`: the global run queue (`vm/runq.c`): FIFO order and
  removal from the middle on the solo queue, three pushers against three
  poppers after `agc_runq_share` (every task comes out once), the blocking
  waits and the spin (ordered by `agc_runq_stats` counts, not by time).
- `vm/tests/inbox_test.c`: the inbox (`vm/inbox.c`): six producers, one
  consumer, every request once in each producer's order; a ping that waits for
  its answer catches a lost wake (not the order of publish and send, which
  holds by construction); an inbox that is not kept does not hold the loop. It
  is closed only after the producers are joined.
- `vm/tests/compute_test.c`: the compute pool (`vm/compute.c`): order on one
  thread, growth to the pool's size and no further, every end on the loop's
  thread, an idle pool that lets the loop end, and a close that leaves a busy
  thread alone.
- `vm/tests/outcome_test.c`: the job outcome and count of `core.h`: threads
  race to settle one outcome (the first wins), and only the last
  `agc_job_unref` sees zero.
- `vm/tests/job_test.c`: a job on the loop with a pool work held by a
  semaphore, so the test orders the events (timer before completion and the
  reverse, cancel before completion, the same two for a compute job of
  `agc_io_compute`) and the requests of a second thread
  through the inbox (`agc_io_share`). `sweep` asserts that a freed job is on no
  list (catches a double drop). Not caught: the task recorded after the START
  post (a window of a few instructions, no hook) and `agc_io_finish` without
  its EXPIRED settle (same result on one thread).
- `vm/tests/task_wake_test.c`: the wake against the park path: a task marks
  itself PARKING while two waker threads call `agc_task_wake` and the scheduler
  thread does `agc_task_commit_park`; the task ends in the queue exactly once
  per round (a dropped wake leaves none, a double push leaves two). Also the
  runnext slot (`test_runnext`). `threads_test.c` has the whole-run side.
- `vm/tests/test_support.h`: `agc_test_deadline(seconds)` (an alarm, so a
  broken park path fails a test instead of hanging `make vm-test`; none on
  Windows) and `agc_test_ready_head`.
- `vm/tests/gc_thread_test.c`: Boehm with threads: libuv threads that call
  `agc_gc_thread_enter` allocate lists held only on their stacks while
  collections are forced; a collector that missed a stack frees live nodes.
  The sanitizer build has no collector, so it only runs the threads.
- `vm/tests/channel_test.c`: the `Channel` builtins with hand-made tasks:
  ring growth and wrap-around, receivers and senders served in order, a
  cancelled woken receiver or sender handing its value or slot on, `close`
  with a reserved value or slot, and a timer racing a reservation. The
  channel-waiter cancel case on the real scheduler is in
  `task_cancel_test.c`.
- `vm/tests/input_test.c`: `vm/input.c` with hand-made tasks, a pipe as stdin
  and one pool thread: a waiting read leaves the pool free, a second reader
  parks behind the read in flight, EOF reaches each waiter once, and the loop
  closes while a read waits.
- `vm/tests/output_test.c`: `vm/output.c` with hand-made tasks and a pipe:
  print order, writers that wait not being passed, the ring wrapping,
  `agc_drain`, a head that leaves, files and `/dev/null`, stdout and stderr
  sharing one buffer, notices (waiting for room, not entering a long print,
  moved at the end of run, final notices), the notice queue limit, and a stop
  signal not waiting for a silent reader. It also runs on Windows, with an
  overlapped write end (the tests that fill the pipe) or a synchronous one
  (the others, as a Python parent gives it), where a duplicate of the
  descriptor is one target and two pipes are two.
- `vm/tests/tree_test.c`: `agc_remove_tree` (`Path.remove`) on temp trees:
  links removed as links, a link root refused, the refused names (`/`, `.`,
  `..`, empty, `dir/..`) asked only of the pure `agc_tree_refused`, never of a
  removal (every real removal runs in a scratch directory that is also the
  working directory), the 128-level limit, a directory swapped for a link just
  before its open (the binary defines `openat` and `__openat_2`, so a walk
  without `O_NOFOLLOW` or the changed-entry skip fails), the entry named in a
  failure, listing and `EINTR` edge cases, and a `/proc/self/fd` count around
  every case to catch a leaked directory.
- `vm/tests/each_line_test.c`: what bytecode cannot reach in the
  `File.each_line` stepper: buffer argument errors with that argument's span,
  a timed-out FIFO read that closes its descriptor, a cancelled reader whose
  descriptor closes at once (the test sets `in_turn` while the open finishes
  so `agc_own` records the owner). The rest is in the `file-each-line*` goldens
  and `tests/test_vm_file_lines.py`.
- `vm/tests/stack_test.c`: `agc_stack_capture` and the three printers on
  hand-built tasks: merged runs, the cut at 20 lines, name and path cutting at
  a character boundary, `json_agrees` (`agc_stack_members` as JSON must equal
  the `--json` stack text of `agc_print_diagnostic`), and hostile frames (pc,
  function and span indexes out of range, frame count past the capacity) that
  must not read out of bounds.
- `vm/tests/trace_test.c`: the trace escaper and line buffer (invalid UTF-8
  as `\u00XX`, lines cut at 512 bytes on a UTF-8 or escape boundary, the
  unknown-category warning).
- `tests/test_vm_tcp.py`: the VM against Node peers
  (`tests/fixtures/tcp-peer.js`): client and server cases, `main` returning
  while tasks wait on a read, an accept and a full send buffer (the `io` trace
  ends in `end code=0 signal=0` and the peer sees the close; the exit path
  closes no socket itself, the OS does at `_exit`), and connections a task
  closes when it ends. Runs `dist/agentica run`, so `AGENTICA_VM_BINARY` picks
  the sanitizer or GC-stress binary.
- `tests/test_vm_trace.py`: traced runs give the same exit code, stdout and
  stderr as untraced runs; every line matches the format; `gc` lines from
  `map-large` (skipped on a sanitizer build); skips on a `TRACE=0` VM.
- `tests/test_process.py`, `tests/test_process_lifecycle.py`,
  `tests/test_process_windows.py`: `Process` on Linux, macOS and Windows with
  Node and Python peers (`tests/fixtures/process-peer.js`, `process-peer.py`):
  spawn and the ways a run ends; a child is gone when its owner ends, the run
  is stopped or the driver of its VM is killed; the exit pair libuv reports for
  a stopped child (Windows only). The cleanup cases that use SIGTERM or chmod
  on POSIX have Windows counterparts in `test_windows_process_cleanup.py`.
  `test_process_bdd.py` keeps the `agentica test` case apart because it starts
  the whole driver (Windows runs it natively, not under Wine). The C side is
  `vm/tests/process_test.c`.
- `tests/test_vm_stop.py`: the one exit path under stop signals, with
  `tests/fixtures/stop-peer.py`: `SIGTERM`, `SIGINT` and `SIGHUP` kill the
  children and write the buffered file, and the VM dies by the signal; a
  second signal waits for the children; flush into a FIFO; a driven VM whose
  driver died does not flush; Ctrl-C to the CLI's process group (the CLI runs
  as a `Child` in its own session); an inherited ignored stop signal stays
  ignored. The tests that send `SIGHUP` or `SIGINT` start the VM through the
  peer's `launch default` mode, so the result does not depend on how the test
  run was started.
- `tests/test_vm_channel.py`: a socket handed to a worker over a
  `Channel[Socket]` (Python peer `tests/fixtures/channel-peer.py`, port 0).
- `tests/test_vm_task_map.py`: the timing cases of `Task.map`, run alone by
  `make vm-task-map` (`PY_ALONE`; CI runs it after `make vm-latency`):
  in-flight bound, HTTP against an in-process `ThreadingHTTPServer` on port 0,
  timed-out items (spawned children, nested `Task.map`, detached reads, pooled
  connections, `RUNTIME-TASK-CANCELLED` at main's await span), a value handed
  to an item before its deadline kept when a sort holds the CPU past it (the
  deadline is calibrated from the same sort; a run whose margins do not hold is
  repeated), the `limit` and `timeout_ms` diagnostics at their argument spans,
  and `--seed` giving the same numbers whatever order the items end in. Bounds
  are one-sided or generous. Skips when `AGENTICA_VM_BINARY` names another
  binary.
- `tests/test_vm_stdout.py`: stdout and stderr on the loop, with
  `tests/fixtures/stdout-peer.py` (starts the VM on pipes, a socket pair or a
  pty it reads late, slowly or never, or a pipe it closes): a stuck pipe while
  a timer task keeps ticking, no interleaving of long lines, the end of run
  draining within the flush limit, a reader that never reads
  (`--flush-timeout` and its warning), `puts` and `IO.warn` order on one pipe
  and one pty, crash diagnostics that wait for a full stderr and arrive whole,
  a print cut by the end of run not holding a queued notice or the exit, `File`
  on `/dev/stdout` and `/dev/stderr`, and a reader that went away
  (`RUNTIME-INTERNAL`, exit 1). Runs on Linux, macOS and Windows; the socket,
  pty, `/dev/full` and `/dev/stdout` cases are Unix only, and the merged-pipe
  order case is skipped under Wine, which does not tell the two descriptors of
  one pipe apart.
- `tests/test_vm_test_protocol.py`: a Python peer
  (`tests/fixtures/test-protocol-peer.py`, with `child_channel.py`, which
  starts the VM with a socket pair as fd 3; on Windows a Node peer
  `test-protocol-peer.js` with `child_channel.js`: two pipes at fd 3 and 4, the
  child's stdout in a file that the peer reads when a record arrives, since two
  pipes do not keep their order) plays the runner of a test file
  (`tests/fixtures/test-protocol-peer.agc`): list records, one index at a time
  with the record read before the stdout of that test (`read_available`
  order), the test's own stdin, a record-shaped line printed as plain output,
  a partial line, and `RUNTIME-TEST-RUN` for a run without a channel.
- `tests/test_vm_child_channel.py`: the child channel on Linux, macOS and
  Windows (`tests/fixtures/child-channel.agc`, `child-channel-peer.js`): the VM
  as the child of a Node parent and as the parent of a Node child (framing,
  half close, timeouts, a UTF-8 character split between two `read_available`
  calls), and a child that is gone after its parent is killed (it reads the end
  of input and leaves a mark on Linux and macOS; libuv's job object ends it on
  Windows).
- `tests/test_vm_child_channel_posix.py`: the POSIX cases
  (`child-channel-peer.py`): descriptor 3 as a regular file, a character
  device or a write-only FIFO (refused, left as it was) or a read-write FIFO
  (taken), and a shell grandchild that gets neither the marker nor the socket.
- `tests/test_vm_logger.py`: `std/logger`: a run with no setup prints one
  `INFO` line; the async handler example (`tests/fixtures/logger-async.agc`)
  leaves every event in `app.log` in order; the Python peer
  `tests/fixtures/logger-peer.py` writes `Logger.time_text` vectors from
  `datetime` and decodes every JSON line the VM writes. The goldens
  `logger-format`, `logger-levels` and `logger-tasks` hold exact stderr; the
  registry tests are `tests/std/logger_test.agc`.
- `tests/test_vm_stack.py`: the exact stderr of `stack-trace-*.agc` fixtures
  (also under `step-limited/`) in the plain, `--ai` and `--json` formats, from
  the sidecars `<name>.stack.plain`, `.ai` and `.json` (the fixtures directory
  is `@fixtures/`). `make goldens` rewrites the sidecars
  (`python3 -m tests.test_vm_stack`); read the diff by hand.
- `tests/test_vm_os.py`: the OS builtins of the BDD driver port, each as a
  program on the VM: private creation modes, `File.lstat` and `File.stat`
  against Python's `os`, `File.try_lock` between handles and VM processes
  (holder exits, is killed, or started a child before closing), `Path.remove`
  and `Path.rename` with links, FIFOs and races, the refused names asked from a
  working directory inside the scratch directory (never `/`), `System.pid`, and
  a child VM started with `--driver-pid` from a private copy of its bytecode.
- `tests/test_single_binary.py`: `dist/agentica` (built by `make test`):
  stdout, stderr and exit status for examples, runtime errors and diagnostics
  (the option and diagnostic forms are frozen in `tests/test_cli_forms.py`),
  the `compile` round trip, `RUNTIME-FRONT-END-ONLY`, the flags reaching the
  program only, `agentica run` usage errors and the long `--version` line, and,
  with `--front-end` and `tests/fixtures/single-binary/front.agc`, the inputs
  the binary passes, every `stdlib/MODULES` source through
  `FrontEnd.std_source`, a front end and a program of another Agentica
  version, the hand-off, and the errors for bad bytes, words, options and
  counts. The fixed point is not a test: `make fixed-point` is a CI step
  (`test` and `vm-sanitizers`). `tests/test_stdlib_modules.py` checks
  `stdlib/MODULES` against the folder, without the binary.
- `tests/test_vm_lazy_io.py`: `File.foreach` and `write_lines` close their
  file on every exit path of a terminal (`lazy-file.agc`, `lazy-write.agc`
  under the io trace) and at the end of a run that `--max-steps` stopped;
  portable, so the macOS and Windows jobs run it.
- `tests/test_vm_file_lines.py`: `File.each_line`: a 10 MB file streams in
  order over buffer pool jobs with bounded peak memory; `--max-steps` ends a
  long file with `RUNTIME-STEP-LIMIT`; with a Python FIFO peer
  (`tests/fixtures/lines-peer.py`): pieces with a CRLF split across reads, a
  stalled FIFO that times out one read (1200 ms), `File.close` of a read FIFO
  with read-ahead lines is `ok()`, and a crash that cancels a parked reader and
  frees its descriptor (the program polls `/proc/self/fd` with
  `Task.sleep(10)`, bounded at 5 s, and a channel orders the crash after the
  fd appears).
- `vm/tests/http_parse_test.c`: the hostile list of
  `docs/vm/10-io-http.md` §10.6 on the request and response head adapter,
  framing, and the body decoder (each body fed whole and byte by byte).
- `vm/tests/loop_test.c`: the registry, a completed job, a timed-out job
  dropped once its work ends, `agc_io_close` freeing the loop (or returning
  false while a job is stuck), and the watch of the stop signals over two VMs
  one after the other.
- `vm/tests/process_test.c`: `Process.spawn` as a C function, then
  `agc_io_close` with the registry in an order that releases the process guard
  before its process (run under `make vm-test SANITIZE=1` it caught a use after
  free).
- `vm/tests/tls_test.c`: two adapters in memory: handshakes with tiny record
  slices, a 100,000-byte transfer, `close_notify` and raw EOF, every verify
  error, and the load errors.
- `tests/test_vm_tls.py`: the VM against independent peers
  (`tests/fixtures/tls-peer.js`, `tls-peer.py`, certificates in
  `tests/fixtures/tls/` from `make-certs.sh`): client and server cases in TLS
  1.3 and 1.2, bad peers (wrong host, expired, self-signed, old versions, plain
  text, stalled handshake), system trust through `SSL_CERT_FILE`,
  `close_notify` on an idle and an active `HttpClient` connection when `main`
  returns, and the end of a run with TLS work pending (`tls` trace). Every case
  runs once (no step sweep); needs Node and Python 3 in CI.
- `tests/vm_diff_support.py`, `tests/test_vm_diff_{1..8}.py`,
  `tests/fixtures/vm/`: the golden tests, in eight shards (rules in
  `references/vm-build.md`; shard 8 runs only the VM command line, the product
  CLI and the cases that need more than a fixture: process trees, signals, a
  FIFO, raw bytes in a path or an argument). Every top-level `*.agc` is a
  program; modules they import live in `tests/fixtures/vm/lib/` or, for `pkg/`,
  in `tests/fixtures/vm/agc_libs/`.
- `tests/test_frontend_bytecode.py`: the bytes of the Agentica writer against
  the frozen output of the original writer, and the opcode numbers against
  `agc_opcode` in `vm/value.h`; the `compile` exit codes are in
  `tests/test_vm_diff_8.py`.

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
