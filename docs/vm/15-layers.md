## 15. VM layers

**Status:** planned by the owner on 2026-10-13, row 7.2.1b of the
[roadmap](../roadmap/README.md) (checklist in
[`07-vm.md`](../roadmap/07-vm.md#7l-vm-layers)); built. No behavior change: the
goldens do not move. It follows the architecture note
[§16](16-architecture.md), which names the threads and queues behind the port.

The C VM gets a light layering: three layers (core, services, adapters) with
one-way dependencies, plus a driver on top that wires them; one small port
between the services and the core; one header per layer; and a CI check that
keeps the direction. It is not DDD and not a plugin system: calls stay direct,
and function pointers stay where they already are (callbacks), not as tables
around every module.

Words. §14 calls everything under the scheduler "the VM core" (`task.c`,
`loop.c`, `input.c`, `files.c`, `process.c`, `tcp.c`, HTTP and TLS). Here
**core** is narrower: the scheduler, the loop, the values and what they need.
§14's five rules hold for the core and the services alike.

This is the first part of 7l (roadmap
[`07-vm.md`](../roadmap/07-vm.md#7l-vm-layers)). §14.6 asks of the layers:
"Does each layer replace code, or only add a boundary?" Answer: mostly a
boundary, checked by CI. It adds no runtime concept.

### 15.1 Layers

The files of each layer are the lists at the top of `vm/tools/check-layers.sh`
(`core`, `services`, `adapters`, `driver`); a new `vm/*.c` file goes in one of
them.

- **Layer:** **Core**
  - **What:** values, the interpreter, the scheduler and the loop
  - **May use:** `value.h`, `port.h`, `core.h`, `trace.h`, Boehm GC, libuv

- **Layer:** **Services**
  - **What:** the libraries and handle kinds built on the port (strings,
    numbers, JSON, files, processes, TCP, HTTP, logger, `Test`)
  - **May use:** `value.h`, `port.h`, `services.h`, `net.h`, `trace.h`, adapter
    headers, libuv, yyjson (`json.c` only)

- **Layer:** **Adapters**
  - **What:** one wrapper of a library or one operating-system side, each
    behind its own plain header (§15.3)
  - **May use:** their own header, their library, and from `value.h` only the
    memory functions (`agc_alloc`, `agc_alloc_atomic`, `agc_size_add`,
    `agc_size_mul`, `agc_out_of_memory`)

- **Layer:** **Driver** (not a layer: it wires them)
  - **What:** `agentica.c`, `launch.c`, `builtin_tables.c` (§15.6 V2), the fuzz
    mains
  - **May use:** everything

`vm/tests/*.c` may use everything. `trace.h` (tracing) is shared by every layer
but the adapters.

Notes on the choices:

- **`unicode_data.c` is core, not an adapter.** It is generated data, not a
  wrapper of a library, and `text.c` (core) prints strings with its
  `agc_write_*` ranges. Its case tables (used by `strings.c`) are data too; all
  its tables are declared in `value.h`.
- **`channel.c` is core.** A channel's waiters are a list the scheduler owns,
  like stdin's, and `agc_task_cancel` takes a task out of it through
  `agc_channel_leave` (`task.c`), so the code cannot sit in a service the core
  may not name. Its builtin table is declared in `core.h`, as
  `agc_task_builtins` is.
- **`task_map.c` is core.** `Task.map` spawns, cancels and times tasks, and
  parks its caller in a stepper on a timer of the task (`vm/timers.c`), so it
  can use only what the core offers. Its builtin table is declared in `core.h`
  and listed in `builtin_tables.c`.
- **`input.c`, `output.c`, `stdio_posix.c`, `stdio_windows.c` and `builtins.c`
  are core.** stdin's waiters and the waiters of stdout and stderr are lists the
  scheduler owns (§14.1), and `agc_task_cancel` takes a task out of them.
  `builtins.c` holds the `IO`, `System`, `List`, `Map`, `Set`, `Result` and
  `Range` builtins over core values, and `agc_find_builtin`, which the loader
  calls. `stdio_posix.c` and `stdio_windows.c` are the operating-system side of
  `output.c`, one file per system family, each guarded whole: which way a
  descriptor is written, whether two are one target, the writes, and the
  in-memory stream of a notice. `output.c` has no `#ifdef` for an OS.
- **`stream.c` is a service.** It is the kit the stream services share
  (`agc_inbuf_*`, `agc_stream_lock`, `agc_stream_write`); only `duplex.c`,
  `process.c` and `tcp.c` use it.
- **`duplex.c` is a service (25c).** It owns the child channel: one
  bidirectional stream per channel end, a line buffer, a reader and a writer
  request, and the two child-side builtins `Process.parent_read_line` and
  `Process.parent_send`. `process.c` creates the parent end of a child's channel
  through it, and `testing.c` checks for the child's end with `agc_parent_open`
  and reads and writes it with `agc_parent_line` and `agc_parent_send`. It adds
  nothing to the port: its waits are jobs with the call's timeout
  (`agc_io_start`), its locks are the stream kit's, and its handle is a libuv
  pipe like the stdio pipes of `process.c`.
- **`http_body.c` is an adapter, with `http_pico.c`.** `http_parse.h` is a plain
  protocol header with no VM values; `http_pico.c` calls `http_body.c`'s syntax
  helpers (`agc_http_token`, `agc_http_framing`, ...), so the two are one unit.
  `http_body.c` uses `agc_size_mul` and `agc_out_of_memory`, so an out-of-memory
  body still ends with exit 70 (§6.3).
- **yyjson has no adapter file.** `json.c`'s parser builds VM values straight
  from the yyjson tree (`convert`); a separate adapter would need an extra tree
  or VM values, so it would add code and replace none. Instead, the check
  (§15.5) keeps `yyjson.h` to `json.c`.
- **libuv streams stay in their owning services.** Services own their
  `uv_tcp_t`, `uv_pipe_t` and timers through `agc_io_uv`.
- **Files have a platform adapter.** `file_io.c` owns synchronous libuv file
  requests and `file_windows.c` owns native path conversion and error mapping.
  Their plain `file_io.h` interface carries no VM values. `files.c` retains
  validation, buffers, ownership and pool scheduling. Core files cannot
  include this header or call the adapter. The driver may use libuv directly
  in `launch.c` for executable discovery; `agentica.c` does not include it.
- **Services may call each other.** `http_server.c` uses `tcp.c` through
  `net.h` and `http_fields.c`; `tcp.c` and `http_wire.c` share the heads and the
  body text through `http_fields.h`; `json_typed.c` uses `json.c`, `json.c` and
  `testing.c` use `strings.c` helpers. That is fine inside a layer.

### 15.2 The port

The port is what a service needs from the core to do I/O and to wait, as §14
allows it. It has its own header, `port.h`, which declares every function
below.

- **Job:** Park and wake a task
  - **Functions:** `agc_task_park`, `agc_task_enqueue`, `agc_task_wake`,
    `agc_task_wake_all`; `agc_task_stepper` for a builtin that calls its block
    and also parks between the calls: it installs an `agc_stepper` on the task,
    and the interpreter then asks its `agc_step_fn` what to do next (call the
    block, park, or end), so no C code calls the interpreter
    (`docs/vm/03-ir-and-bytecode.md` §4.3, `File.each_line`)

- **Job:** Submit a job (loop or pool), with its timeout
  - **Functions:** `agc_io_start` with an `agc_io_kind` (`work`, `done`,
    `expired`, `drop`, `cancel`), `agc_io_ready`, `agc_io_detached` (its context
    is the handle a close job holds, or void), `agc_io_start_then` (a pool job's
    `more` step, which may keep it waiting on the loop)

- **Job:** Wait on a descriptor on the loop
  - **Functions:** `agc_poller_*` (a `uv_poll_t` that owns its descriptor;
    `files.c`, and `input.c` in the core)

- **Job:** Read standard input to its end (`FrontEnd.stdin_bytes`)
  - **Functions:** `agc_input_whole` (`input.c`), so the front end reads
    through the one stdin reader

- **Job:** Set a timer
  - **Functions:** no own function: an I/O deadline is the job's
    `timeout_ms`, and a wait with only a deadline (`Task.sleep`) is a task
    timer in the core (`agc_task_park_until`, §14.2). The three other timers
    of §14.2 use libuv through `agc_io_uv` and stay exceptions

- **Job:** Register, own and close a handle
  - **Functions:** `agc_register`, `agc_own` with an `agc_close_fn` (it takes
    the task that ends, which only the file close uses) and `agc_disown` (a
    server takes its listener off its owner's list), `agc_unregister` (it also
    takes the handle off its owner's list), `agc_resource_id`; the handle's lock
    FIFO: `agc_handle_wait`; the resource's `goodbye` hook (a release-shaped
    function the exit path calls through `agc_io_goodbye`; `tcp.c` sets it for
    TLS `close_notify`); the V3 field `keep_detached` (`process.c` sets it on a
    process's resource, so `discard` in `loop.c` does not release the process
    when a detached job's result is dropped)

- **Job:** Reach the loop and signals
  - **Functions:** `agc_io_uv`, `agc_io_block_stop` (around a fork or a thread
    start). The list of stop signals is static in `loop.c`; no service reads it

- **Job:** Spawn, wait for, cancel and observe tasks (for `Test.run`)
  - **Functions:** `agc_task_spawn_test` (the body of one test, which is its
    own test, with a seed set before it can run), `agc_task_spawn_owning`
    (24b: spawn a task and give it a handle that the caller owns;
    `Task.spawn_owning` and
    `HttpWire.spawn` call it), `agc_task_spawn_seeded` (spawn under a parent
    with the caller's random seed; every builtin spawn uses it), `agc_task_owns`
    (whether the calling task owns a handle value), `agc_task_close_done` (a
    file close job of an ended task has finished), `agc_task_cancel`,
    `agc_task_observe`, `agc_report_unobserved`, `agc_task_join` (V5)

- **Job:** Task groups (20c, for `http_server.c` and `http_service.c`)
  - **Functions:** `agc_task_group` (a parent node that never runs),
    `agc_task_service` (run a task that owns a handle under a root with no
    parent: no caller's crash, cancel or end reaches it, `Task.pending_count`
    and `Test.test` leave its tree out, and its timers are weak for the stall
    check; `HttpWire.service` calls it),
    `agc_task_spawn_seeded` (spawn under a given parent), `agc_task_cancel` to
    drop a subtree (every cancelled task closes the handles it owns as it ends,
    so there is no separate drop), and three task fields the service sets on its
    own tasks: the `end` hook with `end_data` (`agc_end_fn`, called once when
    the task ends in any way) and `hidden` (no await can observe the task, so
    its unobserved crashes keep one entry per test, §10.2.1)

- **Job:** Charge, fail, write
  - **Functions:** `agc_charge`, `agc_charge_bytes`, `agc_value_units`,
    `agc_fail`, `agc_fail_text`, `agc_exit`, `agc_write`,
    `agc_output_waiting`, `agc_drain`, `agc_flush` (`agc_write` takes the
    `agc_output` of stdout or stderr, the text and a flag for a trailing
    newline, and returns false when the task must park and retry;
    `agc_output_waiting` tells a builtin that its text already waits in the
    stream's FIFO, so it passes no text)

- **Job:** Program lookups
  - **Functions:** `agc_builtin_struct`

Behind the port sit the two queues of
[§16.4](16-architecture.md#164-two-directions): waking and enqueueing a task is
the push to the global run queue, and the requests to the I/O thread's inbox are
start, cancel, stop or extend its timer, release and the libuv steps of a job's
halves. With N = 1 they are direct calls on one thread
([§16.9](16-architecture.md#169-as-built)). A service reaches the queues
only through the port. The libuv code of a service runs in the start step of
the request, on the I/O thread (§16.9).

The core calls services back only through function pointers that a service
handed over: the job kind (`agc_io_kind`), `agc_close_fn` and `agc_release_fn`
of a resource, a task's `agc_end_fn` (20c), `agc_builtin_fn` of a builtin, and
the `agc_step_fn` of a stepper that a builtin installs on its task with
`agc_task_stepper` (7.2.1h). It never calls a service by name.

Services still read fields of the runtime structs (`agc_vm`, `agc_task`,
`agc_runtime`, `agc_resource`); making them opaque would not be a mechanical
change. The rule: a service may read the run's settings in `vm->rt` (`trace`,
`cwd`, `no_files`, `allow_run`, `program`, ...), the fields of a resource it
registered, and the per-task fields that exist for it (`cursor` for `strings.c`,
`random` for `numbers.c`, `test` and `test_run` for `testing.c`). It does not
walk or change the scheduler's lists; V6 is the one exception left.

### 15.3 Function-pointer tables

Allowed only where two real implementations are chosen at run time. Today there
is no such place, so the plan adds none:

- **TLS** has one implementation, `tls_openssl.c`, behind `tls.h`, chosen at
  link time. A second backend would be a second `.c` file behind the same
  header, still chosen by the Makefile; a table only if one binary needs both.
- **The loop backend** is not ours: libuv picks io_uring or epoll inside. The VM
  only sets `UV_USE_IO_URING=0` for itself (`loop.c`) and drops it from
  children's environment (`process.c`).
- **Platforms** are chosen at compile time, not through a table. The shared
  logic is written once; an operating system difference that libuv does not
  hide is a function of a platform adapter: a plain header plus one file per
  system family, each guarded whole (`file_io.h` and `file_windows.c`;
  `process_os.h` with `process_posix.c` and `process_windows.c`;
  `duplex_os.h` with `duplex_posix.c` and `duplex_windows.c`;
  `system_os.h` with `system_posix.c` and `system_windows.c`;
  `net_os.h` with `net_posix.c` and `net_windows.c`).
  Shared functions do not branch on `#ifdef`; older code that still does
  (`file_io.c`, and blocks in `files.c`, `loop.c`, `launch.c`, `process.c`,
  `input.c` and `output.c`) moves behind an adapter when a change adds a
  platform branch there.

The function pointers that exist are callbacks (job kinds, close and release
functions, builtins, `agc_conn_watch`), not tables of implementations, and they
stay.

### 15.4 Headers

Four headers in one chain; a `.c` file includes the header of its layer, so
nothing needs an umbrella.

```text
value.h  <-  port.h  <-  core.h
                     <-  services.h  <-  net.h
```

`port.h` includes `value.h`; `core.h` and `services.h` each include `port.h` and
nothing else of ours, so a service never gets `core.h` indirectly. Every type a
header's own declarations name is defined, or forward-declared, in that header
or one below it. `make vm-layers` compiles each `vm/*.h` on its own
(`cc -fsyntax-only` with the VM's flags, one per header, as
`-include h /dev/null`: as the main file, the unused `static inline` in
`trace.h` fails under `-Werror` with clang), so a missing type fails at once. A
core `.c` file includes `core.h`; a service `services.h`, or `net.h` or
`http_fields.h`, which include it; an adapter its own header (`http_body.c` also
`value.h`); the driver `core.h` and `services.h`. A test in `vm/tests/` includes
what it uses. What goes where:

- **`value.h`** (includes `trace.h`): the value types and their constructors
  and accessors, the opaque `agc_list` API, the Json value types and API, the
  program tables, opcodes, the builtin row types, memory, UTF-8, string, map,
  text and equality functions, every Unicode table, and the forward typedefs of
  `agc_vm`, `agc_task` and `agc_resource`. The handle value structs
  (`agc_process`, `agc_socket`, `agc_listener`, `agc_http_client`,
  `agc_http_server`) live here next to their constructors: they are anonymous
  typedefs, so they cannot be forward-declared. `agc_error_value` and
  `agc_utf8_count` are here too (V4, V15).
- **`port.h`**: the body of `struct agc_resource`, the runtime structs
  (`agc_runtime`, `struct agc_task`, `struct agc_vm`), the stepper types
  (`agc_stepper` has one member, its `agc_step_fn`, which a service's state
  struct starts with), `agc_io_kind`, the outcome and stack types, the stdin
  types, and the port functions of §15.2. It includes `<signal.h>` and
  `<locale.h>` on Linux and macOS.
- **`core.h`**: what only the core and the driver call: `agc_vm_init`, tasks
  and turns, the numeric opcode helpers (`agc_op_add_i` ... `agc_op_same`,
  defined in `interp.c`: pure functions on `agc_value` that the interpreter and
  a future JIT share, which fail through `agc_fail` and leave the step and
  turn-cost accounting to the caller), the loop's own life, the exit path and
  stop signals, ownership internals, the loader, the builtin table list and the
  core tables, the stdin and stdout/stderr internals, and the diagnostics
  printers.
- **`services.h`**: the body of `struct agc_test_note`, `agc_inbuf`, the
  helpers of `strings.c`, the JSON parser and typed JSON, the exports of
  `files.c`, `tree.c` and `process.c` that others call, the stream kit, the
  child channel (`agc_duplex_*`, `agc_parent_*`) and the builtin tables of the
  services.
- **`list_impl.h`** (includes `value.h`; private to the core): `struct agc_list`
  (`{ len, root, shift, kind, tail[] }`), the node type of the 32-way trie and
  the `static inline` fast versions of `agc_list_len` and `agc_list_get`
  (`list_len`, `list_get` and `list_at`, which skips the bounds check for a
  caller that has made it). They read an item of the tail in line, with one
  compare, and call `agc_list_trie_get` (defined in `list.c`) for an item in
  the trie, which keeps `agc_run_turn` as small as it was. Only `list.c`, which
  defines the list API, and `interp.c`, whose `LIST_LEN` and `LIST_GET` run once
  per item of a `for` loop, include it, so a loop over a list of up to 32 items
  makes no call per item. `vm/tests/list_test.c` includes it too, to check the
  shape of the trie. Every other file keeps the opaque API, so a site that reads
  the layout outside these files does not compile.

`net.h` (the `agc_conn` API of `tcp.c`, used by `http_server.c`) and
`http_fields.h` include `services.h`; `net.h` also includes `tls.h`. `tls.h`,
`http_parse.h` and `trace.h` include nothing of ours.

### 15.5 The layer check

`make vm-layers` (it depends on `vm`) does three things: it compiles each header
on its own (§15.4), runs `vm/tools/check-layers.sh <object dir>`, and runs the
negative self-test, `vm/tools/check-layers-test.sh`. CI runs it in the
`vm-sanitizers` job of `ci.yml`, on the objects of the sanitizer build. The
script fails when:

1. a `vm/*.c` or `vm/*.h` file is in no list, or a listed file does not exist;
2. a core file includes `services.h`, `net.h`, `tls.h`, `digest.h`,
   `http_parse.h` or `http_fields.h`;
3. a service or adapter file includes `core.h`;
4. an adapter file includes `port.h`, `services.h`, `net.h` or `http_fields.h`
   (it may include `value.h`; rule 8 keeps it to the memory functions);
5. a third-party header is included outside its place (the `only` calls of the
   script): `<gc.h>` only in `value.c`, `<openssl/...>`, `<picohttpparser.h>`
   and `"yyjson.h"` only in their one adapter or service file, and `<uv.h>`
   only in the loop, the stream services and a few core files that need only a
   mutex or an async handle (`runq.c`, `sync.c` and `inbox.c` use `uv_mutex_t`,
   the one mutex type that also builds on Windows, and `uv_async_t`, which wakes
   the loop). `input.c` and `files.c` put stdin, FIFOs and character devices on
   loop handles through `agc_poller_*` (§15.2) and include no libuv header;
6. a `.c` file declares an `agc_` name at file scope instead of taking it from a
   header: a function prototype, or an `extern` or array declaration of an
   `agc_` variable (`extern char **environ` in `process.c` is not an `agc_`
   name);
7. **the link rule**: after the build, a core object's undefined symbols
   (`nm -u`) include a symbol that a service or adapter object defines
   (`nm -g --defined-only`). The driver is left out: `builtins.o` reads
   `agc_builtin_tables` from `builtin_tables.o` by design (§15.6 V2);
8. an adapter object's undefined `agc_` symbols are other than the memory
   functions of §15.1 and symbols of another adapter object (`http_pico.o` uses
   `http_body.o`);
9. the header chain: each header includes only the header below it in the chain
   of §15.4 (`net.h` also `tls.h`; `http_fields.h` also `http_parse.h`;
   `list_impl.h` only `value.h`), and `tls.h`, `http_parse.h` and `trace.h`
   none of ours;
10. `list_impl.h` is included (by any path, in `vm/` and `vm/tests/`) from a
    file other than `list.c`, `interp.c` and `tests/list_test.c`.

The link rules (7, 8) are the authority: a declaration that rule 6 misses still
fails there. Rules 1 to 6, 9 and 10 need no build and give a fast, readable
error. An `rg` exit status of 2 (a bad pattern, a missing file) is a failure,
not "no match", and so is a missing object. The link rules read ELF symbols: on
macOS `nm` prints a leading `_` and has no `--defined-only`, so the script stops
with a message off Linux instead of passing.

The self-test works on a temporary copy of `vm/*.c`, `vm/*.h` and the objects.
The unchanged copy must pass. Then it plants one violation at a time, and each
must fail with its own message: a text one for rules 1 to 6, 9 and 10, and two
link ones. The link ones are a core file that calls `agc_utf8_encode` through a
typedef'd declaration (`plant_fn agc_utf8_encode;`), which rule 6 misses, so
only rule 7 sees it, and an adapter that calls `agc_error_value` (rule 8). They
rebuild the planted object with the VM's compiler flags before the script runs,
so the script never reads a stale object. CI checks the sanitizer objects; run
`make vm-layers` on the release objects locally too, to cover code that a
configuration turns off.

### 15.6 Violations found

Found by listing, for each `vm/*.c` file, the `agc_` functions it calls that
another file defines, and checked against `nm` (the link rule of §15.5 now
does it). Each row is a place where the core names a service or service data,
or a layer reaches past the port. V1 to V5, V10 and V15 are fixed; the others
are accepted, with the reason.

- **#:** V1
  - **Where:** `text.c`, `equal.c`
  - **What:** `to_s`, `inspect` and `==` of a `Json` value call
    `agc_json_encode` in `json.c` (a service)
  - **Fix:** **Move (done).** The Json value is a core type (`AGC_T_JSON`), so
    its code is in a core file, `json_value.c`: the writer, `agc_json_from`,
    the node constructors and finders, and the node code shared with the
    parser (`agc_json_container`, `agc_json_store` and `agc_json_finish`, which
    sorts the members by key bytes and drops repeated keys). `json.c` keeps the
    yyjson parser, `agc_json_status_message`, `agc_json_to_float` and the
    `JSON.*` builtins; `agc_json_decode` and `agc_json_schema` stay in
    `json_typed.c`

- **#:** V2
  - **Where:** `builtins.c`
  - **What:** the builtin table list names every service's table
    (`agc_file_builtins`, `agc_tcp_builtins`, `agc_test_builtins`, ...)
  - **Fix:** **Move (done)** of the list, in the same order (`agc_find_builtin`
    returns the first match), to the driver file `builtin_tables.c`:
    `agc_builtin_tables` and `agc_builtin_table_count`. `agc_find_builtin` stays
    in `builtins.c` and reads the list through `core.h`. `builtins.c` exports
    its own table as `agc_core_builtins` with `agc_core_builtin_count`, like the
    other libraries. The list is the one place that wires the services in, like
    `main.c`

- **#:** V3
  - **Where:** `loop.c` (`discard`)
  - **What:** `discard` (a detached job's result) skipped `AGC_T_PROCESS` by
    name: a process rule in the loop
  - **Fix:** **Port data (done).** The tag check became an `agc_resource`
    field, `keep_detached`, that `process.c` sets when it registers the process;
    `discard` reads the field, not the tag

- **#:** V4
  - **Where:** `task.c`
  - **What:** `await_task` and `builtin_unobserved_crash` build their error with
    `agc_error_value`, which was defined in `stream.c` (a service)
  - **Fix:** **Move (done)** of `agc_error_value` to `value.c`, next to
    `agc_make_string`

- **#:** V5
  - **Where:** `testing.c`
  - **What:** `Test.run` had a `wait_for` that set `vm->task->awaiting`, put the
    task on `target->waiters` and parked: the waiting half of `await_task`,
    without its crashed and cancelled branches
  - **Fix:** **Port function (done)** `bool agc_task_join(agc_vm *vm, agc_task
    *target)` in `task.c`: if the target is done, clear `awaiting` and
    return false; else set `awaiting`, enqueue the task on the target's waiters,
    park (with retry) and return true. `Test.run` and `await_task` call it;
    `await_task` handles the result (crashed, cancelled, value) after false

- **#:** V6
  - **Where:** `testing.c` (`cancel_leftovers`, `unobserved_of`, `observe_test`)
  - **What:** they walk `caller->children` and `rt->crashes` and read `t->test`
  - **Fix:** **Accepted for now.** Reads only, and every change goes through
    `agc_task_cancel` and `agc_task_observe`. 24b's one hand-off form may give a
    task group to replace them; if it does, they move behind the port then

- **#:** V7
  - **Where:** `loop.c` (`agc_owned_of`)
  - **What:** the core reads the `state` field of `agc_socket`, `agc_listener`
    and `agc_process`
  - **Fix:** **Accepted**: those handle values are declared in `value.h`, since
    ownership (§14.5) must find a value's resource. Its callers are
    `agc_task_spawn_owning` in `task.c` and `discard` in `loop.c`

- **#:** V8
  - **Where:** `value.h` (`agc_tag` and the inline constructors and `agc_as_*`),
    `value.c` (the service resources'); `text.c`
  - **What:** the tag enum, constructors, `agc_as_*` and the printed names
    (`<Socket>`, `<Process>`, ...) of service values live in the core
  - **Fix:** **Accepted**: the tag set is one closed enum that the loader,
    `text.c` and `equal.c` need; no service code is called

- **#:** V9
  - **Where:** `port.h` (`struct agc_task`, `struct agc_vm`, `agc_runtime`),
    `task.c`
  - **What:** service state in core structs: `agc_task`'s `test`, `note` and
    `test_run` (a spawned task inherits `test`), `agc_vm.process_guard`, and the
    `allow_run`, `drop_uring_env` and `no_files` settings
  - **Fix:** **Accepted**: opaque pointers and settings, no calls. The driver
    sets the settings

- **#:** V10
  - **Where:** `output.c`, `input.c`
  - **What:** 25b's `mid_line` and `agc_write_record`, the reserved stdin and
    `agc_protocol_line` (core code that exists for `testing.c`)
  - **Fix:** **Removed (done, 25c, row 7.2.1a):** the child protocol moved to fd
    3 (`vm/duplex.c`); those four are gone

- **#:** V11
  - **Where:** `agentica.c`, `launch.c`
  - **What:** the driver calls `agc_files_init`, `agc_files_close`,
    `agc_parent_take`, `agc_tls_version` and `agc_json_version`
  - **Fix:** **Accepted**: `agentica.c` is the driver

- **#:** V12
  - **Where:** `http_body.c`
  - **What:** an adapter calls `agc_size_mul` and `agc_out_of_memory`
  - **Fix:** **Accepted**: memory only, so out of memory keeps its exit code
    (§6.3); rule 8 of §15.5 keeps it to memory

- **#:** V13
  - **Where:** `loop.c` (`agc_owned_of`), 20c
  - **What:** the core reads the `state` field of `agc_http_server` too, so a
    server passed to `Task.spawn_owning` can be handed over
  - **Fix:** **Accepted with V7**, for the same reason. 24b kept the lookup in
    `agc_task_spawn_owning`; the fix, if it is ever wanted, is a resource found
    through a field the service sets at `agc_register`, not a tag list in the
    core

- **#:** V14
  - **Where:** `task.c` (`quiet_slot`), 20c
  - **What:** the crash list reads `hidden` and `t->test` to keep one entry per
    test for HTTP connection tasks
  - **Fix:** **Accepted with V6**: a flag the service sets, read by the core; no
    service call

- **#:** V15
  - **Where:** `json_value.c` (`agc_json_encode`)
  - **What:** once V1 moved the Json writer into the core, it counted the
    characters of its output with `agc_utf8_count`, which `strings.c` (a
    service) defined
  - **Fix:** **Move (done)** of `agc_utf8_count` to `value.c`, with the other
    UTF-8 functions; it is in `value.h`, not `services.h` (§15.4)

Not violations: `loader.c` calls `agc_find_builtin` (core); the core's other
cross-file calls stay inside the core; the services call the core only through
the functions of §15.2 and the value API.

### 15.7 Implementation PRs

Both implementation PRs (the moves, then the headers and the check) are done;
the order of the VM rows is in the roadmap. A PR that adds a `vm/*.c` file puts
it in a layer list, and a reviewer checks a new port function against §14 like
any core change.
