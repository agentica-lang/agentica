# VM tests: C tests, peers and goldens

What each VM test file covers, and the golden sweep rules.

Read first: `references/vm.md`.

## Files

- **Path:** `vm/tests/loader_test.c`
  - **Owns:** one assert per loader rule (`type_tables(which)` builds one
    malformed Types section per case; `updates_spec` and `run_with_updates`
    build the Updates section and run `STRUCT_WITH` against hostile receivers;
    `pair_spec` builds a two-function file with a Globals count and
    `globals_tests` covers the cap, the slot indexes, `GLOBAL_SET` only in the
    entry and never beside a backward jump, no call or closure of the entry when
    the count is above zero (and `main()` inside `main` when it is zero), an
    unset read, and a heap value in a slot across collections);
    `front_end_tests` checks that `agc_load_front_end` accepts another Agentica
    version and still refuses another format version or trailing bytes

- **Path:** `vm/tests/list_test.c`
  - **Owns:** the list API, run with Int, Float and boxed items (the million
    lengths for Int only), at the lengths around the 32-way boundaries (0 to 65,
    1,023 to 1,057, 32,768 to 32,801, about a million), plus mixed kinds built
    by hand at the block and tail boundaries (builder, `append`, `set`,
    `concat`, `agc_list_from_array`, conversion to boxed leaves), the kind of an
    empty list, `-0.0`, NaN and the Int limits through every operation, and
    leaves shared across kinds: the shape of the trie (root NULL up to 32 items,
    shift at the boundaries, full leaves, no empty branch), builder and repeated
    `append` (up to 33,000 items) agree, every `get`, cursors from several
    starts, `agc_list_to_array`, persistence of old versions after `append` and
    `set` (also 60-step chains of `set`), `slice` and `concat` at the boundaries
    (a `take` past the trie shares its root), `reverse`, `agc_list_repeat` (its
    shared leaf survives `set`), the `agc_debug` form, 5,000 kept versions of an
    append-built list, leaves shared by `take`, `drop` and `concat` (and not
    shared by a small `take` or an unaligned `drop`), and a list that only
    interior pointers into its items block keep alive across forced collections
    (skipped under `AGC_NO_GC`)

- **Path:** `vm/tests/map_test.c`
  - **Owns:** HAMT: 20,000 keys, order, replacement, persistence, full hash
    collisions, shared 60-bit prefixes, delete (order, persistence, collision
    nodes, down to an empty map), a depth-1,000,000 nested map printed, and
    `shared_empties`: the Set, Map and List builtins that end empty return the
    run's shared object and building on it leaves it empty

- **Path:** `vm/tests/random_test.c`
  - **Owns:** the generator: a seed repeats, seeds differ, `Random.float` and
    `Random.int` bounds (full Int range too), rough uniformity, `low > high`

- **Path:** `vm/tests/float_text_test.c`
  - **Owns:** Float text against values printed by Racket
    (`docs/vm/02-reference-behavior.md` §2.2)

- **Path:** `vm/tests/string_test.c`
  - **Owns:** UTF-8 helpers over every code point, case mapping (special cases,
    final sigma), KMP search on repetitive text, Int and Float parsing edge
    cases with the bits Racket gives, and `shared_strings`: the String builtins
    return the shared empty and one-character Strings (not for a non-ASCII or
    longer result) and they keep their text after a collection

- **Path:** `vm/tests/json_test.c`
  - **Owns:** the sign of zero (`-0.0`, `-1e-500`), escapes, key order and
    dedupe on 5,000 keys, depth-1,000,000 arrays and objects parsed and encoded,
    a deep list through `JSON.from` (100,000 under ASan's `AGC_NO_GC`, 1,000
    under `AGC_GC_STRESS`); the shared empty and one-character Strings for keys
    and values of a parse; parse statuses and number edge cases live in the
    `json-*` fixtures

- **Path:** `vm/tests/budget_test.c`
  - **Owns:** under `AGC_NO_GC`, an allocation past `agc_set_alloc_limit`
    longjmps once, and after `agc_release_all` no limit is set

