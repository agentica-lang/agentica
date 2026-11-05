## 15. VM layers

**Status:** built (row 7.2.1b; checklist in
[`07-vm.md`](../roadmap/07-vm.md#7l-vm-layers)). It follows the architecture
note [§16](16-architecture.md).

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
  `loop.c` polls; so are `clock_posix.c` and `clock_windows.c`, the coarse clock
  of `timers.c`.
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
allows. `port.h` declares it (read it for the functions); it covers:

- parking and waking tasks, and `agc_task_stepper`, for a builtin that calls its
  block and parks between the calls: the interpreter asks the stepper's
  `agc_step_fn` what to do next (call the block, park, or end), so no C code
  calls the interpreter (§4.3 of `03-ir-and-bytecode.md`);
- submitting a job to the loop or the pool with its timeout (`agc_io_start` with
  an `agc_io_kind`), and `agc_poller_*` for a descriptor on the loop;
- registering, owning and closing a handle (`agc_register`, `agc_own`,
  `agc_disown`, `agc_handle_wait`). A resource's `goodbye` hook runs through
  `agc_io_goodbye` (`tcp.c` closes a socket with TLS `close_notify` first), and
  `keep_detached` makes `discard` in `loop.c` leave a process alone when its
  detached result is dropped;
- spawning, cancelling, joining and observing tasks (`agc_task_spawn_*`,
  `agc_task_cancel`, `agc_task_observe`), and groups: `agc_task_group` is a
  parent node that never runs, and `agc_task_service` runs a task that owns a
  handle under a root with no parent, so no caller's crash, cancel or end
  reaches it, and `Task.pending_count` and `Test.test` leave it out. Its tasks
  get an `end` hook and `hidden`, so no await observes them and their unobserved
  crashes keep one entry per test (§10.2.1);
- charging, failing and writing (`agc_charge`, `agc_fail`, `agc_write`).
  `agc_write` returns false when the task must park and retry, and
  `agc_output_waiting` tells a builtin that its text already waits in the
  stream's FIFO, so it passes no text.

There is no timer function: an I/O deadline is the job's `timeout_ms`, a
deadline-only wait (`Task.sleep`) is a core task timer (`agc_task_park_until`,
§14.2), and the other timers of §14.2 use libuv through `agc_io_uv` and stay
exceptions. `agc_io_block_stop` wraps a fork or a thread start, and
`agc_input_whole` lets the front end use the one stdin reader.

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
  accounting to the caller, so a future JIT can share them; §6.4), the loop's
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
fails there. The other rules need no build and give a fast, readable error. The
link rules read ELF symbols, so the script stops with a message off Linux
instead of passing. The self-test plants one violation at a time in a temporary
copy, and each must fail with its own message, including two link plants that
only rules 7 and 8 see. Run `make vm-layers` on the release objects locally too,
to cover code that a configuration turns off.

### 15.6 Violations found

Places where the core names a service, or a layer reaches past the port (rule
7 of §15.5 checks them with `nm`). V1 to V5 are fixed; the others are accepted.

- **V1 to V5, fixed:** the Json writer moved to the core (`json_value.c`); the
  builtin table list moved to the driver file `builtin_tables.c`
  (`agc_builtin_tables`, in the old order, since `agc_find_builtin` returns the
  first match; V2); `discard` reads the resource field `keep_detached` instead
  of a tag; `agc_error_value` moved to `value.c`; `Test.run` waits through
  `agc_task_join`.
- **V6, accepted for now:** `testing.c` (`cancel_leftovers`, `unobserved_of`,
  `observe_test`) walks `caller->children` and `rt->crashes` and reads
  `t->test`. They only read, and every change goes through `agc_task_cancel` and
  `agc_task_observe`. They move behind the port if a task group replaces them.
- **V7, V13, accepted:** `loop.c` (`agc_owned_of`) reads the `state` field of
  `agc_socket`, `agc_listener`, `agc_process` and `agc_http_server`, because
  ownership (§14.5) must find a value's resource and those values are declared
  in `value.h`. If more is wanted, the fix is a resource found through a field
  the service sets, not a tag list in the core.
- **V8, accepted:** the tag enum and the printed names of service values live in
  the core: one closed enum that the loader, `text.c` and `equal.c` need.
- **V9, V14, accepted:** service state in core structs (`agc_task`'s `test`,
  `note` and `test_run`, `agc_vm.process_guard`, the settings `deny_run`,
  `drop_uring_env` and `no_files`; `hidden` and `t->test` read by `quiet_slot`
  in `task.c`): opaque pointers and settings, no calls. The driver sets them.
- **V11, V12, accepted:** the driver (`agentica.c`, `launch.c`) calls service
  init and version functions; `http_body.c` calls `agc_size_mul` and
  `agc_out_of_memory` only, so out of memory keeps its exit code (§6.3).

Not violations: `loader.c` calls `agc_find_builtin` (core), and the core's other
cross-file calls stay inside the core.

### 15.7 New files

A PR that adds a `vm/*.c` file puts it in a layer list, and a reviewer checks a
new port function against §14 like any core change.
