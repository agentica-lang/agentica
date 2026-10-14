# Bytecode VM development (phase 7)

The VM's codename is Aurora (Aurora VM). Only the docs use it: the binary,
the `AGENTICA_VM*` variables, the `agc_` prefix, `.agcb` and `vm/` keep
their names.

`docs/vm/` is the contract: reference behavior, IR, bytecode format, value
layout, loader rules, libraries and the PR plan. Its "Status" note says which
subset runs today. This file is the working guide: where things live, how to
widen the VM, and the rules every change keeps. When this guide and
`docs/vm/` disagree, `docs/vm/` wins. The VM is the only backend and the
reference: roadmap 7i deleted the Racket evaluator. Notes below that compare
with "the evaluator" record why a rule was copied from it.

## Pipeline and files

```text
check #:types (src/checker.rkt)   eq? hash: expression node -> checked type
lower         (src/lower.rkt)     checked program -> IR, or LOWER-UNSUPPORTED / LOWER-INTERNAL
ir->bytecode  (src/bytecode.rkt)  IR -> bytecode; adjacent STEP merge; BYTECODE-LIMIT / -INTERNAL
write-bytecode                    the versioned .agcb file (magic, format version, Agentica version)
vm/main.c     dist/agentica-vm [--max-steps N] [--seed N] [--flush-timeout MS] [--allow-run] [--ai|--json] -- file.agcb [args...]   (AGENTICA_FLUSH_TIMEOUT_MS sets the flush limit, default 30000)
src/main.rkt  agentica file.agc: all of the above through a 0600 temp file, then the VM (LOWER-UNSUPPORTED exits 1)
```