- **Path:** `vm/tests/text_test.c`
  - **Owns:** write-escape range lookup, String debug forms
    (`docs/vm/02-reference-behavior.md` §2.3), list text, a depth-1,000,000 list
    and a depth-1,000,000 enum/struct chain (hand-built `agc_program` tables):
    deep enough to overflow an 8 MB C stack if the printer recursed; 1,000 under
    `AGC_GC_STRESS`, where the point is GC safety while printing

- **Path:** `vm/tests/task_cancel_test.c`
  - **Owns:** `agc_task_cancel` (20b; also a running task that cancels itself
    after it took a handle, as a handler that closes its own server would, whose
    handle is closed at its end) on the real scheduler: hand-built bytecode
    programs (with a one-line source and a span table, since a crash prints its
    diagnostic) whose builtin table adds test builtins (mark, cancel, a check
    callback, a handle operation on an external job, an `HttpWire.exchange`
    wrapper); every cancel state, a job whose deadline timer fired before the
    cancel (a 200 ms job and a 300 ms block, so the first poll never sees the
    timer), `RUNTIME-TASK-CANCELLED` at the await span (a task that awaits a
    cancelled task now crashes, phase 24), the move of children, the
    `HttpClient` pool against a port-0 socket that never answers TLS, and a pool
    job with a `more` step (`agc_io_start_then`): cancelled while its work runs,
    the `cancel` half is not called and the job ends through `done`; cancelled
    in its loop phase, it is dropped and its poller closes the descriptor; and a
    writer cancelled while it waits in the FIFO of a full stdout buffer (a pipe
    filled beforehand): the next one keeps its place and the bytes that arrive
    are the earlier ones and the next writer's, never the cancelled one's. 17a
    adds `test_map_caller_cancelled` (a `Task.map` caller cancelled while parked
    in its call: the items in flight are cancelled, the pending item never
    starts, the call never returns) and `test_map_deadlines` (limit 1, every
    item runs out of time one after the other, the list holds the timeout error
    three times), `test_map_closes` (items that end with two file closes pending
    are not settled until the last close ends, and then give their results) and
    `test_map_late_closes` (limit 1, items that crash with their closes pending:
    the one that runs out of time is settled as timed out and its crash is
    marked observed, a late end of its closes settles nothing and wakes nobody,
    and the one whose closes end in time settles with its crash as the error);
    `test_closing_task` also checks that the end hook of a task runs once, when
    `agc_task_close_done` brings `closing` to 0; 17c adds
    `test_timed_await_cancel` and `test_timed_await_ends` (they build the
    `Await` enum tables in `new_prog`); `test_woken_while_parking` (the
    `Test.window` builtin marks its task, wakes it, then parks: the CAS makes it
    WOKEN, queues nothing, and the end of the turn queues the task instead of
    parking it, so it is queued once)

- **Path:** `vm/tests/runq_test.c`
  - **Owns:** The global run queue (`vm/runq.c`): FIFO order and removal from
    the middle on the solo queue, then three pushers against three poppers on
    libuv threads after `agc_runq_share` (every task comes out exactly once).

- **Path:** `vm/tests/inbox_test.c`
  - **Owns:** The inbox (`vm/inbox.c`): six producers post 20000 requests each
    and the one consumer sees every request once, in each producer's order; a
    ping that waits for its answer (a lost wake hangs until the deadline); a
    post while the handler runs; an inbox that is not kept does not hold the
    loop; a close handles the requests still queued. The ping catches a lost
    wake, not the order of publish and send, which holds by construction. The
    inbox is closed only after the producers are joined.

- **Path:** `vm/tests/outcome_test.c`
  - **Owns:** The job outcome and count of `core.h`: three threads race to
    settle one outcome (the first wins, every thread and an observer see that
    one), and the last `agc_job_unref` is the only one that sees zero.

- **Path:** `vm/tests/job_test.c`
  - **Owns:** A job on the loop, with a pool work held by a semaphore so the
    test, not the clock, orders the events: the timer before the completion
    (the job stays while the work runs), the completion before the timer, a
    cancel before the completion (a later extend is refused), and the requests
    of a second thread through the inbox (`agc_io_share`): an extend, a START
    still queued when the owner ended the job inline, a finish whose
    CLOSE_TIMER and RELEASE are queued, the `more` path and a late end of the
    wait, a close and a poll that run the queued requests, 2000 jobs that end
    at once on a scheduler thread's START, and 20000 jobs that end in one run.
    `sweep` asserts that a freed job is on no list and has no live wait, which
    catches a double drop. Not caught: the task recorded after the START post
    (a window of a few instructions, no hook) and `agc_io_finish` without its
    EXPIRED settle (the same result on one thread).

