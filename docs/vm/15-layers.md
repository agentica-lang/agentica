## 15. VM layers

**Status:** built (row 7.2.1b of the [roadmap](../roadmap/README.md),
checklist in [`07-vm.md`](../roadmap/07-vm.md#7l-vm-layers)). It follows the
architecture note [§16](16-architecture.md).

The C VM has three layers (core, services, adapters) with one-way dependencies,
a driver that wires them, one port between the services and the core, one header
per layer, and a CI check for the direction. Calls stay direct. It is not DDD
and not a plugin system.

Words. §14 calls everything under the scheduler "the VM core". Here **core** is
narrower: the scheduler, the loop, the values and what they need. §14's five
rules hold for the core and the services alike.

§14.6 asks of the layers: "Does each layer replace code, or only add a
boundary?" Answer: mostly a boundary, checked by CI. It adds no runtime concept.

### 15.1 Layers

The files of each layer are the lists at the top of `vm/tools/check-layers.sh`.
A new `vm/*.c` file goes in one of them.

- **Layer:** **Core**
  - **What:** values, the interpreter, the scheduler and the loop
  - **May use:** `value.h`, `port.h`, `core.h`, `trace.h`, Boehm GC, libuv

- **Layer:** **Services**
  - **What:** the libraries and handle kinds built on the port (strings,
    numbers, JSON, files, processes, TCP, HTTP, logger, `Test`)
  - **May use:** `value.h`, `port.h`, `services.h`, `net.h`, `trace.h`, adapter
    headers, libuv, yyjson (`json.c` only)

- **Layer:** **Adapters**
  - **What:** one wrapper of a library or one operating-system side, each behind
    its own plain header (§15.3)
  - **May use:** their own header, their library, and from `value.h` only the
    memory functions (`agc_alloc`, `agc_alloc_atomic`, `agc_size_add`,
    `agc_size_mul`, `agc_out_of_memory`)

- **Layer:** **Driver** (not a layer: it wires them)
  - **What:** `agentica.c`, `launch.c`, `builtin_tables.c` (§15.6 V2), the
    fuzz harness and the libFuzzer entry point
  - **May use:** everything

`vm/tests/*.c` may use everything. `trace.h` is shared by every layer but the
adapters.

Notes on the choices:

- **`unicode_data.c` is core.** It is generated data, not a library wrapper.
  `text.c` prints with its ranges, and the case tables that `strings.c` uses are
  declared in `value.h`.
- **`channel.c` is core.** Its waiters are a list the scheduler owns.
  `agc_task_cancel` removes a task through `agc_channel_leave`, so the code
  cannot sit in a service the core may not name.
- **`task_map.c` is core.** `Task.map` parks its caller in a stepper on a task
  timer (`vm/timers.c`), so it can use only what the core offers.
- **`input.c`, `output.c`, `stdio_posix.c`, `stdio_windows.c` and `builtins.c`
  are core.** The stdin, stdout and stderr waiters are lists the scheduler owns
  (§14.1). `builtins.c` holds the core builtins and `agc_find_builtin`, which
  the loader calls. `stdio_posix.c` and `stdio_windows.c` are the
  operating-system side of `output.c`, one file per family. `output.c` has no
  `#ifdef` for an OS. `poll_posix.c` and `poll_windows.c` are core in the same
  way: the operating-system side of the copy that a `Native.wait_*` poller of
  `loop.c` polls.
- **`stream.c` is a service.** It is the kit the stream services share; only
  `duplex.c`, `process.c` and `tcp.c` use it.
- **`duplex.c` is a service (25c).** It owns the child channel: one
  bidirectional stream per channel end, and the child-side builtins
  `Process.parent_read_line` and `Process.parent_send`. Its waits are jobs with
  the call's timeout, its locks are the stream kit's, and it adds nothing to the
  port.
- **`http_body.c` is an adapter, with `http_pico.c`.** `http_parse.h` is a plain
  protocol header with no VM values. `http_pico.c` calls the syntax helpers of
  `http_body.c`, so the two are one unit. The body code uses only the memory
  functions, so an out-of-memory body still ends with exit 70 (§6.3).
- **yyjson has no adapter file.** `json.c`'s parser builds VM values straight
  from the yyjson tree. An adapter would add a tree or a copy and replace
  nothing. The check (§15.5, rule 5) keeps `yyjson.h` to `json.c`.
- **libuv streams stay in their owning services.** Services own their
  `uv_tcp_t`, `uv_pipe_t` and timers through `agc_io_uv`.
- **Files have a platform adapter.** `file_io.c` owns the synchronous libuv file
  requests, and `file_windows.c` owns native paths and error mapping, behind a
  plain `file_io.h` with no VM values. `files.c` keeps validation, buffers,
  ownership and pool scheduling. Core files cannot include the header.
  `launch.c` may use libuv for executable discovery; `agentica.c` does not.
- **Services may call each other** inside their layer, as `http_server.c` calls
  `tcp.c` through `net.h`.

### 15.2 The port

The port is what a service needs from the core to do I/O and to wait, as §14
allows. Its header, `port.h`, declares every function below.

- **Job:** park and wake a task
  - **Functions:** `agc_task_park`, `agc_task_enqueue`, `agc_task_wake`,
    `agc_task_wake_all`; `agc_task_stepper`, for a builtin that calls its block
    and parks between the calls. The interpreter asks the stepper's
    `agc_step_fn` what to do next (call the block, park, or end), so no C code
    calls the interpreter (`docs/vm/03-ir-and-bytecode.md` §4.3)

- **Job:** submit a job (loop or pool), with its timeout
  - **Functions:** `agc_io_start` with an `agc_io_kind` (`work`, `done`,
    `expired`, `drop`, `cancel`), `agc_io_ready`, `agc_io_detached`,
    `agc_io_start_then` (a pool job's `more` step)

- **Job:** wait on a descriptor on the loop
  - **Functions:** `agc_poller_*` (a `uv_poll_t` that owns its descriptor)

- **Job:** read standard input to its end (`FrontEnd.stdin_bytes`)
  - **Functions:** `agc_input_whole`, so the front end uses the one stdin reader

- **Job:** set a timer
  - **Functions:** none of its own. An I/O deadline is the job's `timeout_ms`. A
    deadline-only wait (`Task.sleep`) is a core task timer
    (`agc_task_park_until`, §14.2). The other timers of §14.2 use libuv through
    `agc_io_uv` and stay exceptions

- **Job:** register, own and close a handle
  - **Functions:** `agc_register`, `agc_own` (with an `agc_close_fn`),
    `agc_disown` (a server takes its listener off its owner's list),
    `agc_unregister`, `agc_resource_id`, `agc_handle_wait` (the handle's lock
    FIFO); the resource's `goodbye` hook, called through `agc_io_goodbye`
    (`tcp.c` sets it to close a socket, TLS `close_notify` first); and
    `keep_detached`, which `process.c` sets so that `discard` in `loop.c` does
    not release a process whose detached result is dropped

- **Job:** reach the loop and signals
  - **Functions:** `agc_io_uv`, `agc_io_block_stop` (around a fork or a thread
    start). The stop-signal list is static in `loop.c`; no service reads it

- **Job:** spawn, wait for, cancel and observe tasks
  - **Functions:** `agc_task_spawn_test` (one test, seeded before it runs),
    `agc_task_spawn_owning` (a task that gets a handle the caller owns;
    `Task.spawn_owning` and `HttpWire.spawn` call it), `agc_task_spawn_seeded`
    (under a parent, with the caller's random seed), `agc_task_owns`,
    `agc_task_close_done`, `agc_task_cancel`, `agc_task_observe`,
    `agc_report_unobserved`, `agc_task_join`

- **Job:** task groups
  - **Functions:** `agc_task_group` (a parent node that never runs) and
    `agc_task_service`, which runs a task that owns a handle under a root with
    no parent. No caller's crash, cancel or end reaches it, and
    `Task.pending_count` and `Test.test` leave it out. `HttpWire.service` calls
    it. Its tasks get an `end` hook (`agc_end_fn` with `end_data`) and `hidden`,
    so no await observes them and their unobserved crashes keep one entry per
    test (§10.2.1)

- **Job:** charge, fail, write
  - **Functions:** `agc_charge`, `agc_charge_bytes`, `agc_value_units`,
    `agc_fail`, `agc_fail_text`, `agc_exit`, `agc_write`, `agc_output_waiting`,
    `agc_drain`, `agc_flush`. `agc_write` returns false when the task must park
    and retry. `agc_output_waiting` tells a builtin that its text already waits
    in the stream's FIFO, so it passes no text

- **Job:** program lookups
  - **Functions:** `agc_builtin_struct`

Behind the port are the two queues of
[§16.4](16-architecture.md#164-two-directions): the run queue (a waking task is
pushed onto it) and the I/O thread's inbox (start, cancel, stop or extend a
timer, release, and the libuv steps of a job). With N = 1 they are direct calls
([§16.9](16-architecture.md#169-as-built)). A service reaches them only through
the port.

The core calls services back only through function pointers that a service
handed over: `agc_io_kind`, `agc_close_fn` and `agc_release_fn` of a resource,
`agc_end_fn`, `agc_builtin_fn` and `agc_step_fn`. It never calls a service by
name.

Services may still read fields of the runtime structs: the settings in `vm->rt`
(`trace`, `cwd`, `no_files`, `deny_run`, `program`, ...), their own resources,
and their per-task fields (`cursor` for `strings.c`, `random` for `numbers.c`,
`test` and `test_run` for `testing.c`). A service does not walk or change the
scheduler's lists; V6 is the one exception left.

### 15.3 Function-pointer tables

Tables of implementations are allowed only where two real implementations are
chosen at run time. None exists.

- **TLS** has one implementation, `tls_openssl.c`, behind `tls.h`, chosen at
  link time. A second backend would be another file behind the same header; a
  table only if one binary needs both.
- **The loop backend** is libuv's choice (io_uring or epoll). The VM only sets
  `UV_USE_IO_URING=0` for itself (`loop.c`) and drops it from children
  (`process.c`).
- **Platforms** are chosen at compile time. An operating-system difference that
  libuv does not hide goes in a platform adapter: a plain header plus one file
  per system family, each guarded whole (`file_io.h` with `file_windows.c`;
  `process_os.h`, `duplex_os.h`, `system_os.h` and `net_os.h`, each with a
  `*_posix.c` and a `*_windows.c`). Shared code does not branch on `#ifdef`.
  Older code that still does (`file_io.c`, and blocks in `files.c`, `loop.c`,
  `launch.c`, `process.c`, `input.c` and `output.c`) moves behind an adapter
  when a change adds a platform branch there.

The existing function pointers are callbacks (job kinds, close and release
functions, builtins, `agc_conn_watch`), not tables of implementations. They
stay.

### 15.4 Headers

Four headers in one chain. A `.c` file includes the header of its layer, so
nothing needs an umbrella.

```text
value.h  <-  port.h  <-  core.h
                     <-  services.h  <-  net.h
```

`core.h` and `services.h` each include `port.h` and nothing else of ours, so a
service never gets `core.h` indirectly. Every type a header names is defined, or
forward-declared, in that header or one below it. `make vm-layers` compiles each
`vm/*.h` on its own (`cc -fsyntax-only`, as `-include h /dev/null`: as a main
file, the unused `static inline` in `trace.h` fails under `-Werror` with clang).
Each `.c` file includes the header of its layer: `core.h` for the core,
`services.h` (or `net.h`) for a service, its own header for an adapter, and
`core.h` and `services.h` for the driver.

- **`value.h`** (includes `trace.h`): the value types and their constructors and
  accessors, the opaque `agc_list` API, the Json value API, the program tables,
  opcodes, the builtin row types, memory, UTF-8, string, map, text and equality
  functions, the Unicode tables, and the forward typedefs of `agc_vm`,
  `agc_task` and `agc_resource`. The handle value structs (`agc_process`,
  `agc_socket`, `agc_listener`, `agc_http_client`, `agc_http_server`) live here
  because they are anonymous typedefs, which cannot be forward-declared.
- **`port.h`**: the body of `struct agc_resource`, the runtime structs
  (`agc_runtime`, `struct agc_task`, `struct agc_vm`), the stepper types
  (`agc_stepper` has one member, its `agc_step_fn`, which a service's state
  struct starts with), `agc_io_kind`, the outcome and stack types, the stdin
  types, and the port functions of §15.2.
- **`core.h`**: what only the core and the driver call: `agc_vm_init`, tasks and
  turns, the opcode helpers (`agc_op_add_i` ... `agc_op_list_get`, defined in
  `interp.c`; they return an `agc_status` instead of failing, which
  `agc_op_fail` turns into the failure, and leave the step and turn-cost
  accounting to the caller, so a future JIT can share them; §22), the loop's
  life, the exit path, ownership internals, the loader, the builtin table list,
  and the diagnostics printers.
- **`services.h`**: `agc_inbuf`, the helpers of `strings.c`, the JSON parser and
  typed JSON, the exports of `files.c`, `tree.c` and `process.c` that others
  call, the stream kit, the child channel (`agc_duplex_*`, `agc_parent_*`) and
  the builtin tables of the services.
- **`list_impl.h`** (includes `value.h`; private to the core): `struct agc_list`
  (`{ len, root, shift, kind, tail[] }`), the node type of the 32-way trie, and
  the `static inline` fast paths `list_len`, `list_get` and `list_at`. They read
  the tail in line and call `agc_list_trie_get` (in `list.c`) for the trie,
  which keeps `agc_run_turn` small. Only `list.c`, `interp.c` and
  `vm/tests/list_test.c` include it. `interp.c` needs it because its `LIST_LEN`
  and `LIST_GET` run once per item of a `for` loop, so a loop over up to 32
  items makes no call per item. Every other file keeps the opaque API, so code
  that reads the layout outside these files does not compile.

`net.h` (the `agc_conn` API of `tcp.c`) and `http_fields.h` include
`services.h`; `net.h` also includes `tls.h`. `tls.h`, `http_parse.h` and
`trace.h` include nothing of ours.

### 15.5 The layer check

`make vm-layers` (it depends on `vm`) compiles each header on its own (§15.4)
and runs `vm/tools/check-layers.sh <object dir>` and its negative self-test,
`vm/tools/check-layers-test.sh`. CI runs it in the `vm-sanitizers` job of
`ci.yml`, on the sanitizer objects. The script fails when:

1. a `vm/*.c` or `vm/*.h` file is in no list, or a listed file does not exist;
2. a core file includes `services.h`, `net.h`, `tls.h`, `digest.h`,
   `http_parse.h` or `http_fields.h`;
3. a service or adapter file includes `core.h`;
4. an adapter file includes `port.h`, `services.h`, `net.h` or `http_fields.h`
   (it may include `value.h`; rule 8 keeps it to the memory functions);
5. a third-party header is included outside its place: `<gc.h>` only in
   `value.c`; `<openssl/...>`, `<picohttpparser.h>` and `"yyjson.h"` only in
   their one adapter or service file; `<uv.h>` only in the loop, the stream
   services and the core files that need only `uv_mutex_t` (the one mutex type
   that also builds on Windows) or `uv_async_t` (`runq.c`, `sync.c`, `inbox.c`).
   `input.c` and `files.c` use `agc_poller_*` (§15.2) and include no libuv
   header;
6. a `.c` file declares an `agc_` name at file scope instead of taking it from a
   header (a prototype, or an `extern` or array declaration of an `agc_`
   variable; `extern char **environ` in `process.c` is not one);
7. **the link rule**: a core object's undefined symbols (`nm -u`) include a
   symbol that a service or adapter object defines (`nm -g --defined-only`). The
   driver is left out: `builtins.o` reads `agc_builtin_tables` from
   `builtin_tables.o` by design (§15.6 V2);
8. an adapter object's undefined `agc_` symbols are other than the memory
   functions of §15.1 and symbols of another adapter object (`http_pico.o` uses
   `http_body.o`);
9. a header includes a header other than the one below it in the chain of §15.4
   (`net.h` also `tls.h`; `http_fields.h` also `http_parse.h`; `list_impl.h`
   only `value.h`), or `tls.h`, `http_parse.h` or `trace.h` includes one of
   ours;
10. `list_impl.h` is included, by any path in `vm/` or `vm/tests/`, from a file
    other than `list.c`, `interp.c` and `vm/tests/list_test.c`.

The link rules (7, 8) are the authority: a declaration that rule 6 misses still
fails there. Rules 1 to 6, 9 and 10 need no build and give a fast, readable
error. An `rg` exit status of 2 (a bad pattern, a missing file) is a failure,
not "no match", and so is a missing object. The link rules read ELF symbols. On
macOS `nm` prints a leading `_` and has no `--defined-only`, so the script stops
with a message off Linux instead of passing.

The self-test runs on a temporary copy of the sources and objects. The unchanged
copy must pass. Then it plants one violation at a time, and each must fail with
its own message. Two plants are link ones: a core file that calls
`agc_utf8_encode` through a typedef'd declaration (`plant_fn agc_utf8_encode;`),
which rule 6 misses, so only rule 7 sees it, and an adapter that calls
`agc_error_value` (rule 8). The planted object is rebuilt with the VM's flags
first, so the script never reads a stale object. Run `make vm-layers` on the
release objects locally too, to cover code that a configuration turns off.

### 15.6 Violations found

Each row is a place where the core names a service, or a layer reaches past
the port (rule 7 of §15.5 checks them with `nm`). V1 to V5 are fixed; the
others are accepted, with the reason.

- **V1 to V5, fixed:**
  - V1: the Json writer moved to the core (`json_value.c`).
  - V2: the builtin table list moved to the driver file `builtin_tables.c`
    (`agc_builtin_tables`, in the old order, since `agc_find_builtin` returns
    the first match), the one place that wires the services in.
  - V3: `discard` reads the resource field `keep_detached` instead of a tag.
  - V4: `agc_error_value` moved to `value.c`.
  - V5: `Test.run` waits through the port function `agc_task_join`.

- **#:** V6
  - **Where:** `testing.c` (`cancel_leftovers`, `unobserved_of`, `observe_test`)
  - **What:** they walk `caller->children` and `rt->crashes` and read `t->test`
  - **Fix:** **Accepted for now.** They only read, and every change goes through
    `agc_task_cancel` and `agc_task_observe`. 24b's one hand-off form may give a
    task group to replace them; if it does, they move behind the port then

- **#:** V7
  - **Where:** `loop.c` (`agc_owned_of`)
  - **What:** the core reads the `state` field of `agc_socket`, `agc_listener`
    and `agc_process`
  - **Fix:** **Accepted**: ownership (§14.5) must find a value's resource, so
    those values are declared in `value.h`

- **#:** V8
  - **Where:** `value.h` (`agc_tag`, `agc_as_*`), `value.c`, `text.c`
  - **What:** the tag enum and the printed names (`<Socket>`, `<Process>`, ...)
    of service values live in the core
  - **Fix:** **Accepted**: one closed enum that the loader, `text.c` and
    `equal.c` need; no service code is called

- **#:** V9
  - **Where:** `port.h` (`struct agc_task`, `struct agc_vm`, `agc_runtime`),
    `task.c`
  - **What:** service state in core structs (`agc_task`'s `test`, `note` and
    `test_run`, `agc_vm.process_guard`) and the settings `deny_run`,
    `drop_uring_env` and `no_files`
  - **Fix:** **Accepted**: opaque pointers and settings, no calls. The driver
    sets the settings

- **#:** V11
  - **Where:** `agentica.c`, `launch.c`
  - **What:** the driver calls `agc_files_init`, `agc_files_close`,
    `agc_parent_take`, `agc_tls_version` and `agc_json_version`
  - **Fix:** **Accepted**: `agentica.c` is the driver

- **#:** V12
  - **Where:** `http_body.c`
  - **What:** an adapter calls `agc_size_mul` and `agc_out_of_memory`
  - **Fix:** **Accepted**: memory only, so out of memory keeps its exit code
    (§6.3)

- **#:** V13
  - **Where:** `loop.c` (`agc_owned_of`), 20c
  - **What:** the core reads the `state` field of `agc_http_server` too, so a
    server passed to `Task.spawn_owning` can be handed over
  - **Fix:** **Accepted with V7.** If it is ever wanted, the fix is a resource
    found through a field the service sets, not a tag list in the core

- **#:** V14
  - **Where:** `task.c` (`quiet_slot`), 20c
  - **What:** the crash list reads `hidden` and `t->test` to keep one entry per
    test for HTTP connection tasks
  - **Fix:** **Accepted with V6**: a flag the service sets, read by the core

Not violations: `loader.c` calls `agc_find_builtin` (core), and the core's other
cross-file calls stay inside the core.

### 15.7 New files

A PR that adds a `vm/*.c` file puts it in a layer list, and a reviewer checks a
new port function against §14 like any core change.