| Path | Owns |
|---|---|
| `vm/value.h`, `vm/port.h`, `vm/core.h`, `vm/services.h` | the layer headers ("Which layer" below): `value.h` the values, program tables, memory and Json value API, with `agc_opcode` (same order as `opcodes` in `src/bytecode.rkt`); `port.h` the runtime structs and the port a service uses (with `agc_step`, `agc_stepper`, `agc_step_fn` and `agc_task_stepper`, the stepper protocol under "Adding a builtin"); `core.h` what only the core and the driver call; `services.h` the exports of the services |
| `vm/tools/check-layers.sh`, `vm/tools/check-layers-test.sh` | the layer check run by `make vm-layers` (`docs/vm/15-layers.md` §15.5): include rules with `rg`, link rules with `nm` on the objects (Linux only), the header chain; the self-test plants one violation at a time in a temporary copy and rebuilds the object for the link cases |
| `vm/loader.c` | full validation of untrusted `.agcb` input (`docs/vm/08-loader-and-cli.md` §8), including the struct and enum tables (one variant array sized by a first pass, one shared empty value per nullary variant) and the Types section (`load_types`: kinds, back-pointing List/Map entries at most 1024 deep, struct records with unique `json_name`s and `field_types`) |
| `vm/value.c` | allocation (and the GC stress hook), checked accessors, String allocation, UTF-8 checks and code point count (`agc_utf8_count`), `agc_error_value` (an `error` Result from C text), OOM/abort handlers |
| `vm/map.c` | maps: SipHash-1-3 over the value tag word then the key bytes keyed by `vm->hash_key` (set by `agc_vm_init`, then from OS entropy in `vm/main.c`: `getrandom`, then `/dev/urandom`, else the fixed key), the persistent HAMT (`agc_map_put`, `agc_map_get`, `agc_map_delete`, and `_hash` variants that take a given hash, for tests), and `agc_map_keys` (insertion order from the reversed key list) |
| `vm/list_impl.h` | private to the core: `struct agc_list` (`{ len, root, shift, tail[] }`), the trie node types and the `static inline` `list_len`, `list_at` (no bounds check; reads the tail in line and calls `agc_list_trie_get` of `list.c` for the trie) and `list_get`. `list.c` and `interp.c` (`LIST_LEN`, `LIST_GET`, hot in `for` loops) include it, and so does `vm/tests/list_test.c` for the shape checks; `make vm-layers` fails any other include |
| `vm/list.c` | lists: `struct agc_list` is defined in `list_impl.h` and opaque everywhere else, so no other file reads the layout; the layout is a persistent vector (a 32-way trie of leaves of 32 items plus an inline tail of 1 to 32 items, `root` NULL up to 32 items, canonical `shift` 5, 10, 15, 20 from 33, 1,057, 32,801 and 1,048,609 items; `append`, `set`, `slice` and `concat` copy the tail and the path and share the rest, so `push` and `set` are near constant time and `get` is one compare up to 32 items and at most 4 loads up to a million; `take`, `drop`, `reverse` and a big `concat` stay O(n)); the API of `value.h`: `agc_list_len`, `agc_list_get` (a bad index aborts; the caller checks it and fails with the program's diagnostic), a sized builder (`agc_list_builder_sized`, `_push`, `_finish`; the only code that writes a list, and only before it returns it; a wrong count aborts) for every new list whose count is known, `agc_list_from_array` for a staged array (`filter`), `agc_list_to_array`, `agc_list_cursor_begin`/`_next` for scans, and `agc_list_append`, `_set`, `_slice` and `_concat`, which never write to their input. Builders and cursors live on the C stack or in `agc_alloc` memory; a cursor reads leaf by leaf (one descent per leaf). `List.append`, `List.set` and a `List.concat` with 32 items or fewer cost no turn units (the builtin charges `2 * (a + b)` for a longer right list). `docs/vm/17-lists.md`; the gate is `benchmarks/programs/list-build.agc` |
| `vm/text.c` | text and debug forms (`agc_text`, `agc_debug`, and `agc_test_text`, the debug form with each `Json` as its canonical text, for `Test.eq`; lists, maps, structs, enums and Results through one explicit `agc_alloc`'d stack and a growing String, names from the program's tables), `agc_concat`, and `agc_write_form`, the one Racket `write` escaper for Strings |
| `vm/unicode_data.c` | generated by `vm/tools/gen-unicode.rkt` from Racket (`make vm-unicode`); never edit by hand: write-escape ranges, full case maps, cased and case-ignorable ranges (final sigma) |
| `vm/strings.c` | the `String` builtins (`agc_string_builtins`, one of the tables `agc_find_builtin` loops over) and their helpers: UTF-8 encode, `agc_utf8_offset` with each task's one-entry cursor (string, code point index, byte offset), KMP search (`agc_text_find`), `agc_change_case`, `agc_parse_int`, `agc_parse_float` |
| `vm/interp.c` | one turn of the current task (`agc_run_turn`, returns yield, parked or done) and the budgets: the "next stop" counter of `STEP` over the turn and the batch taken from the runtime's atomic `steps_left` (`agc_turn_begin`, `agc_turn_finish`, the slow path), the turn-cost apply path after `CALL_BUILTIN`, between callbacks and after `CONCAT`, `TO_TEXT`, `INSPECT`, `EQ`, `NE`, `SAME`, `MAP`, `MAP_GET` (`agc_charge`, `agc_charge_bytes`; skipped with `AGENTICA_VM_TEST_NO_TURN_COST=1`); frames, registers, call depth, `TAIL_CALL` frame replacement, `TRY` (returns an error like `RETURN`; one that would empty the call stack is `RUNTIME-INTERNAL`), Int rules, `CLOSURE`/`CALL_VALUE`, and the resumable `List` callback builtins (native frames, `agc_native` state, the `sort_by` merge sort), and the stepper builtins (7.2.1h): a builtin calls `agc_task_stepper(vm, &state->stepper)` and returns, then `CALL_BUILTIN` sees `t->stepper` and `start_stepper` pushes an `AGC_NATIVE_STEPPER` frame whose block is the builtin's last argument; `resume_stepper` asks the step function (`agc_step_fn`) what to do next: `AGC_STEP_CALL` calls the block with one argument and the block's result is the next `last` (read from the native frame's base register), `AGC_STEP_WAIT` parks the task (the step function started a job, so `t->parking` must be set, else `RUNTIME-INTERNAL`) and the job's result is the next `last`, `AGC_STEP_END` finishes the builtin with the step's value; a native top frame is resumed at the start of every turn; each call costs one step plus the turn cost; core code cannot call services, so the function pointer is installed at run time |
| `vm/builtins.c` | the core builtins (`agc_core_builtins`: `IO`, `System`, `List`, `Map`, `Result`, `Range`) and `agc_find_builtin`, which matches by implementation key and arity from the import table over `agc_builtin_tables` |
| `vm/builtin_tables.c` | `agc_builtin_tables`, the list of every library's own table in lookup order (the first match wins): the one place that names the services' tables; a new builtin library adds its table here and its `extern` to `vm/services.h` |
| `vm/numbers.c` | `Float`, `Time` and `Random` builtins (`agc_number_builtins`) |
| `vm/random.c` | xoshiro256** seeded with splitmix64, both public domain (`agc_random_seed`, `agc_random_next`, `agc_random_float`, `agc_random_int`; `docs/vm/05-values-execution-builtins.md` §7.4) |
| `vm/json.c` | the `JSON` builtins (`agc_json_builtins`) and `agc_json_parse` (the Racket control-character pass, top-level numbers and literals by hand, strings, arrays and objects through yyjson with `STOP_WHEN_DONE` and `NUMBER_AS_RAW`, then a copy into GC nodes with an explicit stack, built with the node functions of `vm/json_value.c`; `docs/vm/02-reference-behavior.md` §2.6) |
| `vm/json_value.c` | the `Json` value (`agc_json` nodes, 5.1), in the core because `text.c` and `equal.c` print and compare a Json: `agc_json_encode` (the one `write-json` writer, for `JSON.encode` and the text form of a Json) and `agc_json_from` (builders), both over one explicit stack; the node functions the parser and the builtins share (`agc_json_leaf`, `agc_json_object`, `agc_json_array`, `agc_json_container`, `agc_json_store` and `agc_json_finish`, which sorts the members by key bytes and drops repeated keys, and `agc_json_find`); the buffer, stack growth and ASCII helpers (`agc_json_put`, `agc_json_grow`, `agc_json_ascii`) |
| `vm/json_typed.c` | `agc_json_decode` and `agc_json_schema` (`docs/vm/02-reference-behavior.md` §2.7): one explicit frame stack over the Json tree and the type table, the error path built from the frames only on failure; schema marks the types and structs reachable from the target with a queue, then builds their schemas in index order. The buffer, stack growth and ASCII helpers are `agc_json_put`, `agc_json_grow` and `agc_json_ascii` from `vm/json_value.c`. The builtins in `vm/json.c` find the struct by its linked name (`json_name`) |
| `vm/loop.c` | the event loop and the resource registry (`docs/vm/10-io-scheduler.md` §10.2.2), with `vm/stream.c`, `vm/process.c`, `vm/tcp.c` and `vm/http_client.c` the only files that include `uv.h` (`vm/http_server.c` reaches libuv only through `vm/net.h` and jobs): `agc_io_init` (the `UV_USE_IO_URING=0` setenv at start-up; returns whether it set it), `agc_io_uv` (the scheduler's `uv_loop_t`, for handle code), `agc_io_ready` (completes an `external` job from a libuv callback), `agc_register`/`agc_unregister` (GC `agc_resource` objects owning `malloc` memory; a job keeps its registry slot index, fixed when an entry moves), `agc_io_start` (one `uv_queue_work` job plus an optional timer per blocking call; a kind without `work` is a timer only; parks the current task through `r->task` and `task->parked`), `agc_io_poll` (`uv_run` NOWAIT or ONCE, then the ready list of finished jobs wakes their tasks; a non-empty ready list is drained even when the loop has nothing alive, and makes the run NOWAIT), `agc_io_finish` (the request's `done` or `expired` half when the parked task runs again; it first releases a handle the request held, handing it to the head waiter as `next_owner`), `agc_io_detach` (20b: the job of a cancelled task is detached; it ends between turns when the drain meets it, runs `done` and drops the result (closing a new handle in it, except a process: `process.c` sets `keep_detached` on its resource), never `expired`, so it never closes a task's handle; a kind's optional `cancel(vm, data, context, deadline)` half, refused on pool kinds, may end it early through `drop`, also when its timer fired before the cancel; a queued job is never swept), `agc_io_detached` (phase 24: a job with no task from the start, for a crashed task's file close), `agc_io_extend` (20c: restart a job's own timer once, so `read_request`'s deadline counts from the request's first byte), handle ownership (24b: `agc_own` records a handle's owner and close and puts it on the owner task's list (`owned_prev` and `owned_next` in the resource, `owned` in the task), `agc_unregister` takes it off, `agc_owned_of` finds the owned resource of a handle value, `agc_hand_over` moves it to another task, `agc_close_owned(vm, t)` closes what a task still owns when it ends), `close_pending` runs a file's pending close after the job that held it; `agc_own` sets no owner outside a turn; at the end `close_files` starts the same close job for every open file (`agc_resource.pool_close`) and `finish_flushes` waits for all of them with `uv_run` ONCE until the flush-limit deadline timer (30000 ms, `--flush-timeout` or `AGENTICA_FLUSH_TIMEOUT_MS`), setting `rt->flush_expired` for `vm/main.c`'s warning line), `agc_handle_leave` (a cancelled lock waiter leaves the FIFO; a cancelled `next_owner` passes the lock on), `agc_handle_wait` (the per-handle FIFO lock: take it as `next_owner` or when free, else queue and park with retry on a timer-only job at the task's own deadline; a `closing` handle lets every caller through, so the builtin returns its closed error), the one exit path (`docs/vm/10-io-scheduler.md` §10.2.2 "End of run"; `end_run` in `vm/main.c`: `agc_processes_stop` kills the children, `agc_io_children_stopped` acts on a second signal recorded meanwhile, `agc_io_goodbye` calls each resource's `goodbye` hook (TCP: one TLS `close_notify` by `uv_try_write`), stdout and stderr flush (retried on `EINTR`), `agc_io_flush_files` closes the files and waits for their flush jobs until the flush limit under a fresh `setjmp`, then `_exit`, or the stop signal raised again with the stop signals blocked for the last read; nothing else is joined or drained), stop signals (`agc_io_watch_stop`: a `sigaction` handler for `SIGINT`/`SIGTERM`/`SIGHUP`, not for one inherited as ignored, and a `SIGALRM` backstop, installed and armed only when a second signal is recorded; the one global `stop`, marked `NOLINT`, holds lock-free atomics (first signal, a second one, `held` until the children are stopped), the driver pid and an unreferenced `uv_async_t` that wakes the loop; `check_stop` in `vm/task.c` ends the run between turns, before a wait and before a stall error, through `agc_stop` in `vm/interp.c`, which `agc_write` and `agc_flush` also call on `EINTR`; a second signal ends the VM at once, except while `held`; a driven VM whose driver is gone takes that path on its first signal), `agc_poller_*` (a `malloc`'d `uv_poll_t` that owns a descriptor that can wait forever: open (returns the libuv error), wait readable or writable with a callback, pause, close, which closes the descriptor), `agc_io_start_then` (a pool job's `more` step, run on the loop thread after its work, may keep the job waiting on the loop until `agc_io_ready`; the job's `on_loop` flag then makes its `expired` and end-of-run paths treat it like an `external` job), `agc_io_close` (only for in-process harnesses, the fuzzer and the C tests: flush the files, then close handles and timers and free the loop; the process guard's release kills children; false while a job is stuck in the OS); resources have a `kind` (native or job); non-Linux builds get stubs; `drain` counts the jobs that are ready when it starts and pops one at a time, so a long jump out of the flush (a `done` half that calls `agc_fail`) loses only the job in hand, not the rest of the batch; jobs readied while it runs wait for the next drain |
| `vm/files.c` | the `File`, `Dir` and `Path` builtins (`agc_file_builtins`, Linux only; `docs/vm/02-reference-behavior.md` §2.8): argument checks in the evaluator's order (for a handle: arguments and timeout, then the lock, then open and mode), host paths (raw `getcwd` bytes read at start-up by `agc_files_init`, `/` when it fails, + `/` collapsing), `malloc`'d `op` requests whose `work` half runs in the libuv pool, Racket's messages (contract forms cut at 256 characters, `strerror_l` in the message locale, the byte string form for invalid UTF-8), `FileHandle` state with its read buffer or its 4096-byte write buffer (Racket's rule: append when it fits, else write pending and new bytes together; flush, close and the end of run write it), the one waiting rule (`probe`: after an `O_NONBLOCK` open, `fstat` plus an `epoll_ctl` probe; regular files, block devices and devices epoll refuses with `EPERM` go to the pool, set blocking; any other probe error, or a failed `agc_poller_open`, is the call's error; pipes, FIFOs, terminals and other pollable devices stay non-blocking on an `agc_poller`: `start` tries `step` on the loop thread, then parks on `poll_io`, an `external` kind, whose poller callback (`ready`) repeats `step`; whole-file calls get there through `agc_io_start_then`'s `more`; `stop` is the `cancel` half, which `cancellable` in `vm/loop.c` calls only in the loop phase; `ready` repeats the step on a hang-up, so a reader that left gives `EPIPE`; a timed-out close drops the bytes it already sent; a close sends the buffer only for a writable state, so closing a read FIFO that still holds read-ahead lines is `ok()`; the end-of-run flush of a polled file is a detached `poll_close_io` job; `close_file` makes the owner-end close job hold the handle as its context, and `closed` stores an error result on the handle, wakes the lock waiters and calls `agc_task_close_done` for the ending task, so `File.close` on a closing handle waits for the lock and returns that result), `private_pipe` refusing, as not a regular file, a path that reopens a pipe the VM made (one open in the VM that is not in `rt->inherited`, the pipes `agc_files_inherited` found at start-up, before libuv and the trace file; reading libuv's signal lock pipe once stole its token and deadlocked the next `uv_signal_*` call with every signal blocked); inherited pipes (`bash <(...)`, a piped stdin through `/dev/stdin`, stdout and stderr through `/dev/stdout`, `/dev/stderr` and `/proc/self/fd/1` and `2`) stay reachable; `names_output_fd` (before the open, in `open_for`) refuses only a path that is an entry of `/proc/self/fd` or `/proc/thread-self/fd` (same directory device and inode; not `/proc/<pid>/task/<tid>/fd`) with the number of the descriptor `vm/output.c` reopened for stdout or stderr. A child run with `--allow-run` can still open `/proc/<VM pid>/fd/N`: the check covers the program's own file calls only. `agc_each_fd` (the `/proc/self/fd` walk, also used by `vm/process.c`) lives here, `owns_st` saying which request frees the state (open, close, or a handle request after its timeout), `Path.join` and `Path.resolve` as pure string code; `File.each_line` (7.2.1h, `lines_step`, a stepper state machine with phases START, OPENED, SCAN, RESUME, CLOSE, CLOSED: it opens the path with `OP_OPEN_READ`, reads one `OP_READ_BLOCK` job at a time into a buffer of `buffer_bytes + 1` bytes made once, with the pending bytes compacted to the front (`compact`) and each read clamped to `buffer_bytes` bytes (`read_more`; the spare byte only lets a read tell a last line of exactly `buffer_bytes` bytes from a longer one), and `scan_line`, shared with `read_line`, finds the next line: a terminator within the first `buffer_bytes` bytes of the pending data, one `\r` stripped before the LF, the last line without a newline at EOF, and `filesystem: line exceeds buffer_bytes` when more than `buffer_bytes` bytes are pending with no terminator; text is checked with `agc_utf8_chars`; the handle is owned with `agc_own(close_file)` like `File.open`; the buffer range check comes first, then the timeout, then the path contract error; a block error is the result and the file is closed with `OP_CLOSE` before it is returned) |
| `vm/duplex.c` | the child channel (25c, service; `docs/vm/10-io-processes.md` §10.4 "As built (25c)"; Linux only, stubs elsewhere): an `agc_duplex` is one bidirectional libuv pipe over a socket end with an `agc_inbuf` (line reads, 1 MiB), at most one reader request and one writer request, a reference count (the owner, each request, the pipe handle and the shutdown request) the `overflow` text and the flags `closed`, `write_closed` and `sent`. `agc_duplex_overflow` (called by `process.c` when stdout or stderr is cut) stores the output-exceeds text and readies a pending reader; a read that finds no complete line then returns that error, now or later, and lines already buffered still come first. The jobs are `external` loop jobs with the call's timeout (`duplex_io`, kind name `channel`): a read parks until a line is in the buffer, a send writes with `agc_stream_write` and parks only when the pipe is full; `request_expired` closes the whole channel (`agc_duplex_shut`), so a timeout ends the channel and nothing else; `ECONNRESET` on a read is the end of input. The parent side is used by `process.c` (`agc_duplex_new` over the parent's socket end, `agc_duplex_read_line`, `agc_duplex_send`, `agc_duplex_close_write`, which ignores a `uv_shutdown` that fails on the spot (`ENOTCONN` when the peer is gone), `agc_duplex_overflow`, `agc_duplex_release`); the child side is `agc_parent_take` (called by `main.c` after `agc_files_init`: takes fd 3 only with `AGENTICA_CHANNEL=3`, a socket or a FIFO opened `O_RDWR` (`F_GETFL`; a one-way FIFO would fail the read start and park `Test.run` for ever), moves it with `F_DUPFD_CLOEXEC`, forgets it in the inherited-file table, removes the variable, registers the duplex as `vm->parent`; the libuv handle is attached on first use), the builtins `Process.parent_read_line` and `Process.parent_send` (a positive timeout, the `vm->parent_locks` pair; `error("process: no parent channel")` without a channel; `process: the channel is in use` only when a request in that direction is already pending, which keeps a test's call from sharing a buffer with `Test.run`'s retry-style request) and the functions `Test.run` uses (`agc_parent_open`, true when the channel exists and is not closed, and `agc_parent_line` and `agc_parent_send`, which park the calling task with `task->retry`, without a timeout) |
| `vm/process.c` | the `Process` builtins (`agc_process_builtins`, Linux only; `docs/vm/10-io-processes.md` §10.4): a GC `agc_process` with the registered `state` resource and two unregistered lock records (`reader`, `writer`) for `agc_handle_wait`; a `malloc`'d `proc` with the `uv_process_t`, three `uv_pipe_t` (real pipes from `uv_pipe` given with `UV_INHERIT_FD`), the stdout buffer and the pending requests, freed when its user count (resource and requests) and handle count (close callbacks) reach zero; requests park on `external` jobs that pipe, write and exit callbacks ready with `agc_io_ready`; stdout is read only while a reader waits, 4 KiB at a time (more only for a bigger `read_bytes`); stderr is forwarded in its read callback; one close path (`shut`: `SIGKILL`, with no `waitpid` and no sleep anywhere in the file; libuv's exit callback `exited` reaps the child and `retire` closes its `uv_process_t`; a failed kill in `Process.close` is `RUNTIME-PROCESS-CLOSE`) for `close`, stream timeouts and the end of run; `Process.close` of a plain child that still runs parks its task on a `REQ_CLOSE` request (an `external` job with a 1 s timer, kept in `waits`, readied by `exited`; `expired` returns `Void`, so a child in uninterruptible sleep is not waited for), while every other close only signals (§10.4 Close); the park is skipped when the kill failed; the per-run guard (a registered resource, `vm->process_guard`): the list of running children and the loop; `agc_processes_stop`, the first step of the one exit path (stop signals are `vm/loop.c`'s, not the guard's), calls `close_children` (once per run: a second call returns at once), which sends the signals and then `await_exits`: `uv_run` ONCE under a 1 s stack timer until the awaited children (kill not failed) have exited, and `unlink_child` clears `proc.g` so a release after the guard is freed never reaches it; the first spawn marks inherited descriptors above 2 close-on-exec (`agc_each_fd`); executable lookup (`PATH` only for a bare name, the working directory for a name with `/`); captured children (`Process.spawn_captured`, `Process.output`, 21a, §10.4 "As built (21a)"): `spawn_child` serves both spawns, `cwd` from `dir`, both pipes read from the spawn on into `out_buf` and `err_kept` held to 1 MiB of capacity (near the limit a chunk goes to the scratch buffer and `keep_scratch` copies what fits; `out_cut`, `err_cut`, then dropped into the scratch buffer), `output` a wait like `wait` (`await_child`), and a close that sends `SIGTERM` and starts the 1 s `grace` timer for `SIGKILL` (`retire` closes the timer and the process handle once the child is gone); the end of the run waits for captured children under one `await_exits` bound before it kills them (a second bound waits for the exits); the child channel (25c, §10.4 "As built (25c)"): `Process.spawn_channel` is `spawn_child` with `channel` true: a `uv_socketpair`, a fourth stdio slot that hands the child end over as fd 3, and `child_env`, which rebuilds the child environment on every spawn (it removes `AGENTICA_CHANNEL`, removes `UV_USE_IO_URING` when `drop_uring_env`, and adds `AGENTICA_CHANNEL=3` for a channel spawn only, as a separate `marker` string the caller frees; `AGC_CHANNEL_ENV` and `AGC_CHANNEL_FD` are in `vm/services.h`); the parent end is an `agc_duplex` (`vm/duplex.c`) in `proc.channel`, and the `agc_process` has a third pair of lock records, `channel.reader` and `channel.writer`; `channel_read_line`, `channel_send` and `channel_close` call the duplex functions with those locks, `shut` closes the channel with the pipes, and `read_available` drains the stdout pipe with non-blocking `read`s (`drain_out`, at most `DRAIN_LIMIT` = 2 MiB per call, into `out_buf` through the same cut rules) before it consumes the pending bytes, holding back an incomplete UTF-8 sequence at the end (`whole_prefix`, up to 3 bytes) unless the stream ended or failed, and takes them out with `agc_inbuf_take`; the trace line of a spawn has `channel=` |
| `vm/stream.c` | what processes and TCP share (`docs/vm/10-io-tls.md` §10.3.1): `agc_inbuf` (one `malloc`'d input buffer with EOF and a sticky read error; `agc_inbuf_room` for libuv's alloc callback, `agc_inbuf_got` for its read callback, `agc_inbuf_ready`, `agc_inbuf_want` for the read size: 4 KiB or what a byte read still needs), `agc_inbuf_take` (drop the first bytes of the pending data and keep `scanned` right), `agc_inbuf_line` (LF in the first 1 MiB + 1 bytes, searched once per byte through `scanned`, CRLF stripped, a final line only at EOF, the read error when bytes without LF end in an error, the caller's texts for too long and end of input; it says when the line was too long so the caller closes) and `agc_inbuf_bytes`, `agc_stream_write` (`uv_try_write`, then one `uv_write` of a `malloc`'d copy in buffers of at most 1 GiB; 0 written, 1 queued, or a libuv error), `agc_new_lock` and `agc_stream_lock` (an unregistered lock record, and the timeout check plus `agc_handle_wait`), and the `network:` timeout texts |
| `vm/tcp.c` | the `TCP` and `TLS` builtins (`agc_tcp_builtins`, Linux only; §10.3.1, TLS in §10.3): one `malloc`'d `net` for a socket or a listener (users: the resource and each request; callbacks: a DNS lookup in flight and one close callback per `tcp_link`, a `malloc`'d `uv_tcp_t` with its `uv_connect_t` that finds the `net` through `owner`), registered when the call starts, so a crash or the in-process harnesses' `agc_io_close` closes it; the VM's own end of the run closes no socket one by one (`_exit` does), and only calls the `goodbye` hook for TLS `close_notify`; requests park on `external` jobs (`park`): connect resolves with `uv_getaddrinfo` and tries each address with a fresh link (`attempt` takes its callback as an argument, so no prototype is needed), listen binds every resolved address on one port (one link per address, chained through `next`; `bind_all` retries a port-0 listen when a later address finds the port taken), accept is one FIFO for all links whose head is marked served by a link's connection callback (`chosen`) and calls `uv_accept` in its `done` half (a failed `uv_accept` closes the listener, since libuv stops watching that link), reads and writes use the `agc_socket` reader and writer locks and `vm/stream.c`; `shut` is the one close (trace `why`), and wakes every waiting request; `no_files` (the fuzzer) makes connect and listen fail with `RUNTIME-INTERNAL` |
| `vm/input.c` | the only stdin reader (`agc_input_*`, status OK, EOF, WAIT or FAILED): one growing buffer in the runtime shared by `gets`, `read`, `read_bytes` and `eof?`; on Linux a pipe, FIFO, terminal or socket stdin is read on the loop (`watch_stdin`: a pipe or terminal reopened through `/proc/self/fd/N` with `O_NONBLOCK` so the inherited description keeps its flags, a socket read with `MSG_DONTWAIT`; an `agc_poller` and an `external` job), any other stdin by one pool job; the job's `done` half appends the bytes and wakes the readers waiting in the input's FIFO, and the builtin re-runs (retry) once data or EOF is in; an EOF read bumps `eof_seq` and each task gets it once (`input_seen`); a `scanned` offset keeps line search linear; U+FFFD decoding of consumed bytes, a pending EOF after a peek; non-Linux keeps a blocking read |
| `vm/output.c` | the writer of stdout and stderr, but not the only one: `vm/process.c` forwards a child's stderr to `err.file` with a blocking `fwrite` (`agc_write`, `agc_output_waiting`, `agc_drain` for `IO.flush`, `agc_flush`; row 7.2.1f, `docs/vm/10-io-scheduler.md` §10.2.2). Per stream an `agc_output` (`vm->rt->out` and `err`) with a 64 KiB ring (`AGC_OUTPUT_BUFFER`) and a FIFO of waiting writers; a print that fits and has nobody ahead of it is copied and returns, otherwise the task keeps a pointer to its text in `task->output` and parks (retry; `agc_output_waiting` tells the builtin to pass no text), the head is woken when its whole text fits (`wake_head`), a print longer than the ring copies in pieces and holds the stream. `agc_output_open` (from `main`, after `agc_input_open`) reopens a pipe, FIFO or terminal through `agc_fd_reopen` (`/proc/self/fd/N`, `O_NONBLOCK`), or duplicates a socket (`F_DUPFD_CLOEXEC`, `send` with `MSG_DONTWAIT`), and writes it from an `agc_poller` (one `external` detached job per writable event, the request holds the stream index); it drains a regular file, a block device or a device epoll refuses (`/dev/null`) by one pool job on the original descriptor; and it leaves the others (read-only descriptor, failed reopen or `dup`, non-Linux) on the blocking `fwrite` of their `FILE`. When stderr is the same file as stdout (`st_dev`, `st_ino`), `err.base` points to the stdout stream and they share one ring and FIFO. A write error sets `failed`, drops the data and the notices, and wakes the waiters; `agc_output_leave` (from `unlink_task`) takes a cancelled waiter out; `agc_output_busy` keeps `flushing()` in `vm/loop.c` waiting while a buffer holds data (it pumps queued notices with force and kicks the writer, since no task runs any more to finish a cut print), and once a stop signal is set it makes one non-blocking write per stream and stops waiting. `advance` always ends with `kick`. The poller's per-event jobs are quiet (`AGC_JOB_QUIET`); the trace has `output_start` and `output_done` lines per run of data. `agc_notice_begin` and `agc_notice_end` (mode `AGC_NOTICE_QUEUED`, `AGC_NOTICE_KEPT` or `AGC_NOTICE_FINAL`) write the text of the VM itself: queued notices (task crash diagnostics, the unobserved summary) join a queue of at most 1 MiB; a kept notice (the diagnostic of a failed run) is queued even when the queue is at its limit that enters the ring ahead of waiting writers, never inside a print that holds the stream; the diagnostic of a failed run is queued as a kept notice after the blocking streams are flushed and before the end-of-run wait (`announce_outcome` in `vm/main.c`), and final notices (the flush warnings, the flush-timeout warning, a write-error diagnostic) are written after it with non-blocking writes, and the rest a stuck pipe will not take is dropped |
| `vm/task.c` | the scheduler (`docs/vm/10-io-scheduler.md` §10.2.1, "As built"): `agc_vm_run` (setjmp, FIFO run queue, one turn per task, `uv_run` NOWAIT after each turn and ONCE when idle, the stall check), `agc_task_wake`, `agc_task_park`, task cancellation (20b, `docs/vm/10-io-scheduler.md` §10.2.1: each task has `parent` and a `children` list; a task that ends moves its running children to its parent; `agc_task_cancel` cancels a task and its descendants, children first: it leaves the run queue, detaches its job, leaves lock, await and stdin FIFOs and ends; the running task only gets `cancelled` and `vm->yield`, so it stops after the current builtin and the scheduler ends it; `Task.await` on a cancelled task halts with `RUNTIME-TASK-CANCELLED` at the call; `vm/tests/task_cancel_test.c` runs hand-built bytecode with test builtins on the real scheduler), task crashes (phase 24, `docs/vm/10-io-scheduler.md` §10.2.1, "Crashes": one `setjmp` per turn in `run_turn`, `fatal` picks what still ends the run (`main`, an exit, `RUNTIME-STEP-LIMIT`, `RUNTIME-INTERNAL`), `crash` stores and prints the crash, unlinks the task, cancels its descendants and calls `finish_task`; the unobserved summary when `main` returns), handle ownership (24b: `finish_task` is the one end of every task, whether it returns, crashes or is cancelled, and it first calls `agc_close_owned(vm, t)`, which closes the handles on the task's own `owned` list, each by its resource's `close`; `agc_own` in `vm/loop.c` puts a handle on the list of `vm->task`, `agc_unregister` takes it off, `agc_hand_over` moves it; nothing is given to the parent; a regular-file (pool) close job counts on the ending task in `closing`, a polled FIFO or pipe close does not, and `agc_task_join` keeps parking awaiters, new ones too, until `agc_task_close_done` has run for each counted job), and the `Task` builtins (`agc_task_builtins`: spawn with a per-task `Random` split (`agc_task_spawn_seeded`) and no move, `Task.spawn_owning` through `agc_task_spawn_owning` (the port function that also `HttpWire.spawn` calls: it fails with `RUNTIME-HANDLE-NOT-OWNED` at the handle argument before it makes the task, then spawns, seeds and hands the handle over), two await entries with a FIFO of waiters and retry (`agc_task_join`: clear `awaiting`, or enqueue on the target's waiters and park with retry; `Test.run` waits with it too; `Task.await` halts with `RUNTIME-TASK-CRASHED` or `RUNTIME-TASK-CANCELLED`, `Task.await_result`, picked by lowering for a `Result`, returns the error), sleep as a timer job, `sleep(0)` and fuzz sleeps yield, `pending_count` from `pending_tasks`, tasks made minus tasks done minus `main`: it counts ready, running and parked tasks, not tasks that returned or crashed (even unawaited ones), `unobserved_crash`); `agc_task_spawn` (shared by `Task.spawn` and `Test.run`; the child inherits its parent's `test`), `agc_task_observe`; a crash keeps `crash_code`, `crash_message` and `crash_span` for `Test.run`, and `finish_task` sets `left_children` when a task ends with running children |
| `vm/channel.c` | the `Channel` builtins (`agc_channel_builtins`, `docs/future/27-iteration-and-concurrency.md` §27.2, `docs/vm/10-io-scheduler.md` §10.2.2, "Channel waits"; core layer): a GC `agc_channel` with a ring (at most 8 slots at first, doubling up to the capacity, one turn-cost unit per slot copied; each slot holds the value and its send sequence number, so a value handed back by a cancelled receiver is inserted by it and FIFO holds), two FIFOs of waiting tasks through `wait_next`, and counters for the reserved values and slots. A call that must wait parks with retry on `agc_wait_io`, the lock wait's timer-only job kind (the I/O trace skips its `done` and `timeout` lines; `start` and `detach` print `kind=lock`); the deadline lives in the task (`channel.deadline`) and a retry is told by `channel.channel == c`. A value for a waiting receiver is reserved in the task (`channel.value`), a freed slot for the head sender (`channel.reserved`; `offer_slot` makes the offer after a `recv` and after a woken sender hands its value to a receiver); the pops skip tasks that are no longer parked (their timer won), and a woken waiter with a reservation does not search the FIFO again. `agc_channel_leave` (called from `unlink_task`) takes a cancelled waiter out and hands its reservation on. Arguments are checked before any wait state changes; `Channel.new` and the timeouts fail at their argument (`span + 1 + index`; the receiver is argument 0). No new opcode: the builtins are appended to the table, and `src/lower.rkt` lists their names. |
| `vm/testing.c` | the `Test` builtins (`agc_test_builtins`, `docs/future/36-unit-tests.md` §36.3, §36.6, as built in `docs/roadmap/25-unit-tests.md` 25a): `Test.test` makes an `agc_test_case` (tag `AGC_T_TEST`: name, block, call span); the assertions return `ok()` or `error(text)` and record their first failure (`agc_test_note`) on `vm->task->test`, the test the task was spawned under; `Test.run` fails with `RUNTIME-TEST-RUN` when the calling task is not `main` (`vm->task != vm->main`: a test or any task `main` spawned; there is no "served once" state), checks the names, then the arguments (`--agentica-test list|run`; run directly it prints `run this file with agentica test` and exits 2) and the channel (`agc_parent_open`; none is `RUNTIME-TEST-RUN`). It serves `list` (all `test` records and `ready` built by `list_lines` in one pass over an array of lines and sent as one batch, exit 0) or `run`, a retry builtin whose state (`agc_test_run`) lives on the calling task: it reads an index line with `agc_parent_line` (`vm/duplex.c`; the program's stdin and stdout are untouched, there is no token), starts the test with `agc_task_spawn` and a seed from the run's seed and the name, waits for it with `agc_task_join`, and on wake builds the record (crash, first note, the block's error, `left_children`, an unobserved crash of the test's tasks), cancels the test's leftover tasks (now the caller's children), observes every crash of the test's tasks, then `deliver` flushes stdout with `agc_drain` and sends the record with `agc_parent_send` before the next index is read; at the end of the channel and after a list it ends the run like a return from `main` (`agc_report_unobserved` in `vm/task.c`: the unobserved summary, exit 1); an index line that is not a plain index, or that cannot be read as a line (`AGC_INPUT_FAILED`: invalid UTF-8), is a `RUNTIME-BDD-INFRA` fail record and exit 1 (a channel that is already shut just exits 1) |
| `vm/equal.c` | `agc_equal`, the deep compare of §25.4 pulled forward for `Test.eq`: one explicit stack of value pairs, one turn unit per pair, Strings through `agc_same_string` (also used by `EQ` and the map key compare), Floats by IEEE 754, maps by key in any order, a `Json` by its canonical `agc_json_encode` text, `RUNTIME-INTERNAL` for values with no equality; meant for `==` (15d) and BDD (25b) too |
| `vm/diag.c` | the plain, `--ai` and `--json` diagnostic formats, the same formats as `src/diagnostic.rkt`; only the code must match; a task crash adds ` in a task` (plain, `--ai`) or `"task":true` (`--json`); `agc_crash_text` and the unobserved summary line (`agc_print_unobserved`) |
| `vm/trace.h`, `vm/trace.c` | VM tracing (`AGENTICA_VM_TRACE`, `docs/future/24-logging.md` §24.4, as built in `docs/vm/08-loader-and-cli.md` §9): the `agc_trace` struct, category bits, `AGC_TRACE_ON` and `AGC_TRACE`; `agc_trace_parse`, `agc_trace_message`, `agc_trace_format` (for the C test) and `agc_trace_emit` (one 512-byte stack line, one `write(2)`) |
| `vm/fuzz.c`, `vm/fuzz_main.c` | `agc_fuzz_one` and the mutation driver (not in the release binary) |
| `vm/tests/loader_test.c` | one assert per loader rule (`type_tables(which)` builds one malformed Types section per case) |
| `vm/tests/list_test.c` | the list API at the lengths around the 32-way boundaries (0 to 65, 1,023 to 1,057, 32,768 to 32,801, about a million): the shape of the trie (root NULL up to 32 items, shift at the boundaries, full leaves, no empty branch), builder and repeated `append` (up to 33,000 items) agree, every `get`, cursors from several starts, `agc_list_to_array`, persistence of old versions after `append` and `set` (also 60-step chains of `set`), `slice` and `concat` at the boundaries (a `take` past the trie shares its root), the `agc_debug` form, and 5,000 kept versions of an append-built list |
| `vm/tests/map_test.c` | HAMT: 20,000 keys, order, replacement, persistence, full hash collisions, shared 60-bit prefixes, delete (order, persistence, collision nodes, down to an empty map), a depth-1,000,000 nested map printed |
| `vm/tests/random_test.c` | the generator: a seed repeats, seeds differ, `Random.float` and `Random.int` bounds (full Int range too), rough uniformity, `low > high` |
| `vm/tests/float_text_test.c` | Float text against values printed by Racket (`docs/vm/02-reference-behavior.md` §2.2) |
| `vm/tests/string_test.c` | UTF-8 helpers over every code point, case mapping (special cases, final sigma), KMP search on repetitive text, Int and Float parsing edge cases with the bits Racket gives |
| `vm/tests/json_test.c` | the sign of zero (`-0.0`, `-1e-500`), escapes, key order and dedupe on 5,000 keys, depth-1,000,000 arrays and objects parsed and encoded, a deep list through `JSON.from` (100,000 under ASan's `AGC_NO_GC`, 1,000 under `AGC_GC_STRESS`); parse statuses and number edge cases live in the `json-*` fixtures |
| `vm/tests/budget_test.c` | under `AGC_NO_GC`, an allocation past `agc_set_alloc_limit` longjmps once, and after `agc_release_all` no limit is set |
| `vm/tests/text_test.c` | write-escape range lookup, String debug forms (`docs/vm/02-reference-behavior.md` §2.3), list text, a depth-1,000,000 list and a depth-1,000,000 enum/struct chain (hand-built `agc_program` tables): deep enough to overflow an 8 MB C stack if the printer recursed; 1,000 under `AGC_GC_STRESS`, where the point is GC safety while printing |
| `vm/third_party/bdwgc` | Boehm GC submodule, pinned to a release tag |
| `vm/tests/task_cancel_test.c` | `agc_task_cancel` (20b; also a running task that cancels itself after it took a handle, as a handler that closes its own server would, whose handle is closed at its end) on the real scheduler: hand-built bytecode programs (with a one-line source and a span table, since a crash prints its diagnostic) whose builtin table adds test builtins (mark, cancel, a check callback, a handle operation on an external job, an `HttpWire.exchange` wrapper); every cancel state, a job whose deadline timer fired before the cancel (a 200 ms job and a 300 ms block, so the first poll never sees the timer), `RUNTIME-TASK-CANCELLED` at the await span (a task that awaits a cancelled task now crashes, phase 24), the move of children, the `HttpClient` pool against a port-0 socket that never answers TLS, and a pool job with a `more` step (`agc_io_start_then`): cancelled while its work runs, the `cancel` half is not called and the job ends through `done`; cancelled in its loop phase, it is dropped and its poller closes the descriptor; and a writer cancelled while it waits in the FIFO of a full stdout buffer (a pipe filled beforehand): the next one keeps its place and the bytes that arrive are the earlier ones and the next writer's, never the cancelled one's. 17a adds its `Task.map` cases here |
| `vm/tests/channel_test.c` | the `Channel` builtins called directly with hand-made tasks (no bytecode): ring growth and its turn cost, wrap-around and the capacity; receivers and senders served in order; a woken receiver that is cancelled hands its value to the next one, or back to the head of the ring (two cancelled receivers return their values in send order, whichever goes first); a reserved send slot handed to the next sender or freed, and a woken sender that hands its value to a waiting receiver passing its slot on; `close` with a value reserved for a woken receiver (`closed?` stays false until it is taken, or the value comes back when the receiver is cancelled) and with a reserved send slot (the send returns the closed error); a timer that fires before a reservation reaches the waiter, and a reservation that comes first. The channel-waiter cancel case with the real scheduler is in `task_cancel_test.c`. |
| `vm/tests/output_test.c` | `vm/output.c` with hand-made tasks and a pipe: the order of small prints, writers that wait not being passed by later ones, the ring wrapping, `agc_drain` waiting for an empty buffer and failing when the reader left, a head that leaves handing on to the next, a file drained by the pool, `/dev/null`, the blocking write on a read-only descriptor, stdout and stderr on one target sharing the buffer, a notice that waits for room and keeps its text, a notice that does not enter a long print, a leaving long print that lets a queued notice and the next writer through, the end of run moving a notice held by a cut print, a record that starts a line after a cut print, the notice queue limit and a kept notice, and final notices (written straight, or dropped when the pipe is full) |
| `vm/tests/each_line_test.c` | what bytecode cannot reach in the `File.each_line` stepper, driven by hand: the buffer argument errors with the span of that argument and no stepper installed, a FIFO read that times out and closes its descriptor, and a cancelled reader whose descriptor is closed at once (24b: the reader owns its file like any task; the test sets `in_turn` while the open finishes so `agc_own` records the owner); counts descriptors through `agc_each_fd`. The rest is in the `file-each-line*` goldens and `tests/vm-file-lines-test.rkt` |
| `vm/tests/trace_test.c` | the trace escaper and line buffer: numbers, empty and special text values, invalid UTF-8 bytes as `\u00XX`, lines cut at 512 bytes on a UTF-8 or escape boundary, the unknown-category warning |
| `tests/vm-tcp-test.rkt` | the VM against Node peers (`tests/fixtures/tcp-peer.js`): a client reading fragments, EOF, a reset, a 1 MiB + 1 line, a silent peer (timeout) and a refused port; a VM server with two concurrent Node clients; `main` returning while tasks wait on a read, an accept and a full send buffer, with the `io` trace ending in `end code=0 signal=0` and the peer seeing the close (the exit path closes no socket itself; the OS does at `_exit`); a crashed task's and a returned task's connections, which a task closes when it ends (24b), seen closing by the peer. Uses `compile-file`, `run-process` and `vm-file` from `tests/vm-diff-common.rkt`, so `AGENTICA_VM_BINARY` picks the sanitizer or GC-stress binary |
| `tests/vm-trace-test.rkt` | traced runs (`all`, to a file) give the same exit code, stdout and stderr as untraced runs; every line matches the format; unknown category and unopenable file lines; `gc` lines from `map-large` (skipped on a sanitizer build); a VM started with stderr or stdout closed; a connection task of `http-server-close` traced as `parent=group:N` (N the group's owner); skips on a `TRACE=0` VM |
| `tests/vm-stop-test.rkt` | the one exit path under stop signals, with `tests/fixtures/stop-peer.py` (Python): `SIGTERM`, `SIGINT` and `SIGHUP` kill the children and write the buffered file, and the VM dies by the signal; a second signal before the children are stopped waits for them; a flush into a FIFO the peer filled waits on the first signal and ends on the second; a driven VM whose driver died does not flush; a signal while stdout is full ends the run with no diagnostic; a signal with a stdout nobody reads ends the run long before the flush limit; Ctrl-C to the CLI's process group stops a captured child that ignores `INT` and `TERM` and still writes the file; a stop signal inherited as ignored (`nohup`, a background job) stays ignored. The tests that send `SIGHUP` or `SIGINT` start the VM through the peer's `launch default` mode, so their result does not depend on how the test run was started |
| `tests/vm-channel-test.rkt` | a socket handed to a worker over a channel: the VM accepts six connections from a Python peer (`tests/fixtures/channel-peer.py`, port 0), sends each socket into a `Channel[Socket]` read by three worker tasks, closes the channel, and the workers' loops end |
| `tests/vm-stdout-test.rkt` | stdout and stderr on the loop, with `tests/fixtures/stdout-peer.py` (Python, which starts the VM on pipes, a socket pair or a pty it reads late, slowly or never, or a pipe it closes): a stuck pipe while a timer task keeps ticking and the run ends once the reader drains; two tasks printing long lines with no interleaving and in order; a print longer than the ring next to short prints; the end of run draining within the flush limit; a reader that never reads (`--flush-timeout`, the warning, also with stderr on the same pipe, and then no warning in the data); a socket as stdout on the loop; `puts` and `IO.warn` on one pipe and on one pty in the order of the calls; `IO.flush` waiting for the reader; a task crash diagnostic that waits for a full stderr and arrives whole; a `Result.unwrap!` text over 128 KiB reaching a stderr file and a slow stderr pipe; a print cut by the end of the run not holding a queued notice or the exit; a protocol record after a cut print starting a line; `File` on `/dev/stdout` and `/dev/stderr` as pipes; the program output before the diagnostic on blocking streams; a regular file drained by the pool while a child is stopped at the end of the run; a reader that went away (`RUNTIME-INTERNAL`, exit 1); a crashed parent whose waiting child leaves the FIFO with nothing partial written |
| `tests/vm-test-protocol-test.rkt` | a Python peer (`tests/fixtures/test-protocol-peer.py`, with `tests/fixtures/child_channel.py`, which starts the VM with a socket pair as fd 3) plays the runner of a test file (`tests/fixtures/test-protocol-peer.agc`): the list records, one index at a time with the record read before the stdout of that test (`read_available` order), the test's own stdin, a record-shaped line printed as plain output, a partial line, and the `RUNTIME-TEST-RUN` of a run without a channel |
| `tests/vm-child-channel-test.rkt` | the child channel on its own (`tests/fixtures/child-channel.agc`, `child-channel-peer.py`): the VM as the child of a Python parent (lines in pieces, a 300 KB line, the end of input, a timeout that closes the channel, no channel, a marker without a socket and a socket without the marker, a grandchild that gets neither) and the VM as the parent of a Python child (send, read, `read_available` order, a half close, a read timeout and a stalled send that close only the channel, a line over 1 MiB, a child with no channel, an uncaptured child, a UTF-8 character split between two `read_available` calls, `channel_close` after the child exited, a stalled send that keeps sending until one times out) and fd 3 given to the VM as a regular file, a character device or a write-only FIFO (refused, left as it was) or as a read-write FIFO (taken) |
| `tests/vm-file-lines-test.rkt` | `File.each_line`: a 10 MB file of short lines streams in order in about size over buffer pool jobs (the I/O trace) with bounded peak memory; `--max-steps` ends a long file with `RUNTIME-STEP-LIMIT`; with a Python FIFO peer (`tests/fixtures/lines-peer.py`): a FIFO fed in pieces with a CRLF split across reads and a last line without a newline, a stalled FIFO that times out one read (1200 ms) and closes the descriptor, `File.close` of a read FIFO that holds read-ahead lines (and an early stop on it) is `ok()`, and a crash that cancels a parked reader and frees its descriptor (the program polls `/proc/self/fd` with `Task.sleep(10)`, bounded at 5 s, and a channel orders the crash after the fd appears) |
| `vm/tests/http_parse_test.c` | the §10.6 hostile list on the request and response head adapter, framing, and the body decoder (each body fed whole and byte by byte) |
| `vm/tests/loop_test.c` | the registry (slots after removals), a completed job, a timed-out job dropped once its work ends, and `agc_io_close` freeing the loop, or returning false while a job is stuck |
| `vm/tests/process_test.c` | `Process.spawn` called as a C function, then `agc_io_close` with the registry in an order that releases the process guard before its process (the guard is freed first; run under `make vm-test SANITIZE=1` it caught a use after free) |
| `vm/third_party/libuv` | libuv submodule (MIT), pinned to tag v1.53.0; its Linux sources build into `$(VM_BUILD)/libuv.a` |
| `vm/third_party/openssl` | OpenSSL submodule (Apache-2.0), shallow, pinned to tag `openssl-3.5.9`; with `AGENTICA_OPENSSL=vendored` (the release) built static on Linux per build mode into `$(VM_BUILD)/openssl/` (`libssl.a`, `libcrypto.a`; `docs/vm/10-dependencies-and-platforms.md` §10.0); the default `AGENTICA_OPENSSL=system` links the system OpenSSL 3 instead |
| `vm/net.h` | tcp.c's connection object for other C modules (`agc_conn`, `docs/vm/10-io-http.md` §10.7.1): `agc_conn_open` (DNS, connect, TLS with a borrowed `agc_tls_config`) with a watch callback that runs on every state change, `agc_conn_send`/`agc_conn_sent`, `agc_conn_input`/`agc_conn_read` (the `agc_inbuf`), `agc_conn_ready`/`agc_conn_failed`/`agc_conn_error`, `agc_conn_shut` and `agc_conn_release`; also `agc_tls_load_error` |
| `vm/http_parse.h`, `vm/http_pico.c`, `vm/http_body.c` | the HTTP head adapter and body decoder (§10.6, §10.6.1): limits as constants, `agc_http_error` with its status and text, `agc_http_parse_request_head`/`_response_head` (our pre-scan and start-line checks, then picohttpparser, then token, value, obs-fold, Host and status checks), `agc_http_framing`, and the body decoder (`agc_http_body_init/feed/end/free`: Content-Length, chunked with saturating sizes and checked trailers, close-delimited, one `malloc`'d buffer within the limit). No recursion |
| `vm/http_fields.h`, `vm/http_fields.c` | what the client and the server share (`agc_http_closes` on a parsed head and `agc_http_list_closes` on a `List[Header]` use one token check): a growable byte buffer (`agc_http_put`), the header writer with its checks and the managed names (`agc_http_put_headers`, which returns a reason without the `http: ` prefix), the kept header fields (`agc_http_fields`, names lowercased) and their `List[Header]` (`agc_http_header_list`), `agc_http_closes` and `agc_http_error_result` |
| `vm/http_server.c` | `HttpWire.read_request`, `write_response`, `server`, `accept`, `spawn`, `close_server`, `wait` and `local_port` (`agc_http_server_builtins`, Linux only, a stub table elsewhere; §10.7): a `reader` state machine on an `agc_conn` watch (first byte, head, body, answer) that applies the order of `docs/vm/10-io-http.md` §10.7.3 (parse errors, `Upgrade` 501, `Expect` 417, the `Content-Length` limit 413, then `100 Continue`, then the body and its UTF-8 check), writes every error answer itself, then lingers (`linger`: half-close and drop input until the peer closes or the deadline, so no reset loses the answer); the deadline is `first_byte_timeout_ms` until the first byte, then `agc_io_extend` restarts it with `timeout_ms`; a finished request pauses reading (`agc_conn_pause`) until the next `read_request`, so pipelined bytes cannot pile up while a response is written. `write_response` takes the request and the response, builds the whole response first (status 200..599, no body on 204 and 304 or for `HEAD`, `Content-Length` and `Transfer-Encoding` managed, a `Date` header; when the request or response says `Connection: close` (`agc_http_list_closes`), the handler's `Connection` headers are dropped for one `Connection: close`), returns `http: invalid response: ...` without writing when it is bad, else `ok(keep)`, and lingers before a close. The `HttpServer` holds a `server` (listener, open count, `max`, waiting `accept` and `wait` jobs poked by the listener watch, a freed slot and the close) and a group node (`agc_task_group`) in which `server` starts `std/http`'s accept loop: `spawn` starts the connection task under it with `agc_task_spawn_owning` (the hand-off of `Task.spawn_owning`: the socket goes to the connection task), marks it `hidden` and sets its `end` hook, which only frees the slot (the one close path, `finish_task`, closes the socket first); `close_server` (also the owned close) closes the listener, wakes the waiters and cancels the group (`agc_task_cancel`: each cancelled task closes the handles it owns as it ends; the closes may nest, which is safe because each takes the head of its own task's list). Every wait is an `external` job with a `cancel` half |
| `vm/http_client.c` | `HttpWire.client`, `exchange` and `close_client` (`agc_http_builtins`, Linux only, a stub table elsewhere; §10.7.1): a `malloc`'d `client` per handle with its origins (idle connections, open slots, a FIFO of waiting exchanges), one idle timer and a lazily built `agc_tls_config` (a pool job on the first HTTPS call); each `exchange` parks on an `external` job and moves through config, wait, connect and exchange phases on `agc_conn` watches; a `runnable` queue (`schedule`/`drain`) and callbacks stored in the client avoid both static prototypes and call cycles. GC values (the `HttpResponse`) are built only in `done`. Its `cancel` half (20b): an exchange of a cancelled task that has not sent its request leaves the queue or closes its connection, so its slot passes to the next waiter; one that has sent it runs to its end and is not pooled. Its `goodbye` (`client_goodbye`) sends one TLS close_notify on every idle and active connection when the run ends |
| `vm/tls.h`, `vm/tls_openssl.c` | the TLS adapter (`docs/vm/10-io-tls.md` §10.3): our own types (`agc_tls_config`, `agc_tls`, status OK, WANT_READ, WANT_WRITE, CLOSED or ERROR, `agc_tls_error`, `agc_tls_failure` with code, `errno` and a short detail); `vm/tls_openssl.c` is the only file that includes OpenSSL: init with `OPENSSL_INIT_NO_LOAD_CONFIG \| OPENSSL_INIT_NO_ATEXIT`, TLS 1.2 and security level 2, trust (`SSL_CERT_FILE` or the first readable bundle of a fixed list, `SSL_CERT_DIR` or none; a non-empty `ca_file` replaces them), SNI and `SSL_set1_host` or `X509_VERIFY_PARAM_set1_ip_asc`, two memory BIOs per session, error-queue draining into our codes; stubs that fail with "TLS needs Linux" elsewhere |
| `vm/tests/tls_test.c` | two adapters in memory: handshakes with tiny record slices, a 100,000-byte transfer, `close_notify` and raw EOF, every verify error, EOF and a plain HTTP request during the handshake, the load errors (`ENOENT`, bad certificate, bad key, mismatch, bad CA) |
| `tests/vm-tls-test.rkt` | the VM against independent peers (`tests/fixtures/tls-peer.js`, `tests/fixtures/tls-peer.py`, certificates in `tests/fixtures/tls/` from `make-certs.sh`): a client against Node servers (one-byte records, abrupt EOF, a reset, 100,000-byte lines, the 1 MiB limit, a silent peer, wrong host, expired, self-signed, TLS 1.0/1.1 only, plain text, a stalled handshake), system trust through `SSL_CERT_FILE`, a Python TLS 1.2 server, a Python HTTPS server that sees `close_notify` on an idle and an active `HttpClient` connection when `main` returns (`client_goodbye`), a VM server with two Node clients (TLS 1.3 and 1.2), a Python client and a client that does not trust it; VM programs that are their own peers for handshake errors on both sides, timeouts and a pending handshake, and the end of a run with TLS work pending (`tls` trace); every case runs once (no step sweep), in about 5 s; needs Node and Python 3 in CI |
| `vm/third_party/yyjson` | yyjson submodule (MIT), pinned to tag 0.13.0; only its reader is built, into `$(VM_BUILD)/yyjson.o` |
| `vm/third_party/picohttpparser` | picohttpparser submodule (MIT or Perl, dual; the MIT notice is at the top of `picohttpparser.h`), pinned to tag v1.4; `picohttpparser.c` is built like yyjson, into `$(VM_BUILD)/picohttpparser.o`, and only `vm/http_pico.c` includes its header |
| `tests/vm-diff-common.rkt`, `tests/vm-diff-{1..8}-test.rkt`, `tests/fixtures/vm/` | golden tests (`<name>.expected` next to each fixture, `make goldens` rewrites them from the VM), split into eight shards (`heavy-fixtures` pins the costly fixtures to a shard, the rest cycle through shards 1 to 7; shard 8 runs only the CLI and VM-only tests); every top-level `*.agc` is a program, and modules they import live in `tests/fixtures/vm/lib/` (`imports.agc`, `linked.agc`) or, for `pkg/`, in `tests/fixtures/vm/agc_libs/` (`linked.agc`); `std-queue.agc` imports `std/queue`; `doc-comments.agc` has `##` docs on every kind of declaration and shows the VM runs them unchanged |
| `tests/bytecode-test.rkt` | step merging, which returns become `TAIL_CALL`, `LOWER-UNSUPPORTED`, opcode sync, `compile` exit codes |

## Which layer

`vm/*.c` has three layers and a driver (`docs/vm/15-layers.md` §15). A file includes the header of its layer, and `make vm-layers` keeps the direction. A new `vm/*.c` file goes in `VM_SRC` and in one list of `vm/tools/check-layers.sh`.

- **Core** (`core.h`): values, maps, text, the Json value, the interpreter, the scheduler, the loop, stdin, the loader, core builtins, diagnostics, tracing. It never includes or links a service.
- **Services** (`services.h`; `net.h` and `http_fields.h` include it): strings, numbers, JSON, files, streams, processes, TCP, HTTP, `Test`. They reach the core through the port in `port.h` (park and wake a task, jobs with a timeout, register and close a handle, spawn and cancel, fail and charge) and the value API in `value.h`, never `core.h`.
- **Adapters** (`tls.h`, `http_parse.h`): TLS over OpenSSL and the HTTP head and body parsers. They use their library and, from `value.h`, only the memory functions.
- **Driver** (`main.c`, `builtin_tables.c`, `fuzz*.c`): wires the layers and includes `core.h` and `services.h`.

Where a declaration goes: a type or function that values and services both need goes in `value.h`; one a service calls to wait, do I/O or own a handle goes in `port.h` (check a new one against `docs/vm/14-core-invariants.md`); one only the core and the driver call goes in `core.h`; a service's export goes in `services.h`. A `vm/tests/*.c` file includes what it uses. Third-party headers stay in their place: `gc.h` in `value.c`, `uv.h` in `loop.c` and the stream services, OpenSSL in `tls_openssl.c`, picohttpparser in `http_pico.c`, `yyjson.h` in `json.c`.

## Commands

```sh
git submodule update --init          # fetch bdwgc, yyjson, libuv, picohttpparser and openssl after a clone or a bump
make vm                              # dist/agentica-vm (Linux: the system libgc and OpenSSL 3 from pkg-config, dynamic: Debian libgc-dev libssl-dev pkg-config)
make vm AGENTICA_GC=vendored         # libgc from the submodule (extra/gc.c) instead, static; the release, the GC-stress build and non-Linux hosts build this way
make vm AGENTICA_OPENSSL=vendored    # OpenSSL from the submodule instead, static, built once per mode (needs Perl, a few minutes the first time); the release builds this way
make vm-openssl                      # AGENTICA_OPENSSL=vendored: only build/vm/<mode>/openssl/libssl.a and libcrypto.a; AGENTICA_OPENSSL=system: check pkg-config and the version (3.0 or newer)
make -s vm-openssl-key AGENTICA_OPENSSL=vendored   # the OpenSSL build key (Configure and make lines, compiler, version, commit); CI caches by its hash
make vm-third-party                  # only libgc (the vendored gc.o, or the system libgc check), yyjson, picohttpparser and libuv for this mode
make -s vm-third-party-key           # their build key (includes a libgc=system|vendored line; compile lines, compiler, submodule commits and local diffs)
make vm-test                         # C tests: every vm/tests/<name>_test.c in VM_TESTS
make vm-layers                       # the layer check ("Which layer"): each vm/*.h compiles alone, include and link rules, self-test; Linux, needs rg and nm
make vm CCACHE=                      # without ccache (used when installed and its cache dir is writable)
make vm SANITIZE=1 && make vm-test SANITIZE=1   # clang ASan+UBSan, no GC (calloc, never free)
make vm vm-test TRACE=0              # trace points compiled out (still type-checked); --version says "trace off"
AGENTICA_VM_TRACE=all AGENTICA_VM_TRACE_FILE=./t.trace dist/agentica-vm -- prog.agcb   # sched,io,proc,tls,loader,gc
make vm-fuzz                         # compile fixtures, mutate, run accepted mutants
FUZZ_SEED=7 make vm-fuzz SANITIZE=1 FUZZ_RUNS=1000000   # another sequence; the fuzz.yml workflow (run by hand) picks a random seed
make vm-gc-stress                    # GC_STRESS=1 build (collect every 64 allocations), vm-test and the golden tests; JOBS=n sets the test workers
make vm-latency                      # tests/vm-latency-test.rkt alone (see Gotchas, Tasks)
make goldens                         # rewrite tests/fixtures/vm/**/*.expected from the VM; review the diff
make vm-lint CLANG_TIDY=path        # clang-tidy 19+ over vm/*.c and vm/tests/*.c (release, sanitizer, GC stress); any warning fails
make vm-unicode                      # regenerate vm/unicode_data.c with vm/tools/gen-unicode.rkt (~55 s; use Racket CS 9.3, the CI version; CI checks it is committed)
AGENTICA_REQUIRE_VM=1 raco test -j 4 tests/vm-diff-*-test.rkt tests/bytecode-test.rkt
racket src/main.rkt compile prog.agc -o prog.agcb && dist/agentica-vm -- prog.agcb
racket src/main.rkt --dump-ir prog.agc
racket src/main.rkt prog.agc         # front end + VM in one step (the default); AGENTICA_VM=path picks the binary
```

- CI runs `vm-sanitizers` (`make vm-lint`, `make vm-layers`, ASan diff and bytecode tests, `make vm-fuzz`,
  `make vm-gc-stress`) only when a pull request (never a `master` push) touches the VM paths listed
  in the `changes` job of `.github/workflows/ci.yml`; the list and the other
  jobs are in `references/ci.md`. A new VM source or test file outside those
  paths must be added there.
- `agentica file.agc` runs on the VM (Linux only for now,
  `docs/vm/08-loader-and-cli.md` §9): `src/main.rkt` lowers the checked
  program; a `LOWER-UNSUPPORTED` is printed like any diagnostic, exit 1.
  Every catalog implementation is in `vm-builtins` in `src/lower.rkt`
  (`tests/bytecode-test.rkt` checks it), so no builtin reaches it today.
  `agentica test` runs on the VM: `src/bdd-driver.rkt` compiles
  the step program and `std/test/runner` and starts the runner VM with
  `--driver-pid` (see `references/stages.md`).
  Otherwise it writes `agentica-<hex>.agcb` with `#:exists 'error #:permissions #o600`
  in the temp directory and runs the VM with the hidden `--driver-pid PID`
  flag. The VM then deletes its input right after reading it; on Linux it
  first resets `SIGTERM` to its default, sets `PR_SET_PDEATHSIG` to
  `SIGTERM` and exits 2 when `getppid()` is not `PID`. On a break the
  driver (`stop-vm #:interrupted? #t`, after `call-noting-break` in
  `src/vm-launch.rkt`) first waits up to 2 s, since a terminal's Ctrl-C
  reached the VM too and an early `SIGTERM` would be its second signal,
  then sends `SIGTERM` (libc `kill` through the FFI), waits up to 2 s, then
  `SIGKILL`; on other exits it sends `SIGTERM` at once.
  The driver deletes the file too (VM never ran, failed early, break), and
  copies stdin/stdout/stderr through pipes only when they are not file
  streams. The VM is found (`find-vm` in `src/vm-launch.rkt`) by `AGENTICA_VM`, else `dist/` of the checkout
  (module source path), else next to a `raco exe` executable (the release
  archive has it in `bin/`); no `define-runtime-path`, since `raco
  distribute` would copy the VM. A missing VM exits 2, never a silent
  fallback. `--max-steps`, `--seed`, `--allow-run`, `--ai` and `--json`
  pass through; add new options to the pass-through list in `src/main.rkt`
  as the VM gains them. A new builtin goes into `vm-builtins` with its C
  implementation.
  `tests/vm-diff-8-test.rkt` checks the CLI against the goldens (with
  `TMPDIR` and `AGENTICA_VM` set, checking no `.agcb` is left), that the
  removed `--vm` and `--legacy-eval` flags are unknown, a missing VM, runs it once in-process to cover
  the pipe path, and checks `--driver-pid`.

- Each mode compiles `vm/*.c`, `vm/tests/*.c` and the drivers once into
  `$(VM_BUILD)/obj/` with `-MMD -MP` (dependency files beside the objects),
  and every binary links from them (`VM_LINK`); a new `vm/*.c` file goes
  in `VM_SRC` only. `$(VM_BUILD)/obj-flags` recompiles the mode when the
  compile line or the compiler's `--version` changes; `tls_openssl.o` also
  follows the OpenSSL stamp. Compiles run through `$(CCACHE)`, the vendored
  OpenSSL too, but not its key. It is found on `PATH` and used only when
  its cache dir (`ccache -k cache_dir`, or `$CCACHE_DIR`/`~/.ccache` for a
  ccache without `-k`) or its nearest existing parent is writable; the
  check creates nothing. `CCACHE=` turns it off (use it when a ccache
  setup fails). `CCACHE_BASEDIR` is the checkout, and the `-g` modes add
  `-fdebug-prefix-map=$(CURDIR)=.` (`DEBUG_MAP`) to the VM, third-party and
  vendored OpenSSL compiles but not to the stamps or the OpenSSL key, so
  worktrees share hits and debug info names `.`. From a checkout reached
  through a symlink, `$(PWD)` (the path gcc and ccache see) is mapped too.
  Third-party `-g` objects built earlier or restored from the CI cache
  keep their absolute paths until their key changes. A read-only ccache
  (`CCACHE_READONLY`, or a cache dir you cannot write) is turned off.
- `build/vm/<mode>/obj/tests/*_test.o` are `.SECONDARY`, so make keeps them
  and a second `make vm vm-test` recompiles nothing.
- `SANITIZE` may come from the environment; `build/vm/flags` relinks when the
  flags change. Run `make build` (raco make) before many `compile` calls, or
  each one recompiles `src/`.
- Golden tests (`docs/vm/README.md` §1, `docs/vm/12-testing-and-pr-plan.md`
  §12.1): `tests/vm-diff-1-test.rkt` … `vm-diff-8-test.rkt` run each fixture
  of `tests/fixtures/vm/` on the VM and compare exit code, stdout, program
  stderr and diagnostic code with its `<name>.expected`, plus a
  `--max-steps` sweep. Shared code is in `tests/vm-diff-common.rkt`; each
  shard takes a fixed share of the fixtures so `raco test -j` runs them in
  parallel. When behaviour changes on purpose, `make goldens` rewrites the
  expected files from the VM; commit them, and the PR diff shows the change
  for review.
- The `tests/vm-diff-*-test.rkt` shards run `make -s vm` first (under a
  file lock in `build/`, since they run in parallel), print `SKIP` locally
  when the VM cannot be built, and fail in CI (`AGENTICA_REQUIRE_VM=1`).
  They run each fixture on the VM with `--json` and compare exit code,
  stdout, stderr without the final JSON diagnostic line, and the diagnostic
  code parsed from that line (`outcome`), with the fixture's golden
  (`read-expected`; JSON with `exit`, `code`, and `stdout`/`stderr` as lists
  of lines). One more VM run each in the plain and `--ai` formats must match
  exit code, stdout and program stderr, and name the same code
  (`check-text-format`; task crash blocks and the unobserved summary line
  are taken out of both sides first, and their codes must match). Crash
  lines and crash texts carry the fixture's path, so `unfixture` replaces
  the `tests/fixtures/` directory with `@fixtures/` in stdout and stderr
  before any compare. The `--max-steps` sweep: each limit must give the
  golden outcome, or exit 1 with `RUNTIME-STEP-LIMIT` and stdout and stderr
  that are prefixes of the golden's; once a limit finishes, larger ones must
  too (`check-sweep`). Each golden records the fixture's step count T
  (`"steps"`, the smallest limit that finishes); the VM's own count, found
  by `total-steps`, may be lower but at most `T + max(10, T / 10)`
  (`check-steps`, which catches over-charging), and the last sweep limit,
  `max(2T + 100, T + 2 * 2000)` with the golden's T, must finish. With
  `AGENTICA_SWEEP=sampled` (the `test` and ASan jobs and `make vm-gc-stress`) each
  fixture runs only 1, 2, T - 1, T, the last limit and 8 limits drawn one
  from each eighth of 3 to T - 2 (`sampled-limits`); local `make test`,
  the release and the weekly `sweep.yml` keep the full sweep. The draw comes from `AGENTICA_SWEEP_SEED`, else the
  first 8 hex digits of `GITHUB_SHA` or `git rev-parse HEAD`, plus the
  fixture name, so it rotates with the commit and is fixed within a run.
  Each shard prints the seed, and a failed limit names it: rerun with that
  `AGENTICA_SWEEP=sampled AGENTICA_SWEEP_SEED=...`. A new
  fixture needs its golden: run `make goldens`, read the new `.expected` by
  hand, and commit it; a changed golden is a reviewed behaviour change.
  `make goldens` refuses a run that timed out, died by a signal (status
  129 to 159) or ends in `RUNTIME-INTERNAL`, and names `.expected` files
  with no `.agc` next to them. The runaway fixtures in `step-limited/`
  keep their golden at `--max-steps 500`, with no step count. Every program
  the tests run gets `LC_ALL=C.UTF-8` and `LANG=C.UTF-8` (set when
  `tests/cli-in-process.rkt` loads), so OS error text is the untranslated
  C text; plain `C` would make Racket decode command-line arguments as
  ASCII. The sweep cannot see an ignored limit: add a runaway
  program to `tests/fixtures/vm/step-limited/` for each new loop or call
  construct (it prints nothing after the loop). On Linux, sweep and runaway
  VM runs time out after 60 seconds (`timeout --foreground` in the batch
  script, `#:timeout` in `run-process`); after the first timeout (124 or
  137) the batch skips its remaining runs and records them as 124. Fixtures are compiled in-process
  (front end, `lower`, `ir->bytecode`, `write-bytecode`, as `compile` does).
  The VM runs of one fixture go through one `/bin/sh` script that writes each
  run's stdout, stderr and exit status to files (stdin from a file, arguments
  quoted), since a process start from the Racket parent costs 12-35 ms. A new costly fixture may need an
  entry in `heavy-fixtures` in `tests/vm-diff-common.rkt`. A fixture whose
  name starts with `process-` runs with `--allow-run`
  (`fixture-allow-run`); its children must be on every CI runner (`/bin/sh`,
  `cat`, `sleep`) and must end or be closed.
  Fixture stdin comes from a file; pipe stdin is covered by the large-input
  test and the CLI tests. `compile-file` mirrors the `compile`
  pipeline of `src/main.rkt` and must follow it when that pipeline changes
  (shard 8 compares its bytes with the CLI `compile`).
  The batch script needs an `sh` on PATH (MSYS2 on Windows; untested while
  the macOS and Windows runs are paused). It starts with `exec 2>/dev/null`,
  so a VM crash shows up in that run's `.status` (128 + signal) and fails
  only that comparison. `AGENTICA_VM_BINARY=path` makes it
  use another binary without running `make` (`make vm-gc-stress` uses it
  for `build/vm/gcstress/agentica-vm`).
  `tests/bytecode-test.rkt` needs no VM binary.
- `-Wall -Wextra -Werror` and the hardening flags apply to `vm/*.c` only;
  `gc.c` gets only `-O2 -fPIE -DALL_INTERIOR_POINTERS
  -DNO_EXECUTE_PERMISSION` (`build/vm/gc.o` rebuilds when its stamp
  `build/vm/gc-flags` changes). `yyjson.c` is built per mode into `$(VM_BUILD)/yyjson.o`
  with `YY_CFLAGS` (the sanitizers in `SANITIZE=1`, no `-Werror`) and the
  `YY_DEFS` that turn off everything but the reader; `vm/*.c` see the same
  `YY_DEFS` and `-I vm/third_party/yyjson/src`, and only `vm/json.c`
  includes `yyjson.h`. libuv (Linux only, `UV_NAMES` in the Makefile, the
  Linux list of its `CMakeLists.txt`) builds per mode into
  `$(VM_BUILD)/uv/*.o` with `-std=gnu11`, its own `UV_DEFS` and the mode's
  `YY_CFLAGS`, then `$(VM_BUILD)/libuv.a`, linked with `-ldl -lrt`. The
  yyjson, picohttpparser and libuv objects follow only their own stamp,
  `$(VM_BUILD)/third-party-flags` (the output of `make -s
  vm-third-party-key`: the `YY_COMPILE`, `PICO_COMPILE` and `UV_COMPILE`
  lines, `UV_NAMES`, the compiler version, and each submodule's commit and
  local diff), not `build/vm/flags`, the Makefile or the source mtimes, so
  `TRACE` does not rebuild them and a CI cache hit stays valid. Compile them
  only through those variables, so a new flag changes the stamp;
  `vm/*.c` see `-I vm/third_party/libuv/include`, and only `vm/loop.c`,
  `vm/stream.c`, `vm/process.c`, `vm/tcp.c` and `vm/http_client.c` include `uv.h`. Bumping libuv: check out the new tag inside
  `vm/third_party/libuv`, compare its Linux source list with `UV_NAMES`,
  `git add vm/third_party/libuv`, and rerun the sanitizer and diff tests.
- Platforms: the Makefile picks Linux, macOS (`uname -s` is `Darwin`) or
  Windows (`OS=Windows_NT`, MSYS2 UCRT64) in one block: Linux values by
  default, Windows overrides `EXE`, the PIE/RELRO flags, `-lpthread` and
  `-municode` and defaults `CC` to `gcc` (UCRT64 has no `cc`), and Darwin
  only drops `-pie` and RELRO. Every binary
  target ends in `$(EXE)`; the diff test runs `dist/agentica-vm.exe` on
  Windows. The `platforms.yml` workflow, run by hand, runs `make vm vm-test`
  and the diff and bytecode tests on `macos-15` and `windows-2025`, not the
  whole `make test`; run it before merging platform code. macOS and
  Windows are paused (`references/ci.md`); Linux code goes under
  `#ifdef __linux__`.

## Add a trace point

`AGC_TRACE(tr, AGC_TRACE_IO, "start job=%" PRIu64 " kind=%s", id, name)`,
with `tr` a `const agc_trace *` (`&vm->rt->trace`, or the copy in a
`malloc`'d struct whose libuv callbacks have no runtime). Lines are `event
key=value ...`, at events only, never per instruction. When a trace needs
work first (a clock read, a GC getter), guard it with `AGC_TRACE_ON` or put
it in a small `trace_*` helper that returns early. Rules (a trace point
must never crash or change the run):

- The format is checked by `__attribute__((format(printf, ...)))`; only
  `d`, `i`, `u`, `x`, `X` (with `hh`, `h`, `l`, `ll`, `z`, `j`, `t`), `%s`,
  `%.*s` and `%%` are supported; anything else (`%c`, `%p`, floats, widths,
  flags) still compiles but ends the line with `?`. `vm/tests/trace_test.c`
  has one case per supported conversion; add one for any new conversion.
- Text goes through the escaper (plain, or JSON-quoted when empty or when it
  has a space, `=`, `"`, `\`, or a control byte). An `agc_string` or any
  (pointer, length) data is `%.*s` with `agc_trace_len(bytes)`, never `%s`.
  Trace only memory the code owns at that moment (trace a path before it is
  freed).
- No `FILE *`, stdio, locks, shared buffers, `malloc`, GC allocation or GC
  callbacks; `agc_trace_emit` saves and restores `errno`.
- Trace code only reads state: no steps, no turn cost, no change to when
  tasks switch. Bookkeeping that exists only for a trace (a job's start
  time) is set only when the category is on.
- Never trace from a real signal handler or from a libuv pool `work`
  function; libuv callbacks (`uv_signal_t` included) run on the loop thread
  and may trace.
- A new category gets a bit in `vm/trace.h` and a name in `category_names`
  in `vm/trace.c`, the regex in `tests/vm-trace-test.rkt`, and the list in
  `docs/vm/08-loader-and-cli.md` §9.
- Every test file that starts the VM itself removes `AGENTICA_VM_TRACE` and
  `AGENTICA_VM_TRACE_FILE` when it loads (the Makefile `unexport`s them).

## Linked programs

Imports never reach the VM. `src/main.rkt` (`compile` and the default run) and
`compile-file` in `tests/vm-diff-common.rkt` run `link-program`
(`src/modules.rkt`) before `check`, so `lower` sees one program whose
imported declarations carry `@N::` prefixes (display names drop them,
`write-bytecode` uses `display-name`). The span table names its source
per span: `lower` collects every `source` a span points to (`note-source!`,
entry file first), and `vm/diag.c` prints `p->sources[span->source]`, so a
diagnostic in imported code shows that file (full
path, or `std/queue.agc` for an embedded module). Block function names use
only the file's base name, so two imported files may give equal
`block@m.agc:2:17` names (the `same-basename` fixture); nothing looks
functions up by name.

## Widen the subset (new form or opcode)

1. Read the matching rules in `docs/vm/02-reference-behavior.md` §2 (reference behavior) and `docs/vm/03-ir-and-bytecode.md` §3.3
   (lowering). When a detail is not written down, decide it, write it into §2
   and pin it with a golden.
2. `src/lower.rkt`: lower the form. Emit one IR `step` per former AST
   entry, before the node's children (§3.3). Anything still out of
   the subset keeps failing with `LOWER-UNSUPPORTED` at its span; never
   miscompile. `vm-type?` says which checked types the VM accepts (the
   scalars, `(Struct name)` and `(Enum name ...)` declared in the program,
   `Json`, `List` and `Map` of accepted types, `Result` of accepted types or Void, and
   `Fn` over accepted types with an accepted or Void result); a new
   value type widens it.
3. New opcode: append it to `opcodes` in `src/bytecode.rkt` and to
   `agc_opcode` in `vm/value.h` at the same position (a test compares them).
   No opcodes for later PRs.
4. `vm/loader.c`: validate every operand (register ranges and windows,
   indexes, jump targets, spans). A new file section checks its counts
   against the bytes left and allocates through `load_alloc`, which charges
   the load memory budget. Add one assert per new rule to
   `vm/tests/loader_test.c`.
5. `vm/interp.c`: implement it with checked accessors only.
6. Add a fixture to `tests/fixtures/vm/` for each new runtime code or span;
   the diff test sweeps `--max-steps` over it.
7. Update the "Status" note and any rule that changed in `docs/vm/`, tick
   the roadmap items, and keep this guide current.

## Add a C builtin

1. `src/lower.rkt`: let the call through the builtin check (today only the
   `vm-builtins` keys `puts`, `IO.print`, `IO.warn`, `IO.inspect`,
   `IO.gets`, `IO.gets!`, `IO.read`, `IO.read_bytes`, `IO.flush`,
   `IO.eof?`, `System.args`, `System.exit`, `String.from_int`,
   `String.from_float`, `ok` (arities 0 and 1), `error`, `Result.ok?`,
   `Result.unwrap!`, `Result.unwrap_or`, `Result.message`, the callback
   builtins `List.map`, `List.filter`, `List.reduce`, `List.each`,
   `List.any?`, `List.all?` and `List.sort_by`, and the range builtins
   `Range.size`, `Range.to_a`, `Range.include?`, `Range.first`,
   `Range.last`, `Range.each`, `Int.times`, `Int.upto` and `Int.downto`,
   and the `List` and `Map` library (`List.size`, `append`, `set`,
   `repeat`, `concat`, `take`, `drop`, `at`, `reverse`, `sort`;
   `Map.has_key?`, `keys`, `size`, `put`, `get` at arities 2 and 3,
   `delete`, `values`), every `String.*` builtin, and `Float.from_int`,
   `Float.to_int`, `Float.to_int!`, `Time.now_ms`, `Time.monotonic_ms`,
   `Random.int` and `Random.float`, and every `JSON.*` builtin (the type
   argument of `JSON.decode` and `JSON.schema` lowers to a String constant
   with the struct's linked name; a struct without JSON field types, such
   as `Header` or a struct that contains one, is `LOWER-UNSUPPORTED`), and
   every `File.*`, `Dir.*` and `Path.*` builtin (with `FileHandle` in
   `value-types` and `FileInfo` appended to the struct table when a checked
   type mentions it), every `Process.*` builtin, and every `TCP.*` builtin
   (with `Process`, `Socket` and `Listener` in `value-types`) are
   accepted; everything else is
   `LOWER-UNSUPPORTED`; the lowerer also emits `List.concat` and `Map.put`
   for list and map literals above 255 elements; the loader rejects `MAP`
   with more than 255 pairs) and emit `call-builtin` with the catalog's
   implementation key and arity. The import table carries the
   implementation key, not the written name: `puts` and `IO.puts` both
   import `"puts"`.
2. `vm/builtins.c`: add the entry under that key and arity.
3. Add a fixture to `tests/fixtures/vm/` for the happy path and for each
   runtime code or span the builtin can raise; add a loader assert if the
   import rules change. A fixture `name.agc` reads `name.stdin` (raw bytes;
   `.gitattributes` marks them binary so CRLF survives) as its stdin,
   `name.channel` (lines for the child channel, see below) and
   `name.args` (a Racket list of strings, read with `file->value`) as its
   program arguments when they exist; the golden test feeds both to the
   VM, also in the `--max-steps` sweep.
   An `.args` entry `@tmp` becomes a fresh empty directory per run, and that path is turned back into `@tmp`
   in the output before the comparison; file fixtures (`files-*`) use it
   and long timeouts, and never touch paths outside it.
   A `name.channel` file makes the golden run go through `tests/fixtures/channel-run.py`
   (Python 3, needed in CI): the wrapper opens a socket pair, hands one end to
   the VM as fd 3 with `AGENTICA_CHANNEL=3`, sends the first line of the file
   and one more after each line the VM sends back, closes its sending side
   after the last, and writes everything to its stdout in the order the child
   produced it: the child's stdout as it is, each channel line as
   `channel> ` and the line. Stdout is drained before each channel line is
   shown, which is why the order is fixed. The `test-*` fixtures use it;
   the plain golden reads of `agentica test` modes (`--agentica-test run`) need
   a `.channel` file, and a fixture without one is the no-channel case
   (`test-no-channel`).
4. A blocking builtin (7h) checks its arguments, fills a `malloc`'d
   request (no GC pointers; strings through `agc_cstr` or a `malloc`'d
   copy), and calls `agc_io_start` with an `agc_io_kind`: `work` runs in
   the libuv pool and may only do system calls on that request; `done`
   and `expired` run on the interpreter thread and return the value;
   `drop` frees a request whose timeout already fired; the optional
   `cancel` half (last field, external kinds only) says whether a
   detached job (its task was cancelled) may end now through `drop`, at
   the cancel or at its deadline; leave it NULL unless the request can
   stop without closing the task's handle. It returns any
   value; `CALL_BUILTIN` then parks the task (`task->parking`) and the
   scheduler runs others; the result lands in the call's register when the
   task runs again. A builtin that must wait and then re-check (stdin,
   `Task.await`) calls `agc_task_park(vm, true)` (retry): `CALL_BUILTIN`
   keeps the arguments and re-runs the call on wake. A builtin that must
   call its block and also park between the calls (`File.each_line`) is a
   stepper: its state struct starts with an `agc_stepper` whose `step`
   function is set, the builtin calls `agc_task_stepper(vm, &state->stepper)`
   and returns, and `CALL_BUILTIN` pushes a native frame on the block (the
   builtin's last argument). Each time the frame runs, `step(vm, self, last)`
   returns `AGC_STEP_CALL` (call the block with `value`), `AGC_STEP_WAIT`
   (it started a job, so the task parks) or `AGC_STEP_END` (finish with
   `value`); `last` is the block's result or the finished job's result.
   Use `List`-style native frames for pure callbacks and a plain blocking
   builtin when there is no block. Every table entry
   has a `cost` (`AGC_COST_NONE` or `AGC_COST_SIZE`, `docs/vm/10-io-scheduler.md`
   §10.2.1, "Builtins"): a builtin whose work grows with its input takes
   `AGC_COST_SIZE` or charges `agc_charge` from inside; never touch
   `steps_left` for that. State goes in `vm->rt` (shared runtime),
   `vm` (the scheduler) or `vm->task`. Check `vm->rt->no_files`
   first in file builtins and in `TCP.connect` and `TCP.listen`, so the
   fuzzer never touches the disk or the network.

Rules for the C code:

- The catalog in `src/builtins.rkt` stays the source of keys and arity; the
  loader resolves each `(key, arity)` against the C table.
- Check argument tags generically from the table; check list and map
  elements when you touch them.
- Fail with the documented diagnostic code (`docs/grammar/`), at the call
  span or `span + 1 + i` for argument `i`, with a clear message.
- Every bounds check on an Int argument uses `__builtin_add_overflow` or
  `x < 0 || x > n - y`; never cast a negative `int64_t` to `size_t` first.
- Strings reach the OS or a library only through `agc_cstr` (a `malloc`'d
  copy, NUL terminated, NULL on an embedded NUL so the caller returns its
  error message; the caller frees it, usually with its request). Every String constructor validates UTF-8
  or decodes with U+FFFD. Build a String with `agc_make_string` (copies) or
  `agc_new_string` and fill every byte before it is stored anywhere.
- Debug text of a String (`inspect`, and later map-key, `index_of` and
  conversion messages) always goes through `agc_write_form`; never write a
  second escaper.
- No C recursion whose depth depends on a value (printing, `to_s`/`inspect`,
  JSON): use an explicit stack allocated with `agc_alloc`.
- Builtins never call the interpreter. Callback builtins are resumable
  native frames. A builtin must not keep `args` across anything that pushes a
  frame or grows registers.

## Rules every change keeps

**Goldens, not parity** (`docs/vm/README.md` §1). The VM is the reference:
each fixture's golden holds its exit code, stdout, program stderr
(`IO.warn`) and diagnostic code; a runaway program stops with
`RUNTIME-STEP-LIMIT` under `--max-steps`. Network, process and protocol
work is tested with goldens and independent Node/Python peers. Pick the peer
by role: where the VM must talk to a real
implementation, use one whose library does the protocol work (Node's `http`
for HTTP streaming, since Python's `http.server` does not decode chunked
request bodies); for raw or hostile cases, use the language the test file
already uses, so each test file has one peer. A new golden gets
hand-checked expected output; a regenerated one needs a reviewed diff. Error strings a program prints are program data: when a library
message changes, switch the fixtures that print it to printing only ok or
error in the same PR, or update their goldens on purpose. Message text,
spans, stderr wording, OS error text, exact step counts and the step-limit
span may change, but VM messages must stay clear for agents. Lowering may
optimize (inline, fold constants, move or merge `STEP`s) as long as the
goldens hold. Differences from the old evaluator in exit code, stdout or
code are recorded in `docs/vm/` (for example a failed stdout write exits 1,
out of memory exits 70, and the 2^24 register cap gives
`RUNTIME-STACK-OVERFLOW`).

**Trust model.** A `.agcb` is untrusted. Whatever it contains, the VM has no
memory errors or undefined behavior, runs children only with its own
`--allow-run`, and stops within `--max-steps`. The loader enforces the
termination rules: every backward jump lands on a `STEP`, every function that
calls starts with one, and a function without a leading `STEP` has at most 2
instructions. A file that loads may still compute wrong values or end with
`RUNTIME-INTERNAL`.

**C style.** C11. `make vm-lint` (clang-tidy, `.clang-tidy`) and
`tests/vm-style-test.rkt` check the rules marked *checked*.

- File order: includes, macros, every `struct`/`typedef`/`enum`/`union`
  definition, static data, functions. No type definition between functions
  (*checked*). Builtin tables that point to the file's functions come last.
- Exported names start with `agc_` (*checked* for functions); macros in
  the headers and enum constants start with `AGC_`; file-local macros are plain
  upper case.
- File-local helpers and data are `static` (*checked*).
- No mutable global or file-scope `static` variable in `vm/*.c` and
  `vm/*.h` (*checked* by
  `cppcoreguidelines-avoid-non-const-global-variables`; function-local
  `static` variables are not caught). State goes in `agc_vm`; constant data
  is `const`. The exceptions of `docs/vm/10-io-multicore.md` §10.2.3 take
  `// NOLINT(cppcoreguidelines-avoid-non-const-global-variables)`.
  `vm/tests/.clang-tidy` turns the check off for the C tests.
- No prototypes of `static` functions: define each helper before its first use, so files read bottom-up and the `agc_*` functions usually come last (*checked*); only unavoidable mutual recursion may have one.
- No value-driven C recursion (`docs/vm/05-values-execution-builtins.md` §7.3; *checked* by
  `misc-no-recursion` within one file only: recursion across files through
  `agc_*` calls is not caught). Depth bounded by a constant or `log n` (HAMT
  levels) is allowed with `// NOLINT(misc-no-recursion)` on the function line.
- Size arithmetic goes through `agc_size_add`/`agc_size_mul`; the loader's
  index and size sums use `uint64_t`.
- Comments in `vm/*.c`, `vm/*.h` and `vm/tests/*.c`: the default is no
  comment. Add one only where the code's complexity justifies it, and make
  it say why, not what: an invariant, a subtle ownership or lifetime rule, a
  protocol, OpenSSL or libuv quirk, an order that is not obvious, or the
  spec section or RFC the code follows. Use short `/* */` block comments.
  Never narrate obvious code and never leave commented-out code. A file may
  also start with a short header comment that says what the file is and
  where its design lives, as `vm/main.c` does, or with a legal header. Tool
  markers (`// NOLINT(...)`, `/* fall through */`) are not comments in this
  sense.
- Only `value.c` reads the value union. Immediates write the full word.

`make vm-lint` (clang-tidy 19 or newer, for `misc-use-internal-linkage`)
skips only `vm/unicode_data.c` (generated). A hook name that a tool fixes
(`__asan_default_options`) takes an exact `NOLINT(check,...)`. The style test
is a line scanner with known limits: it misses prototypes of functions that
return function pointers or that start with a macro or attribute; it reports
static arrays whose size contains `(` (`x[sizeof(y)]`) as prototypes; it
miscounts when `#if` branches open or close different numbers of braces; and
a `\`+newline inside a literal shifts its line numbers. The `_WIN32` and
macOS branches are not linted while those platforms are paused.

**Failure and exit.** Runtime failures call `agc_fail`, which `longjmp`s to
`agc_vm_run`; call it only from interpreter or builtin code on the VM's own C
stack. `System.exit` calls `agc_exit`, which records `AGC_EXITED` and the
code and `longjmp`s the same way. Only `vm/main.c` prints and exits: it
flushes stdout and maps the code (1..255 as is, anything else 0, like
Racket's exit handler). SIGPIPE is ignored and every write is checked.

**Boehm GC.**
- Allocate only through `agc_alloc` (objects that hold `agc_value`s) and
  `agc_alloc_atomic` (strings, byte buffers; not zeroed under Boehm, so never
  expose an unfilled tail), or `load_alloc` in the loader. They switch to
  `calloc` under `AGC_NO_GC` and route out-of-memory to the handler. Only
  `value.c` calls `GC_*` or includes `gc.h`.
- Under `AGC_NO_GC`, `agc_fuzz_one` frees every block after each mutant
  (`agc_release_all`), so never cache an `agc_alloc` pointer in a static.
  It also sets a 256 MB budget (`agc_set_alloc_limit`, blocks tracked only
  while it is set); an allocation past it longjmps out of the mutant and
  `agc_fuzz_one` returns 2. yyjson allocates through `agc_alloc_atomic` under
  `AGC_NO_GC` for this reason; anything else outside the agc heap (a libuv
  loop) must be closed on that path too.
- Never keep a GC pointer in `malloc` memory, an atomic object or a
  `_Thread_local`; never tag pointers. Frames hold register offsets, not
  pointers, because the register array moves when it grows.
- No GC finalizers for OS resources. OOM and abort handlers only `write(2)`
  and `_Exit(70)`.
- The submodule is pinned to a release tag. To bump it: check out the new
  tag inside `vm/third_party/bdwgc`, then `git add vm/third_party/bdwgc` (the
  index keeps the old commit otherwise), rebuild with `AGENTICA_GC=vendored`,
  and run the sanitizer and diff tests.
- `AGENTICA_GC` picks the libgc (`docs/vm/11-build-ci-supply-chain.md`):
  `system` (the Linux default) links the distro's libgc with `pkg-config
  --cflags --libs bdw-gc`, after the stamp `$(VM_BUILD)/gc-system` (an
  order-only prerequisite of every VM object and a prerequisite of every
  binary) has checked pkg-config, the package and `GC_MIN` (8.2.0);
  `vendored` builds `build/vm/gc.o` from the submodule (non-Linux hosts, the
  release, and `GC_STRESS=1` always); `SANITIZE=1` has no libgc. The mode is
  not remembered: pass it to every make command or export it. Debian's libgc
  is threaded and `gc.o` is not; the VM never defines `GC_THREADS`, so the
  collector knows only the main thread and starts no marker threads. Keep
  pool threads off GC memory (they use `malloc` only); a thread that
  touches the heap needs `GC_THREADS` and `GC_register_my_thread` first.
  `agc_init` sets `GC_set_all_interior_pointers(1)` before `GC_INIT` so both
  builds agree.

## Later phases (read §10, `docs/vm/10-*.md`, before starting them)

- **libuv (7h, in: loop, files and tasks)**: `docs/vm/10-io-scheduler.md` §10.2.2 describes the
  loop with its run queue; only the scheduler (`vm/task.c`, through `agc_io_poll`) calls
  `uv_run`, and libuv callbacks only set flags (tasks will also queue the
  task). N=1 today; the design target (`docs/vm/16-architecture.md` §16, rules per
  thread in `docs/vm/10-io-multicore.md` §10.2.3, gated in the roadmap order on the server
  measurement, decided right after it) is N scheduler threads that pull from
  one global run queue and one I/O thread, the main thread, with the only libuv
  loop, built on split structures (read-only runtime; global run queue; the
  loop and its inbox on the I/O thread, and the registry there or shared
  under a lock, which is open in §16.11; per-scheduler turn counter;
  per-task stack, registers and frame). Once tasks land, a
  builtin or opcode whose work grows with its input sets a turn cost
  (`docs/vm/10-io-scheduler.md` §10.2.1, Builtins); it is taken from the turn only, never
  from `steps_left`, so it never changes how `--max-steps` stops a program. Only the
  thread that owns the loop calls `uv_run` on it (the scheduler with N=1, the I/O thread with N>1). New code adds no
  mutable `static` or global variable in `vm/` (the exceptions are listed
  in `docs/vm/10-io-multicore.md` §10.2.3); state goes in the runtime, scheduler or task
  struct, and lazy init uses `pthread_once` or runs at start-up.
  Handles and requests are `malloc`'d and must stay owned until their
  `uv_close` callback: either the GC object that owns one stays in its
  scheduler's resource registry until then, or the `malloc`'d native
  state counts its pending close callbacks (and its users) and frees
  itself only when both reach zero. With such a count, `close` may
  unregister the resource at once, as `Process.close` and `TCP.close`
  do: the native state outlives the handle. The VM's own exit path frees
  nothing (`_exit`); `agc_io_close`, for the in-process harnesses, runs
  `uv_run` NOWAIT so the callbacks still fire there.
  Request buffers stay owned by the request until its callback. All
  handles and descriptors are non-inheritable.
- **OpenSSL 3.5 (7h, in on Linux)**: `AGENTICA_OPENSSL` picks it
  (`docs/vm/10-dependencies-and-platforms.md` §10.0). The default `system`
  links the system OpenSSL dynamically with `pkg-config --cflags --libs
  openssl`; the stamp `$(VM_BUILD)/openssl-system` (the first
  prerequisite of every VM binary and `vm-lint`, order-only for every VM
  object, so it runs before any `vm/*.c` compile) fails with a clear
  message when `pkg-config` or the package is missing or older than
  `OSSL_MIN` (3.0.0: the code uses 3.0 APIs such as
  `SSL_CTX_load_verify_file` and `OPENSSL_VERSION_STRING`), and
  `vm/tls_openssl.c` has an `#error` for older versions and LibreSSL. The
  mode is not remembered: pass `AGENTICA_OPENSSL=vendored` to every make
  command or export it. `vendored` (only the release) builds the submodule
  static per build mode: out-of-tree `Configure` in `$(VM_BUILD)/openssl/` with
  `OSSL_OPTS` (`no-shared no-tests no-docs no-apps no-module ... no-deprecated`)
  and the mode's `OSSL_CFLAGS` (release hardening, `-g` for GC stress,
  clang `-g -fno-omit-frame-pointer` without `-fsanitize` for the
  sanitizer build: a non-instrumented OpenSSL; ASan's interceptors still
  check the buffers we hand it), output in `configure.log` and
  `build.log`; both commands run under `env -u` for the make and compiler
  variables, and the sub-make is a plain `make` (never `$(MAKE)`, so
  `make -n` skips it). `$(VM_BUILD)/openssl-flags` is the key of the
  vendored build only (`make -s vm-openssl-key
  AGENTICA_OPENSSL=vendored`, which refuses the system mode: the two command lines, compiler version, OpenSSL
  version and commit), rewritten only when it changes, and the archives depend
  only on it, so `TRACE` and VM flag changes never rebuild OpenSSL and a
  restored CI cache is up to date; after editing OpenSSL sources by hand,
  remove `$(VM_BUILD)/openssl`. Init with `OPENSSL_INIT_NO_LOAD_CONFIG |
  OPENSSL_INIT_NO_ATEXIT`; TLS 1.2 and security level 2 as minimums;
  trust: `SSL_CERT_FILE` or else the first readable distro bundle, and
  `SSL_CERT_DIR` or else no directory (a failing system source is
  skipped); a non-empty `ca_file` replaces system trust and must load.
  SNI plus `SSL_set1_host` per connection, `X509_VERIFY_PARAM_set1_ip_asc`
  (no SNI) for IP literals; no `SSL_VERIFY_NONE` path. Never hand OpenSSL a
  GC pointer, and keep file loading off the scheduler thread (the config
  loads in a libuv pool job). The release (`zig cc`, glibc 2.28) sets
  `AGENTICA_OPENSSL=vendored` and `AGENTICA_GC=vendored`; `readelf -d` must show no `libssl`, `libcrypto` or `libgc`, and `--version` must name the submodule's version. `--version` prints the
  OpenSSL that runs (`OpenSSL_version`), so a system build shows the
  distro's version. `build/vm/flags` records the mode, so switching it
  relinks. Bumping: fetch the new 3.5.x tag in the submodule, commit it,
  rebuild with `AGENTICA_OPENSSL=vendored`, rerun the TLS, sanitizer and golden
  tests.
- **HTTP (7h)**: parity is black-box. Well-formed messages: same status,
  headers, body and `Result` ok or error. Malformed input: both reject
  (server error status and close, client error `Result`); the code may
  differ except 413, 431 (also trailers), 505 (requests; a bad response
  version is a client error `Result`) and 501 (`CONNECT`, and any
  `Transfer-Encoding` but one `chunked`). Equal duplicate `Content-Length`
  is accepted; conflicting values give 400; `Content-Length` with any
  `Transfer-Encoding` is 400 first. No copying of evaluator quirks or
  its order of failing lines; picohttpparser's leniencies are documented
  differences; framing stays strict. picohttpparser (submodule
  `vm/third_party/picohttpparser`, MIT or Perl, tag v1.4, built at the baseline
  without `-msse4.2`) parses and validates start lines and headers, behind
  `vm/http_parse.h` (our head struct with byte slices,
  `agc_http_parse_request_head`/`agc_http_parse_response_head` returning
  OK with bytes consumed, INCOMPLETE or ERROR with our error enum). Only
  `vm/http_pico.c` includes `picohttpparser.h`. It is called without
  `last_len` and only when new bytes complete a line (head at most the
  8192-byte start line plus 64 KiB of headers); a -1 is 400 or a client
  error `Result`. A pre-scan checks size limits (431), bare LF and the
  header count (431 past 100, before pico runs), skipping one leading CRLF
  before a request. The pre-scan stops at the end of the start line; the
  start-line check (431 for its length, then 505 or 400) runs before the
  pre-scan looks at any header line. Before pico, the adapter checks a
  complete start line
  with the evaluator's shape: `HTTP/[0-9.]+` other than exactly `1.1`
  gives 505 (`GET / HTTP/1` too), other bad shapes 400, so it fails at
  once. On pico's output: target (origin form or `*` with
  `OPTIONS`, bytes 33–126), method token, `CONNECT` 501, obs-fold
  (`name == NULL`), response version, status 100–599, no 101, 15 interim
  responses accepted and the 16th fails, `Host`, framing and smuggling.
  The body goes through our incremental decoder `vm/http_body.c` (`feed`
  returns bytes consumed, body slices, and NEED_MORE, DONE or ERROR: 413
  over the limit, 431 for an over-long chunk-size or trailer line or
  trailers over their limits, 400
  otherwise; trailers checked with the header rules; no
  `phr_decode_chunked`), so bodies stream and are never buffered whole.
  Tests target the adapter and check rejections and the codes that must
  match, not messages (`docs/vm/10-io-http.md` 10.6).
- **Processes (7h, in on Linux)**: `vm/process.c`, `docs/vm/10-io-processes.md` §10.4. The
  VM resolves the executable itself (`PATH` only for a bare name, never the
  working directory) and passes the absolute path to `uv_spawn`; never
  verbatim arguments; all three stdio piped; `UV_USE_IO_URING` is dropped
  from the child's environment only when the VM set it. A Windows port must
  allow only `.exe`/`.com`, case-insensitive, and must not search the
  current directory. The evaluator keeps a direction's lock after a stream
  timeout (a legacy bug; the VM answers "process is closed"); fixtures avoid
  that path. Pool threads are started with `SIGINT`, `SIGTERM` and `SIGHUP`
  blocked (`agc_io_start` blocks them around `uv_queue_work`); keep that
  when adding new ways into the libuv pool. Boehm's marker threads do not
  block them, so the stop handler may run on any thread: it only uses
  lock-free atomics and async-signal-safe calls. The signal tests in
  `tests/vm-stop-test.rkt` (with `tests/fixtures/stop-peer.py`: a FIFO
  filled so a flush cannot end, a dying driver, an inherited pipe) and
  `tests/vm-diff-common.rkt` signal the driver and the VM with libc `kill`
  through the FFI and bound every wait.
  Captured children (21a) are what `std/bdd` runs its scenario VMs with:
  never block the VM in their close (only the end-of-run cleanup may wait,
  bounded), and keep the `SIGTERM` first, since the child VM's exit path
  is what stops the programs it started. `tests/vm-diff-common.rkt` checks
  that with a VM child that started `sleep`, closed by `Process.close` and
  by a `read_line` timeout: the grandchild's pid must be gone when the run
  ends. A second case closes a child that ignores `SIGTERM` (close returns
  at once, the timer's `SIGKILL`, the end-of-run deadline) and one that
  dies on it right before `main` returns; each run must end with
  `end code=0 signal=0` in the `io` trace. Golden fixtures with children keep their step counts independent of
  timing: wait for an event (`wait`, a read, `output`) before a call whose
  result depends on it.
- **TCP (7h, in on Linux)**: `vm/tcp.c`, `docs/vm/10-io-tls.md`
  §10.3.1. TLS sockets and listeners are the same `net` with
  `secure` set (see TLS below).
  The `tcp-*` fixtures are their own peers (a listener and its client tasks
  in one program) and print only from `main` after its awaits, so output and
  step counts do not depend on timing; `recv_bytes` returns what has
  arrived, so a fixture reads bytes only after the writer is done (await it
  first). Network tests bind 127.0.0.1 port 0 and use Node peers; no name
  that needs DNS beyond `/etc/hosts`. A connect timeout has no hermetic test
  (it needs an address that drops SYNs); it was checked by hand. A fixture
  that needs a write to stay parked sends one String far bigger than the
  loopback buffers (64 MiB), never a loop of sends: the number of sends
  that complete depends on the kernel's buffer sizes, and so would the
  step count.
- **TLS (7h, in on Linux)**: `TLS.connect` and `TLS.listen` in `vm/tcp.c`
  on the adapter of `vm/tls.h` (`docs/vm/10-io-tls.md`
  §10.3). A secure `net` first loads its config in a pool job
  (`start_setup`), then resolves and connects or listens as for TCP. The
  read callback feeds ciphertext to the session, runs the handshake, then
  decrypts into `agc_inbuf`, so line and byte reads, limits, locks and
  timeouts are the TCP ones. Sends copy plaintext to a `malloc`'d buffer
  and encrypt it 16 KiB at a time, one `agc_stream_write` per piece. On a
  TLS listener a waiting accept takes the connection at once and handshakes
  it under the accept's timeout; children in a handshake hang off their
  request (`handshakes` list), and closing the listener closes them.
  Closing sends `close_notify` with one `uv_try_write`. Messages keep
  Racket's shapes (`ssl-connect: connect failed (...)`, `port->ssl-ports:
  accept failed (...)`, `ssl-load-...: load failed from: "path" (...)`);
  only the `Result` kind must match the evaluator. A peer that closes
  without `close_notify` is EOF (`SSL_OP_IGNORE_UNEXPECTED_EOF`), as in
  Racket. `tls` trace points: handshake, handshake_done, handshake_error,
  setup_error, read_error, close. Keep TLS goldens few and small (now
  `tls-echo` and `tls-errors`, about 60 steps each): every run of the
  `--max-steps` sweep does a handshake. Put other TLS cases in
  `tests/vm-tls-test.rkt`, which runs each once, with short timeouts, small
  payloads and no sleeps. The `tls-*` fixtures take their
  certificate directory as `@fixtures/tls` in `.args` (`fixture-arg` in
  `tests/vm-diff-common.rkt` makes it absolute, since `raco test` and
  `make goldens` run from different directories). Certificates come from
  `tests/fixtures/tls/make-certs.sh` (OpenSSL 3.4 or newer for the expired
  one).
- **HTTP client (20a, in on Linux)**: `vm/http_client.c` on `vm/net.h`
  and the parser of `vm/http_parse.h`, called only by `stdlib/http.agc`
  (the std-only guard). The `http-*` fixtures are their own peers (a TCP
  server task in the same program; only `main` prints); the std/http URL
  parser costs about 500 steps per call, so the sweep samples them. Put the
  other cases in `tests/vm-http-test.rkt`, which starts one Python peer
  (`tests/fixtures/http-peer.py`: a `ThreadingHTTPServer`, the same over `ssl`, and a raw socket server with
  canned hostile responses) and runs three programs once. Python 3
  (standard library only) is required in CI, as Node is for TCP: with `CI`
  set the test fails without it, locally it prints a skip. picohttpparser
  is the submodule `vm/third_party/picohttpparser` (v1.4); bumping it: check
  out the new tag inside it, `git add` it, and rerun
  `vm/tests/http_parse_test.c`, the HTTP goldens and `tests/vm-http-test.rkt`.
- **HTTP server (20c, in on Linux)**: `vm/http_server.c` on `vm/net.h`, the
  same parser and `vm/http_fields.c`. The `http-server*` fixtures are their
  own peers (the `std/http` client, or a raw `TCP` client for bytes the
  client cannot send); a side `TCP` listener tells `main` that a handler
  started, so `close_server`, slow-handler and `main`-returns cases do not
  depend on timing. `tests/vm-http-test.rkt` starts a VM server program
  (plain and TLS, port 0, ports on its first line) and runs
  `tests/fixtures/http-server-peer.py` (every hostile request of §10.6 on a
  raw socket, the `Expect` cases, pipelining, `http.client`, the
  `max_connections` wait, TLS, and a pipelined flood during a stalled
  8 MiB response that must stay bounded) and `tests/fixtures/http-server-peer.js`
  (Node `http`: chunked upload, `Expect`, keep-alive, `HEAD`, concurrent
  clients); closing its stdin ends the server. Node and Python are
  required in CI. A connection task is `hidden`: of its unobserved crashes
  only the first per test (or per run) stays in the crash list, the others
  count on it (`quiet_more`), so a long-running server does not grow the
  list; observed crashes leave the list. Handlers cannot reach their own
  `HttpServer` (values are immutable and the handler is fixed before the
  server exists), so the self-close case is the C test of a task that cancels itself;
  `http-server-owner-crash` crashes the task that owns a server with a live
  connection (handed over with `Task.spawn_owning`), and
  `http-server-owner-cancel` cancels the task that owns one, which frees the
  port.
  The client gets its connection from tcp.c through `agc_conn`, never its own
  socket code. Idle pooled connections and the idle timer are unreferenced
  (`agc_conn_hold`), so they never keep a stalled run alive; a connection
  freed while calls wait is parked first and handed over by a 1 ms
  referenced timer (a narrow guard against late bytes, not a full one). An
  idempotent call that fails on a reused connection before any response
  byte is retried once on a new one (`retry`). A close-delimited body over TLS needs `close_notify`
  (`agc_conn_clean_eof`); a bare FIN gives "truncated HTTP body".
- **Limits**: the 1 MiB per-call reads, HTTP framing limits and the other
  caps in the `docs/vm/10-io-processes.md` limits table stay as documented.

## Gotchas

- JSON parsing matches what the old evaluator did (Racket's `read-json` plus the checks of its deleted `src/json.rkt`),
  not RFC 8259 alone: the control-character pass runs first over the whole
  text, a top-level number or literal stops early (`01` is unexpected
  content, `truex` invalid), the finite check comes after the trailing
  check, a mantissa of zeros is `0.0` whatever its sign, and duplicate
  keys keep the last value (`docs/vm/02-reference-behavior.md` §2.6). yyjson reads numbers as
  raw text so the VM converts them itself; never turn on its `ALLOW_*`
  flags or its writer. Bumping yyjson: check out the new tag inside
  `vm/third_party/yyjson`, `git add vm/third_party/yyjson`, and rerun the
  sanitizer and diff tests.

- `Random` differs from the evaluator by design: the VM uses xoshiro256**
  and the evaluator Racket's `random`, so seeded sequences differ between
  backends (`docs/vm/05-values-execution-builtins.md` §7.4). A `Random` fixture prints only what both
  share (counts of in-range values, `[0, 1)` checks), never drawn
  numbers.
- Float text is not `printf("%.17g")` or "first `%.*e` that round-trips":
  Racket breaks exact ties upward and uses the asymmetric interval at powers
  of two. Keep `agc_float_text` as `docs/vm/02-reference-behavior.md` §2.2 describes it, and add
  any new tricky value to `vm/tests/float_text_test.c` with the text Racket
  prints.

- Checking out a branch without the submodule warns `unable to rmdir
  vm/third_party/bdwgc`; run `git submodule update --init` after switching
  back.
- Each sweep limit is one VM start, and the start costs more than the run:
  the diff test runs every limit only up to 200 steps; above that it runs 1
  to 100, limits spaced steps / 50 apart, the steps minus 1 and the steps
  (`sweep-limits` in `tests/vm-diff-common.rkt`). Under ASan a start costs
  about 20 ms, so the sanitizer and GC-stress runs sample the sweep
  (`AGENTICA_SWEEP=sampled`).
- Typed JSON: `user-tables` in `src/lower.rkt` gives each `ir-struct` its
  JSON field types when the struct is decodable (greatest fixpoint, so
  recursive structs stay in), and `src/bytecode.rkt` interns them into the
  Types section (format version 3). `$defs` names and the type-argument
  constant are the linked names (`@2::Point`), not display names: the
  evaluator's `JSON.schema` prints them, and two imported structs can share
  a display name. A new decodable kind (enums, `JsonField`) needs a new
  type kind, loader rules and a format bump.
- Struct and enum table names are display names: `write-bytecode` passes
  the linked name through `display-name` (`builtins.rkt`), as the
  evaluator does when printing (`docs/vm/02-reference-behavior.md` §2.4). The lowerer keeps the
  unique linked names as its keys and in `format-ir`. Variant ids are global in file order;
  struct ids and field indexes follow declaration order. Generic enums need
  nothing special: type arguments exist only in the checker.
- `case` reads a local scrutinee in place (no copy) because every test and
  payload read comes before any arm body runs. Arm bodies go through
  `lower-block`, so the `for` element read (`after-step`) still lands after
  the first statement's `step` when a `case` starts a loop body.
- The checker accepts Int literal patterns outside 64 bits
  (`9223372036854775808 ->`); they never match, so the lowerer emits a plain
  jump to the next arm instead of a constant the writer cannot encode.
- The load budget is 4 bytes per file byte plus 1 MiB. Keep per-entry
  costs low (one array for all variants, sized by a first pass; no
  temporary copies): a real program with 65535 variants must load.
  `load_alloc(0)` returns NULL without charging anything.
- Tail calls: the lowerer turns `return f(...)` into `tail-call` when the
  value is a direct user call (`tail-call?` in `src/lower.rkt`; builtins
  and calls inside larger expressions do not count) and emits no `return`
  after it. `TAIL_CALL` grows the registers to the frame base plus the
  callee's count first, then `memmove`s the argument window to `R[0..]`
  (windows overlap). It does not touch the depth, so a deep tail recursion
  runs (the depth rule is in `docs/vm/05-values-execution-builtins.md` §6.1). Fixtures that must overflow need a
  non-tail call (`stack-overflow.agc` uses `return down(n + 1) + 1`); the
  deep tail-recursion case lives in `tests/vm-diff-common.rkt`. The loader
  treats `TAIL_CALL` as a call for the termination rules.
- Tasks: `make vm-latency` runs `tests/vm-latency-test.rkt` alone (kept
  out of `make test`'s parallel batch by `tests/info.rkt`; CI runs it right
  after `make test`). A sleeping task and a stdin reader must wake within
  250 ms next to CPU, sort and concat tasks, and must not with
  `AGENTICA_VM_TEST_BLOCKING_OUTPUT=1` (a test-only switch that leaves
  stdout and stderr on the blocking `FILE` fallback, so
  `tests/vm-stdout-test.rkt` can test that path on Linux) and
  `AGENTICA_VM_TEST_NO_TURN_COST=1` (a test-only switch that skips turn
  costs, `docs/vm/10-io-scheduler.md` §10.2.1). A task reading a
  `FileHandle` in a loop must let `main` close it, and the run must end.
  Every read from the VM has a 60-second timeout. The test skips when
  `AGENTICA_VM` names another binary. The `task-*` fixtures keep tasks
  from running side by side where the step-limit span matters, since with
  several runnable tasks the span depends on the interleaving. Builtins get
  `vm->task->regs + base`; `Task.spawn` builds the child's frame with
  `agc_task_call` on the child, never on the caller.
- Stdout and stderr: `vm/output.c` writes them, with one exception: `vm/process.c` forwards the stderr of a child process (`Process.spawn`) to `err.file` with a blocking `fwrite` in its read callback. That text is not in the buffer or in the order of the calls, and it can block the loop when stderr is stuck. `agc_vm_init` leaves
  both on the blocking `FILE *` it was given (`base` is null), so the C tests and
  the fuzzer never depend on the loop; `vm/main.c` calls `agc_output_open`
  after `agc_input_open`. Never `fwrite` to `vm->rt->out.file` or
  `err.file` from builtin code: use `agc_write`, which parks the task and
  expects to be run again, so a builtin must work out its text before the
  call (and pass no text when `agc_output_waiting` says its text already waits)
  and not touch state after it that a second run would repeat. Text the
  VM itself prints goes through `agc_notice_begin` and `agc_notice_end`.
- Stdin and arguments: only `vm/input.c` reads fd 0; `agc_vm_init` leaves
  the input closed (`fd = -1`, always EOF) and `System.args` empty, and
  `vm/main.c` opens fd 0 and fills `vm->rt->args`, so the C tests and the
  fuzzer never block on stdin. Stdin text decodes each invalid byte to
  U+FFFD (Racket ports); arguments decode each invalid byte to `?` and an
  incomplete sequence at the end to one `?` (Racket in a UTF-8 locale,
  through glibc `iconv`); the diff test checks this with `LC_ALL=C.UTF-8`.
  The driver copies a non-file stdin into the VM with a thread that
  it kills once the VM exits.
- Closures: a `block-lit` becomes an extra IR function after the declared
  ones (`block@file:line:col`), lowered by a fresh `lower-function` context;
  its captures are the visible names its body (nested blocks included)
  reads, found by `referenced-names`, a generic walk over the transparent
  AST structs. Captures sit after the parameters; `closure` copies them
  into the function value (a snapshot). The checker records every block's
  `Fn` type in `#:types`, also when a `List` rule checks it directly. A
  block's final expression statement is its value. `&name` is `closure`
  with no captures, `.call` is `call-value` (window base holds the
  function, result lands there).
- Callback builtins are native frames, not C calls into the loop: the C
  table entry has an `agc_native_kind`; `CALL_BUILTIN` copies the
  arguments into an `agc_native` GC object and pushes a frame with
  `native` set at `R[a]`; callbacks run at `R[a+1]` with result register
  `R[a]`, and `return_value` resumes the native frame when it is on top.
  `frame_count` counts every frame, `depth` only bytecode frames, so the
  call-depth limit matches the evaluator (callback push fails at the
  builtin's call span). Deep recursion through a callback must not use
  `return f(...)` in the block in a fixture: that is a tail call on the
  VM only.
- Ranges: `AGC_T_RANGE` holds an atomic `agc_range` (start, end,
  exclusive); `agc_range_bounds` gives first, last included and non-empty
  without overflow. A `for` over a range literal lowers to a counter loop
  with no `RANGE` (`lower-range-for`); over a Range value it reads
  `RANGE_BOUNDS` once into three slots. The loop variable is the counter
  slot, and the exit test (`eq` with the last value) runs before `add-i`,
  so the largest Int never overflows. The loop top is a `STEP` with the
  `for` span, so each iteration charges one step even with an empty body
  (never drop the loop); the counting natives call `charge_steps`, shared with `STEP`, before
  each callback. The evaluator charges the same (`step!` per range
  iteration and per counting callback). `tests/fixtures/vm/step-limited/`
  holds huge loops that the extras shard runs only with small
  `--max-steps` values. `Range.each`, `Int.times`, `upto` and
  `downto` are counting native frames (`counting()` in `vm/interp.c`): no
  list, a current value, a last value, a direction and a "more" flag. The
  range text is at most 43 bytes, so `AGC_SCALAR_TEXT` is 48 (a `_Static_assert` keeps it at least 44).
- Results: `ok`, `error` and `Result.*` are builtins (`vm/builtins.c`);
  `try`, `is-ok` and `result-value` are opcodes. A Result pattern is a
  `variant-pattern` with enum name `"Result"` and variant `"Ok"` or `"Err"`
  (the parser turns `ok(v)`/`error(m)` into it); the lowerer picks the
  Result test from the scrutinee's checked type. `ok()` holds Void and
  prints `ok()`. `Result.unwrap!` fails with the error's own String
  through `agc_fail_text`, which keeps the byte length (the String may hold
  NUL); `agc_outcome` has `message_len`, and `vm/diag.c` prints by length.
  `agc_outcome.text` is never read: it keeps the String reachable while
  `message` points into its data, so do not remove it.
- Maps keep insertion order exactly, as the old evaluator did: a HAMT from
  key to value plus a reversed cons list of keys (the old `mapping` of the
  deleted `src/runtime-values.rkt`). A new key conses one cell; a replaced key
  keeps its cell. Never keep order in an array copied on every put. The
  hash is keyed per run, so nothing observable may depend on it; the
  printer, `Map.keys` and `Map.values` walk the key list, not the trie.
  `Map.delete` copies the trie path and the key list up to the key's cell
  (the rest is shared); a missing key returns the same map. `List.sort`
  reuses `agc_sort_by_keys` (`vm/interp.c`) with the items as their own
  keys. `MAP` and `Map.put` share
  `agc_map_put`; HAMT recursion is bounded by 14 levels, printing nested
  maps goes through the explicit-stack printer.
- `SAME` (case literals) is `equal?`, not `=`: Float by `eqv?`, so `-0.0`
  and `0.0` are different patterns.
- A loop body is the target of a backward jump, so it must start with a
  `STEP`. `for` therefore emits its `list-get` right after the first body
  statement's `step` (the `after-step` hook in `lower-statement`), and an
  empty body lowers to just the iterable.
- The `for` iterable is copied into a hidden slot even when it is a local:
  the body may assign that local, and the evaluator iterates the old list.
- Lists can share items, so a list's text can be exponential in the code
  that built it (`a1 = [a0, a0]`, `a2 = [a1, a1]`, ...); printing then ends in the out-of-memory exit, as the trust
  model allows. Never print or compare nested values with C recursion.
- Under ASan, Boehm is off (`-DAGC_NO_GC`); GC bugs need the GC-debug stress
  run (`make vm-gc-stress`), not ASan.
- Racket `write` prints the joiners U+200C, U+200D and U+E0020 to U+E007F
  raw only after a raw non-blank character, so the debug form has state;
  see `docs/vm/02-reference-behavior.md` §2.3 before touching `agc_write_form`.
- `--max-steps` bounds instructions, not bytes: string ops cost in
  proportion to their size.
- Portability: keep platform code in `vm/main.c` (`open_input`, `wmain`)
  and the Makefile platform block. `#ifdef SIGPIPE`, not `#ifdef _WIN32`,
  guards the signal. `_Exit` is C11; mingw-w64 still provides `write`,
  `open`, `read`, `fstat` and `ssize_t` with `-std=c11`, but its `struct
  stat` has a 32-bit `st_size`, so Windows uses `_fstat64`. The input file
  is opened with `_wopen` on the original UTF-16 argument (`wide_args`),
  never through `open` (ANSI code page) or a UTF-8 round trip (a lone
  surrogate would become U+FFFD and name another file). `-municode` goes only on binaries that link
  `vm/main.c`; the C tests have a plain `main`.
- libgc without `NO_EXECUTE_PERMISSION` maps writable and executable pages,
  and macOS on arm64 aborts with `Cannot allocate executable pages` as soon
  as the heap grows (the loader test does). Interior pointers on the stack
  and in registers always count; `ALL_INTERIOR_POINTERS` only adds those
  stored in GC objects and static data and one-past-the-end pointers (one
  extra byte per object). Nothing relies on it; it is upstream's default.
- `-D_POSIX_C_SOURCE` makes mingw-w64 use its own printf
  (`__USE_MINGW_ANSI_STDIO=1`), not the UCRT's; both print `%.767e`
  exactly, as does the macOS libc.
- `.gitattributes` keeps LF on checkout (GitHub's Windows runners set
  `core.autocrlf`). Git detects files with NUL bytes as binary; a binary
  fixture without them needs a `binary` line there.
- MSYS2 in CI has no `grep`; use `sed` or install the package.
- Strings: `agc_string` keeps the byte and code point counts; build every
  `String` result with a sizing pass then a fill pass (or one copy), never
  by repeated concatenation, and search with the KMP finder in
  `vm/strings.c`, not a naive loop. Racket's `String.trim` is `\s` only
  (five ASCII bytes); case mapping is the tables plus final sigma
  (`docs/vm/02-reference-behavior.md` §2.3), and a new contextual case rule must come with a
  generator check, not by hand. Float text goes to `strtod` only after
  the evaluator's pattern check.
- `string-trim` in `format-diagnostic-ai` trims only ASCII `[ \t\n\f\r]`,
  not Unicode whitespace; the VM matches that.