- **Path:** `vm/tests/task_wake_test.c`
  - **Owns:** The wake against the park path: the task marks itself PARKING and
    two waker threads call `agc_task_wake` twice each while the scheduler thread
    does `agc_task_commit_park`, 20000 rounds with different timings. The task
    ends in the queue exactly once per round (a dropped wake leaves none, a
    double push leaves two). The single-thread part checks the marks, unpark
    and a stale wake.

- **Path:** `vm/tests/test_support.h`
  - **Owns:** `agc_test_deadline(seconds)` (an alarm, so a broken park path
    fails a test instead of hanging `make vm-test`; none on Windows) and
    `agc_test_ready_head` (the first ready task, for tests that run on one
    thread).

- **Path:** `vm/tests/gc_thread_test.c`
  - **Owns:** Boehm with threads: libuv threads that call `agc_gc_thread_enter`
    allocate checked lists, held only on their stacks, while they and the main
    thread force collections. A collector that missed a stack would free live
    nodes. The sanitizer build has no collector, so it only runs the threads.

- **Path:** `vm/tests/channel_test.c`
  - **Owns:** the `Channel` builtins called directly with hand-made tasks (no
    bytecode): ring growth and its turn cost, wrap-around and the capacity;
    receivers and senders served in order; a woken receiver that is cancelled
    hands its value to the next one, or back to the head of the ring (two
    cancelled receivers return their values in send order, whichever goes
    first); a reserved send slot handed to the next sender or freed, and a woken
    sender that hands its value to a waiting receiver passing its slot on;
    `close` with a value reserved for a woken receiver (`closed?` stays false
    until it is taken, or the value comes back when the receiver is cancelled)
    and with a reserved send slot (the send returns the closed error); a timer
    that fires before a reservation reaches the waiter, and a reservation that
    comes first. The channel-waiter cancel case with the real scheduler is in
    `task_cancel_test.c`.

- **Path:** `vm/tests/output_test.c`
  - **Owns:** `vm/output.c` with hand-made tasks and a pipe: the order of small
    prints, writers that wait not being passed by later ones, the ring wrapping,
    `agc_drain` waiting for an empty buffer and failing when the reader left, a
    head that leaves handing on to the next, a file drained by the pool,
    `/dev/null`, the blocking write on a read-only descriptor, stdout and stderr
    on one target sharing the buffer, a notice that waits for room and keeps its
    text, a notice that does not enter a long print, a leaving long print that
    lets a queued notice and the next writer through, the end of run moving a
    notice held by a cut print, a record that starts a line after a cut print,
    the notice queue limit and a kept notice, and final notices (written
    straight, or dropped when the pipe is full), and a stop signal not waiting
    for a silent reader (on Windows also a socket, which libuv refuses, written
    by a pool thread). It also runs on Windows, where the pipe has an overlapped
    write end (the tests that fill it) or a synchronous one (the other tests, as
    a Python parent gives it), and where a duplicate of the descriptor is one
    target and two pipes are two

- **Path:** `vm/tests/tree_test.c`
  - **Owns:** `agc_remove_tree` (`Path.remove`) on temp trees: links inside the
    tree removed as links with their targets kept, a link as the root and a link
    with a trailing slash refused, missing and non-directory roots, the refused
    names (`/`, `//`, `.`, `..`, empty, `dir/..`) asked only of the pure
    `agc_tree_refused`, never of a removal, with every real removal in a scratch
    directory that is also the working directory, the 128-level limit (a tree
    that fits, one level too deep, cleaned up from the middle), a directory
    swapped for a link just before its open (the binary defines `openat` and
    `__openat_2`, so a walk without `O_NOFOLLOW` or without the skip of a
    changed entry fails), the entry named in a failure (a refusing `unlinkat`, a
    real 0500 directory outside root), a file system that lists a name it cannot
    remove (no loop) or is interrupted (`EINTR` repeated), and a count of
    `/proc/self/fd` around every case to catch a leaked directory

- **Path:** `vm/tests/each_line_test.c`
  - **Owns:** what bytecode cannot reach in the `File.each_line` stepper, driven
    by hand: the buffer argument errors with the span of that argument and no
    stepper installed, a FIFO read that times out and closes its descriptor, and
    a cancelled reader whose descriptor is closed at once (24b: the reader owns
    its file like any task; the test sets `in_turn` while the open finishes so
    `agc_own` records the owner); counts descriptors through `agc_each_fd`. The
    rest is in the `file-each-line*` goldens and `tests/test_vm_file_lines.py`

- **Path:** `vm/tests/stack_test.c`
  - **Owns:** `agc_stack_capture` and the three printers on hand-built tasks
    (14b): one frame in `main` shows nothing and one in a spawned task shows the
    `task spawned at` line, native frames skipped, the tail flag, merged runs of
    10,000 equal frames, the cut at 20 lines (1 frame omitted, then 20), `@N::`
    prefixes and `block@...` names, a line break in a name, a function name and
    a path over 256 bytes cut at a character boundary in the three formats,
    `json_agrees` (`agc_stack_members` encoded as JSON must equal the `--json`
    stack text of `agc_print_diagnostic`), and hostile frames (pc 0, pc past the
    code, function and span indexes out of range, no frames, a frame count past
    the capacity) that must not read out of bounds

- **Path:** `vm/tests/trace_test.c`
  - **Owns:** the trace escaper and line buffer: numbers, empty and special text
    values, invalid UTF-8 bytes as `\u00XX`, lines cut at 512 bytes on a UTF-8
    or escape boundary, the unknown-category warning

- **Path:** `tests/test_vm_tcp.py`
  - **Owns:** the VM against Node peers (`tests/fixtures/tcp-peer.js`): a client
    reading fragments, EOF, a reset, a 1 MiB + 1 line, a silent peer (timeout)
    and a refused port; a VM server with two concurrent Node clients; `main`
    returning while tasks wait on a read, an accept and a full send buffer, with
    the `io` trace ending in `end code=0 signal=0` and the peer seeing the close
    (the exit path closes no socket itself; the OS does at `_exit`); a crashed
    task's and a returned task's connections, which a task closes when it ends
    (24b), seen closing by the peer. Compiles through the CLI and runs
    `dist/agentica run`, so `AGENTICA_VM_BINARY` picks the sanitizer or
    GC-stress binary

- **Path:** `tests/test_vm_trace.py`
  - **Owns:** traced runs (`all`, to a file) give the same exit code, stdout and
    stderr as untraced runs; every line matches the format; unknown category and
    unopenable file lines; `gc` lines from `map-large` (skipped on a sanitizer
    build); a VM started with stderr or stdout closed; a connection task of
    `http-server-close` traced as `parent=group:N` (N the group's owner); skips
    on a `TRACE=0` VM

- **Path:** `tests/test_vm_stop.py`
  - **Owns:** the one exit path under stop signals, with
    `tests/fixtures/stop-peer.py` (Python): `SIGTERM`, `SIGINT` and `SIGHUP`
    kill the children and write the buffered file, and the VM dies by the
    signal; a second signal before the children are stopped waits for them; a
    flush into a FIFO the peer filled waits on the first signal and ends on the
    second; a driven VM whose driver died does not flush; a signal while stdout
    is full ends the run with no diagnostic; a signal with a stdout nobody reads
    ends the run long before the flush limit; Ctrl-C to the CLI's process group
    (the CLI runs as a `Child` in its own session) stops a captured child that
    ignores `INT` and `TERM` and still writes the file; a stop signal inherited
    as ignored (`nohup`, a background job) stays ignored. The tests that send
    `SIGHUP` or `SIGINT` start the VM through the peer's `launch default` mode,
    so their result does not depend on how the test run was started

- **Path:** `tests/test_vm_channel.py`
  - **Owns:** a socket handed to a worker over a channel: the VM accepts six
    connections from a Python peer (`tests/fixtures/channel-peer.py`, port 0),
    sends each socket into a `Channel[Socket]` read by three worker tasks,
    closes the channel, and the workers' loops end

- **Path:** `tests/test_vm_task_map.py`
  - **Owns:** the timing cases of `Task.map`, run alone by `make vm-task-map`
    (`PY_ALONE`; CI runs it after `make vm-latency`): the items in flight never
    pass `limit` and reach it (start and end lines); HTTP against an in-process
    `ThreadingHTTPServer` on port 0 (the peer's own count of requests in flight,
    bodies in input order, responses ended in reverse order); a timed-out item
    with a 60 s sleep, a spawned child and a grandchild whose parent ended; a
    nested `Task.map` of an item that timed out starts no more items; a read in
    a timed-out item is detached and the next line goes to main; a timed-out
    HTTP item leaves no pooled connection (the peer sees the end of file while
    the run goes on); `RUNTIME-TASK-CANCELLED` at main's await span, both when
    main awaits after the timeout and when it is parked before; a timed-out
    receiver leaves the channel queue; a value handed to an item before its
    deadline is kept when a sort holds the CPU past the deadline (the deadline
    is calibrated from the same sort, and a run whose margins do not hold is
    repeated); the `limit` and `timeout_ms` diagnostics at their argument spans;
    `--seed` gives the same numbers whatever order the items end in. Bounds are
    one-sided or generous. Skips when `AGENTICA_VM_BINARY` names another binary

- **Path:** `tests/test_vm_stdout.py`
  - **Owns:** stdout and stderr on the loop, with
    `tests/fixtures/stdout-peer.py` (Python, which starts the VM on pipes, a
    socket pair or a pty it reads late, slowly or never, or a pipe it closes): a
    stuck pipe while a timer task keeps ticking and the run ends once the reader
    drains; two tasks printing long lines with no interleaving and in order; a
    print longer than the ring next to short prints; the end of run draining
    within the flush limit; a reader that never reads (`--flush-timeout`, the
    warning, also with stderr on the same pipe, and then no warning in the
    data); a socket as stdout on the loop; `puts` and `IO.warn` on one pipe and
    on one pty in the order of the calls; `IO.flush` waiting for the reader; a
    task crash diagnostic that waits for a full stderr and arrives whole; a
    `Result.unwrap!` text over 128 KiB reaching a stderr file and a slow stderr
    pipe; a print cut by the end of the run not holding a queued notice or the
    exit; a protocol record after a cut print starting a line; `File` on
    `/dev/stdout` and `/dev/stderr` as pipes; the program output before the
    diagnostic on blocking streams; a regular file drained by the pool while a
    child is stopped at the end of the run; a reader that went away
    (`RUNTIME-INTERNAL`, exit 1); a crashed parent whose waiting child leaves
    the FIFO with nothing partial written. The module runs on Linux, macOS and
    Windows; the socket, pty, `/dev/full` and `/dev/stdout` cases are Unix only,
    and the merged-pipe order case is skipped under Wine, which does not tell
    the two descriptors of one pipe apart

- **Path:** `tests/test_vm_test_protocol.py`
  - **Owns:** a Python peer (`tests/fixtures/test-protocol-peer.py`, with
    `tests/fixtures/child_channel.py`, which starts the VM with a socket pair as
    fd 3) plays the runner of a test file
    (`tests/fixtures/test-protocol-peer.agc`): the list records, one index at a
    time with the record read before the stdout of that test (`read_available`
    order), the test's own stdin, a record-shaped line printed as plain output,
    a partial line, and the `RUNTIME-TEST-RUN` of a run without a channel

- **Path:** `tests/test_vm_child_channel.py`
  - **Owns:** the child channel on its own (`tests/fixtures/child-channel.agc`,
    `child-channel-peer.py`): the VM as the child of a Python parent (lines in
    pieces, a 300 KB line, the end of input, a timeout that closes the channel,
    no channel, a marker without a socket and a socket without the marker, a
    grandchild that gets neither) and the VM as the parent of a Python child
    (send, read, `read_available` order, a half close, a read timeout and a
    stalled send that close only the channel, a line over 1 MiB, a child with no
    channel, an uncaptured child, a UTF-8 character split between two
    `read_available` calls, `channel_close` after the child exited, a stalled
    send that keeps sending until one times out) and fd 3 given to the VM as a
    regular file, a character device or a write-only FIFO (refused, left as it
    was) or as a read-write FIFO (taken)

- **Path:** `tests/test_vm_logger.py`
  - **Owns:** `std/logger` (14c): a run with no setup prints one `INFO` line
    matching the time format and nothing else; the async handler example
    (`tests/fixtures/logger-async.agc`, run in a temporary directory) leaves
    every event in `app.log` in order; the Python peer
    `tests/fixtures/logger-peer.py` writes `Logger.time_text` vectors from
    `datetime` (the epoch, leap days, 2000-02-29, 2100-03-01, year ends,
    negative times, year 9999, 500 drawn values), the VM runs `logger-peer.agc`
    on them, and the peer decodes every JSON line (exact keys, values, field
    order, tasks 1 to 3). The goldens `logger-format`, `logger-levels` and
    `logger-tasks` hold exact stderr; the registry tests are
    `tests/std/logger_test.agc`

- **Path:** `tests/test_vm_stack.py`
  - **Owns:** the exact stderr of `tests/fixtures/vm/stack-trace-*.agc` and
    `tests/fixtures/vm/step-limited/stack-trace-*.agc` in the plain, `--ai` and
    `--json` formats, from the sidecars `<name>.stack.plain`, `.ai` and `.json`
    next to each fixture (the fixtures directory is `@fixtures/`): nested calls,
    a function and a block from an imported file, a block run by `xs.map`, a
    tail call, a recursion that overflows (merged repeats), two functions that
    call each other (the cut), a failing task (`task spawned at`), a step limit
    in `main` and in a task, and a failure in `main` alone (no stack). `make
    goldens` rewrites the sidecars (`python3 -m tests.test_vm_stack`); read the
    diff by hand

- **Path:** `tests/test_vm_os.py`
  - **Owns:** the OS builtins of the BDD driver port, each as a program on the
    VM: `create_private` and `Dir.mkdir_private` modes with umask 0 and no reuse
    of a path (a dangling link too), `File.lstat` and `File.stat` against
    Python's `os.lstat` and `os.stat` (mode with the sticky bit, links, a
    dangling link), `File.try_lock` on two handles and between VM processes (a
    holder that exits, a holder that is killed, and a holder that started a
    child before closing the handle), `File.try_lock` on `/dev/null` and a FIFO
    (an error), the lock kept across the rename of its directory, `Path.remove`
    on a tree with links, a FIFO and a root link (targets kept), the refused
    names asked as `.`, `..` and `dir/..` from a working directory inside the
    scratch directory (never `/`), the depth limit and the entry named in a
    failure, `Path.rename` (an existing target of any kind kept, a link moved as
    a link, six processes racing for one name give one winner), `System.pid`
    against the VM process, the `sh` child's `$PPID` and a child VM started with
    `--driver-pid` from a private copy of its bytecode, and the metrics
    variables kept from children

- **Path:** `tests/test_single_binary.py`
  - **Owns:** `dist/agentica` (built by `make test`): stdout, stderr and exit
    status for examples, runtime errors and diagnostics (the root file as typed,
    imports canonical; the option and diagnostic forms are frozen in
    `tests/test_cli_forms.py`), `compile` bytes run on the VM (round trip),
    `RUNTIME-FRONT-END-ONLY` for a program on the binary and on `agentica run`,
    `--max-steps`, `--seed` and `--allow-run` reaching the program only,
    `agentica run` with `--max-steps`, `--seed`, `--allow-run`, `--json`, its
    usage errors and the long `--version` line, a front end that stops with an
    error exits 2, `test` without `--self`, a closed pipe on `--version` (no
    SIGPIPE death), and with `--front-end` and
    `tests/fixtures/single-binary/front.agc`: the inputs the binary passes,
    every `stdlib/MODULES` source through `FrontEnd.std_source` against the
    file, a front end and a program of another Agentica version, the hand-off
    with options, arguments and stdin, and the errors for bad bytes, words,
    options (`--driver-pid` too) and counts, the input `--self`, a named pipe as
    `--front-end`, a bad `AGENTICA_FLUSH_TIMEOUT_MS`, and a file that is not
    UTF-8 (small and 350 KB, with a time limit). The fixed point is not a test:
    `make fixed-point` is a CI step (`test` and `vm-sanitizers`).
    `tests/test_stdlib_modules.py` checks `stdlib/MODULES` against the folder,
    without the binary

- **Path:** `tests/test_vm_file_lines.py`
  - **Owns:** `File.each_line`: a 10 MB file of short lines streams in order in
    about size over buffer pool jobs (the I/O trace) with bounded peak memory;
    `--max-steps` ends a long file with `RUNTIME-STEP-LIMIT`; with a Python FIFO
    peer (`tests/fixtures/lines-peer.py`): a FIFO fed in pieces with a CRLF
    split across reads and a last line without a newline, a stalled FIFO that
    times out one read (1200 ms) and closes the descriptor, `File.close` of a
    read FIFO that holds read-ahead lines (and an early stop on it) is `ok()`,
    and a crash that cancels a parked reader and frees its descriptor (the
    program polls `/proc/self/fd` with `Task.sleep(10)`, bounded at 5 s, and a
    channel orders the crash after the fd appears)

- **Path:** `vm/tests/http_parse_test.c`
  - **Owns:** the §10.6 hostile list on the request and response head adapter,
    framing, and the body decoder (each body fed whole and byte by byte)

- **Path:** `vm/tests/loop_test.c`
  - **Owns:** the registry (slots after removals), a completed job, a timed-out
    job dropped once its work ends, and `agc_io_close` freeing the loop, or
    returning false while a job is stuck, and the watch of the stop signals over
    two VMs one after the other (the single binary)

- **Path:** `vm/tests/process_test.c`
  - **Owns:** `Process.spawn` called as a C function, then `agc_io_close` with
    the registry in an order that releases the process guard before its process
    (the guard is freed first; run under `make vm-test SANITIZE=1` it caught a
    use after free)

- **Path:** `vm/tests/tls_test.c`
  - **Owns:** two adapters in memory: handshakes with tiny record slices, a
    100,000-byte transfer, `close_notify` and raw EOF, every verify error, EOF
    and a plain HTTP request during the handshake, the load errors (`ENOENT`,
    bad certificate, bad key, mismatch, bad CA)

- **Path:** `tests/test_vm_tls.py`
  - **Owns:** the VM against independent peers (`tests/fixtures/tls-peer.js`,
    `tests/fixtures/tls-peer.py`, certificates in `tests/fixtures/tls/` from
    `make-certs.sh`): a client against Node servers (one-byte records, abrupt
    EOF, a reset, 100,000-byte lines, the 1 MiB limit, a silent peer, wrong
    host, expired, self-signed, TLS 1.0/1.1 only, plain text, a stalled
    handshake), system trust through `SSL_CERT_FILE`, a Python TLS 1.2 server, a
    Python HTTPS server that sees `close_notify` on an idle and an active
    `HttpClient` connection when `main` returns (`client_goodbye`), a VM server
    with two Node clients (TLS 1.3 and 1.2), a Python client and a client that
    does not trust it; VM programs that are their own peers for handshake errors
    on both sides, timeouts and a pending handshake, and the end of a run with
    TLS work pending (`tls` trace); every case runs once (no step sweep), in
    about 5 s; needs Node and Python 3 in CI

- **Path:** `tests/vm_diff_support.py`, `tests/test_vm_diff_{1..8}.py`,
  `tests/fixtures/vm/`
  - **Owns:** golden tests (`<name>.expected` next to each fixture, `make
    goldens` rewrites them from the VM), split into eight shards
    (`HEAVY_FIXTURES` pins the costly fixtures to a shard, the rest cycle
    through shards 1 to 7; shard 8 runs only the VM command line, the product
    CLI and the cases that need more than a fixture: process trees, signals, a
    FIFO, raw bytes in a path or an argument); every top-level `*.agc` is a
    program, and modules they import live in `tests/fixtures/vm/lib/`
    (`imports.agc`, `linked.agc`) or, for `pkg/`, in
    `tests/fixtures/vm/agc_libs/` (`linked.agc`); `std-queue.agc` imports
    `std/queue`; `doc-comments.agc` has `##` docs on every kind of declaration
    and shows the VM runs them unchanged

- **Path:** `tests/test_frontend_bytecode.py`
  - **Owns:** the bytes of the Agentica writer against the frozen output of the
    original writer, the opcode numbers against `agc_opcode` in `vm/value.h`;
    the `compile` exit codes are in `tests/test_vm_diff_8.py`

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
  (`docs/vm/10-io-scheduler.md` §4.3), so it cannot hold a deadline.
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
that
  skip under `AGENTICA_VM_BINARY` (`tests/test_vm_task_map.py`) are checked by
  removing the fix, rebuilding and running them once.
