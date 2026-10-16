## 15. VM layers

**Status:** planned by the owner on 2026-10-13, row 7.2.1b of the
[roadmap](../roadmap/README.md) (checklist in
[`07-vm.md`](../roadmap/07-vm.md#7l-vm-layers)). No behavior change: the goldens
do not move. Both PRs are done: the moves (§15.7 item 1) and the headers and the
check (item 2). It follows the architecture note [§16](16-architecture.md) (row
7.2.1c), which names the threads and queues behind the port.

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

This is the first part of 7l ([§21](../future/21-vm-layers.md#21-vm-layers)): it
replaces §21's first item (the `core`/`rt`/`lib` header split) with the split
below. Opcode helpers, builtin metadata flags and the callback-builtin protocol
stay in 7l at step 8.1. §14.6 asks of the layers: "Does each layer replace code,
or only add a boundary?" Answer: mostly a boundary, checked by CI. It adds no
runtime concept and replaces two pieces of code: `testing.c`'s hand-made wait
becomes the port's `agc_task_join` (V5), and `loop.c`'s process tag check
becomes a resource field that `process.c` sets (V3).

Line numbers in this section are from the tree after the moves of §15.7 item 1
(master at d99f273 plus PR 1), except what V1 to V5 of §15.6 say about the code
before it moved; the header split moved no line of a `.c` file except the
`#include` lines of `agentica.c`, `launch.c`, `builtin_tables.c`, `fuzz.c` and
`fuzz_main.c`.

### 15.1 Layers

| Layer | Files | May use |
|---|---|---|
| **Core** | `value.c`, `map.c`, `list.c`, `equal.c`, `text.c`, `unicode_data.c`, `json_value.c` (§15.6 V1), `interp.c`, `task.c`, `task_map.c`, `channel.c`, `loop.c`, `input.c`, `output.c`, `random.c`, `loader.c`, `builtins.c`, `diag.c`, `trace.c` | `value.h`, `port.h`, `core.h`, `trace.h`, Boehm GC, libuv |
| **Services** | `strings.c`, `numbers.c`, `json.c`, `json_typed.c`, `files.c`, `tree.c`, `stream.c`, `duplex.c`, `process.c`, `tcp.c`, `http_fields.c`, `http_client.c`, `http_server.c`, `logger.c`, `testing.c` | `value.h`, `port.h`, `services.h`, `net.h`, `trace.h`, adapter headers, libuv, yyjson (`json.c` only) |
| **Adapters** | `tls_openssl.c` (`tls.h`), `http_pico.c` and `http_body.c` (`http_parse.h`) | their own header, their library, and from `value.h` only the memory functions (`agc_alloc`, `agc_alloc_atomic`, `agc_size_add`, `agc_size_mul`, `agc_out_of_memory`) |
| **Driver** (not a layer: it wires them) | `agentica.c`, `launch.c`, `builtin_tables.c` (§15.6 V2), `fuzz.c`, `fuzz_main.c` | everything |

`vm/tests/*.c` may use everything. `trace.h` (tracing; `agc_trace_emit` is used
by `http_client.c`, `process.c` and `tcp.c`) is shared by every layer but the
adapters.

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
  parks its caller in a stepper on the scheduler's own timer job, so it can
  use only what the core offers (`agc_task_spawn_seeded`, `agc_task_cancel`,
  `agc_task_stepper`, the end hook of a task, `agc_count_step`). Its builtin
  table (`agc_task_map_builtins`) is declared in `core.h` and listed in
  `builtin_tables.c`.
- **`input.c`, `output.c` and `builtins.c` are core.** stdin's waiters and the
  waiters of stdout and stderr are lists the scheduler owns (§14.1), and
  `agc_task_cancel` takes a task out of them (`task.c:129`). `builtins.c` holds
  the `IO`, `System`, `List`, `Map`, `Set`, `Result` and `Range` builtins over
  core values, and `agc_find_builtin`, which the loader calls.
- **`stream.c` is a service.** It is the kit the stream services share
  (`agc_inbuf_*`, `agc_stream_lock`, `agc_stream_write`); only `duplex.c`,
  `process.c`, `tcp.c` and `http_client.c` use it.
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
  `http_body.c` uses `agc_size_mul` and `agc_out_of_memory`
  (`http_body.c:142-146`), so an out-of-memory body still ends with exit 70
  (§6.3).
- **yyjson has no adapter file.** `json.c`'s parser builds VM values straight
  from the yyjson tree (`convert`, `json.c:107`); a separate adapter would need
  an extra tree or VM values, so it would add code and replace none. Instead,
  the check (§15.5) keeps `yyjson.h` to `json.c`.
- **libuv is not wrapped.** The services own their own `uv_tcp_t`, `uv_pipe_t`
  and timers through `agc_io_uv`. A wrapper would be a second API over one
  library.
- **Services may call each other.** `http_client.c` and `http_server.c` use
  `tcp.c` through `net.h` (`http_server.c` calls `agc_conn_observe`,
  `agc_conn_unobserve`, `agc_conn_retain`, `agc_conn_release`, `agc_conn_read`,
  `agc_conn_pause`, `agc_conn_send`, `agc_conn_sent`, `agc_conn_write_status`,
  `agc_conn_half_close`, `agc_conn_shut`, `agc_conn_closed`, `agc_conn_failed`,
  `agc_conn_error`, `agc_conn_heard`, `agc_conn_input`, `agc_conn_accept`,
  `agc_conn_socket` and `agc_net_close`) and `http_fields.c`, `json_typed.c`
  uses `json.c`, `json.c` and `testing.c` use `strings.c` helpers. That is fine
  inside a layer.

### 15.2 The port

The port is what a service needs from the core to do I/O and to wait, as §14
allows it. It existed before PR 1, except `agc_task_join` (V5) and the resource
field of V3, which PR 1 added; it has its own header, `port.h`.

| Job | Functions |
|---|---|
| Park and wake a task | `agc_task_park` (`task.c:65`), `agc_task_enqueue` (`task.c:31`), `agc_task_wake` (`task.c:25`), `agc_task_wake_all` (`task.c:40`); `agc_task_stepper` (`task.c:70`) for a builtin that calls its block and also parks between the calls: it installs an `agc_stepper` on the task, and the interpreter then asks its `agc_step_fn` what to do next (call the block, park, or end), so no C code calls the interpreter (`docs/vm/03-ir-and-bytecode.md` §4.3, `File.each_line`) |
| Submit a job (loop or pool), with its timeout | `agc_io_start` with an `agc_io_kind` (`work`, `done`, `expired`, `drop`, `cancel`), `agc_io_ready`, `agc_io_detached` (its context is the handle a close job holds, or void), `agc_io_start_then` (a pool job's `more` step, which may keep it waiting on the loop), `agc_io_extend` (20c: restart the job's own timer, for `read_request`'s deadline from the first byte) |
| Resolve a path in pool work | `agc_real_path` (`loop.c`, the only file that includes `uv.h` for it): `uv_fs_realpath` called without a callback, so it runs on the calling pool thread and returns a `malloc`'d string, or NULL and the errno; `files.c` calls it from the `work` half of `Path.real` |
| Wait on a descriptor on the loop | `agc_poller_open`, `agc_poller_wait`, `agc_poller_pause`, `agc_poller_close` (a `uv_poll_t` that owns its descriptor; `files.c`, and `input.c` in the core) |
| Set a timer | no own function: a timer is the job's `timeout_ms` (§14.2); `Task.sleep` is a job with no work. The three other timers of §14.2 use libuv through `agc_io_uv` and stay exceptions |
| Register, own and close a handle | `agc_register`, `agc_own` with an `agc_close_fn` (it takes the task that ends, which only the file close uses) and `agc_disown` (a server takes its listener off its owner's list), `agc_unregister` (it also takes the handle off its owner's list), `agc_resource_id`; the handle's lock FIFO: `agc_handle_wait`; the resource's `goodbye` hook (a release-shaped function the exit path calls through `agc_io_goodbye`; `tcp.c` sets it for TLS `close_notify`); the V3 field `keep_detached` (`process.c` sets it on a process's resource, so `discard` in `loop.c` does not release the process when a detached job's result is dropped) |
| Reach the loop and signals | `agc_io_uv` (`loop.c:488`), `agc_io_block_stop` (around a fork or a thread start). The list of stop signals is static in `loop.c`: since the blocked-read fix no service reads it (`process.c` has no signal watchers) |
| Spawn, wait for, cancel and observe tasks (for `Test.run`) | `agc_task_spawn`, `agc_task_spawn_owning` (24b: spawn a task and give it a handle that the caller owns; `Task.spawn_owning` and `HttpWire.spawn` call it), `agc_task_spawn_seeded` (spawn under a parent with the caller's random seed; every builtin spawn uses it), `agc_task_owns` (whether the calling task owns a handle value), `agc_task_close_done` (a file close job of an ended task has finished), `agc_task_cancel`, `agc_task_observe`, `agc_report_unobserved`, `agc_task_join` (V5) |
| Task groups (20c, for `http_server.c`) | `agc_task_group` (a parent node that never runs), `agc_task_spawn_in` (spawn under a given parent), `agc_task_cancel` to drop a subtree (every cancelled task closes the handles it owns as it ends, so there is no separate drop), and three task fields the service sets on its own tasks: the `end` hook with `end_data` (`agc_end_fn`, called once when the task ends in any way) and `hidden` (no await can observe the task, so its unobserved crashes keep one entry per test, §10.2.1) |
| Charge, fail, write | `agc_charge`, `agc_charge_bytes` (`interp.c:80`, `86`), `agc_value_units`, `agc_fail`, `agc_fail_text`, `agc_exit`, `agc_write`, `agc_output_waiting`, `agc_drain`, `agc_flush` (`agc_write` takes the `agc_output` of stdout or stderr, the text and a flag for a trailing newline, and returns false when the task must park and retry; `agc_output_waiting` tells a builtin that its text already waits in the stream's FIFO, so it passes no text) |
| Program lookups | `agc_builtin_struct` (`builtins.c:438`) |

Behind the port sit the two queues of
[§16.4](16-architecture.md#164-two-directions): waking and enqueueing a task is
the push to the global run queue, and the requests to the I/O thread's inbox are
start, cancel, stop or extend its timer, release and the libuv steps of a job's
halves; which port function posts each is open
([§16.11](16-architecture.md#1611-open)). With N = 1, as built, they are direct
calls on one thread ([§16.9](16-architecture.md#169-as-built-n--1)). A service
reaches the queues only through the port. The libuv code of a service (§15.1,
"libuv is not wrapped") would run in the start step of the request, on the I/O
thread (§16.9).

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
  only sets `UV_USE_IO_URING=0` for itself (`loop.c:481-482`) and drops it from
  children's environment (`process.c:21`, `process.c:759`).
- **Platforms** are chosen at compile time with `#ifdef __linux__` stubs
  (`loop.c:757`, `files.c:1365`, `tcp.c:1270`, `process.c:926`,
  `http_client.c:845`, `http_server.c:707`, `input.c:237`). That stays.

The function pointers that exist are callbacks (job kinds, close and release
functions, builtins, `agc_conn_watch`), not tables of implementations, and they
stay.

### 15.4 Headers

`vm/agc.h` (717 lines) is split into four headers in one chain, and is gone: a
`.c` file includes the header of its layer, so nothing needs an umbrella.

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
what it uses (`json_test.c` and `string_test.c` both). What goes where, by name:

- **`value.h`** (includes `trace.h`): the limits; `agc_tag`; `agc_value` and the
  value structs (string, map, struct, enum, result, fn, range) and the opaque
  `agc_list` with its `agc_list_builder` and `agc_list_cursor` types (the layout
  is defined in the private `list_impl.h`); the Json value types
  (`agc_json_kind`, `agc_json_member`, `agc_json`, `agc_json_buffer`); opcodes,
  `agc_instr`, `agc_span`, `agc_source`; forward typedefs of `agc_vm`,
  `agc_task` and `agc_resource`; the handle value structs `agc_process`,
  `agc_socket`, `agc_listener`, `agc_http_client` and `agc_http_server`
  (anonymous typedefs, so they cannot be forward-declared; they hold
  `agc_resource *`, a port, a listener value and a task group pointer, and live
  here next to their constructors); `agc_test_case`; `agc_builtin_fn`,
  `agc_native_kind`, `agc_cost_rule` and `agc_builtin` (`agc_program` names
  `agc_builtin`); the program tables (`agc_function`, `agc_type`, the struct,
  enum and variant defs, `agc_program`); `agc_random` and its functions;
  `agc_gc_info`; memory (`agc_init` to `agc_gc_stats`); value constructors and
  `agc_as_*`; the UTF-8, string, map, list (`agc_list_len` to `agc_list_concat`,
  defined in `list.c`), text and equality functions; `agc_sort_by_keys`; every
  Unicode table; the Json value API (`agc_json_ascii`, `agc_json_grow`,
  `agc_json_put`, `agc_json_leaf`, `agc_json_number`, `agc_json_pair`,
  `agc_json_object`, `agc_json_array`, `agc_json_find`, `agc_json_encode`,
  `agc_json_from`, and the node helpers
  `agc_json_container`, `agc_json_store` and `agc_json_finish`, which
  `json_value.c` defines); `agc_error_value` and `agc_utf8_count` (V4, V15).
- **`port.h`**: `agc_release_fn`, `agc_close_fn`, `agc_end_fn`,
  `agc_resource_kind` and the body of `struct agc_resource`; forward typedefs of
  `agc_test_note` (the struct gets a tag, `struct agc_test_note`, so the forward
  typedef matches), `agc_test_run`, `agc_registry`, `agc_loop`, `agc_io_job`,
  `agc_more_fn`, `agc_poller` and `agc_native`; `agc_frame`; `agc_step_kind`,
  `agc_step`, `agc_stepper` (one member, its `agc_step_fn`, which a service's
  state struct starts with) and `agc_step_fn`; `agc_io_kind`;
  `agc_outcome_kind`, `agc_style`, `agc_stack_line`, `agc_stack` with
  `AGC_STACK_HEAD` and `AGC_STACK_TAIL`, `agc_outcome`; `agc_input_status` and
  `agc_input`; `agc_runtime`, `agc_task_state`, `agc_turn_result`,
  `agc_lock_status`, `struct agc_task`, `struct agc_vm`; `agc_file_id` and
  `agc_file_ids` (`rt->inherited`); and the port functions of §15.2 (among them
  `agc_stack_members`, which builds the stack members of a Json failure record
  for `testing.c`), with `agc_io_block_stop`, `agc_io_start_then` and the poller
  functions under `__linux__` (so `port.h` includes `<signal.h>` and
  `<locale.h>` there).
- **`core.h`**: what only the core and the driver call: `agc_builtin_table`;
  `agc_vm_init`; tasks and turns (`agc_new_task`, `agc_task_call`,
  `agc_task_enter`, `agc_task_remove`, `agc_turn_begin`, `agc_turn_charge`,
  `agc_turn_finish`, `agc_run_turn`, `agc_vm_run`); the loop's own life
  (`agc_uv_version`, `agc_io_init`, `agc_io_poll`, `agc_io_finish`,
  `agc_io_detach`, `agc_io_close`); the exit path and stop signals
  (`agc_io_watch_stop`, `agc_io_stop_signal`, `agc_io_children_stopped`,
  `agc_io_goodbye`, `agc_io_flush_files`, `agc_stop`); ownership internals
  (`agc_owned_of`, `agc_hand_over`, `agc_close_owned`, `agc_handle_leave`); the
  loader (`agc_load`, `agc_load_traced`); `agc_find_builtin`, the builtin table
  list (`agc_builtin_tables` with `agc_builtin_table_count`, defined in
  `builtin_tables.c`), `agc_core_builtins` with its count (defined in
  `builtins.c`), `agc_task_builtins` with its count (defined in `task.c`) and
  `agc_task_map_builtins` with its count (defined in `task_map.c`);
  stdin (`agc_input_open`, `agc_input_close`, `agc_input_peek`,
  `agc_input_line`, `agc_input_all`, `agc_input_bytes`); stdout and stderr
  (`agc_output_open`, `agc_output_close`, `agc_output_leave`, `agc_output_busy`,
  `agc_notice_begin`, `agc_notice_end`); diagnostics (`agc_print_diagnostic`,
  `agc_crash_text`, `agc_print_unobserved`, `agc_print_flush_timeout`,
  `agc_print_flush_failed`); `agc_fuzz_one`.
- **`services.h`**: the body of `struct agc_test_note`; `agc_inbuf`; the
  `strings.c` helpers others use (`agc_utf8_encode`, `agc_utf8_offset`,
  `agc_text_find`, `agc_change_case`, `agc_parse_int`, `agc_parse_float`,
  `agc_around`) with `agc_number_status` and `AGC_NOT_FOUND`; the JSON parser
  and typed JSON (`agc_json_status`, `agc_json_version`, `agc_json_parse`,
  `agc_json_status_message`, `agc_json_to_float`, `agc_json_decode`,
  `agc_json_schema`); `files.c`'s exports (`agc_files_init`,
  `agc_files_close`, `agc_host_path`, `agc_utf8_error`, `agc_system_error`,
  `agc_each_fd`, `agc_files_inherited`, `agc_files_forget`);
  `agc_tree_refused` and `agc_remove_tree` (`tree.c`, the refusal test and the
  tree walk of `Path.remove`, with `AGC_TREE_TOO_DEEP`, `AGC_TREE_REFUSED` and
  `AGC_TREE_MAX_DEPTH`; no VM state); `agc_processes_stop` (`process.c`,
  called by the driver's exit path); the stream kit (`agc_new_lock`,
  `agc_stream_lock`, `agc_stream_bad_timeout`, `agc_stream_timed_out`,
  `agc_inbuf_*`, `agc_stream_write`, with forward `struct uv_stream_s` and
  `struct uv_write_s`); `agc_duplex_*` and `agc_parent_*` (the child channel,
  `duplex.c`, used by `process.c`, `testing.c` and the driver); the builtin
  tables of the services (strings, numbers, json, files, duplex, process, tcp,
  http, test) and their counts.

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

`net.h` (the `agc_conn` API of `tcp.c`, used by `http_client.c`) and
`http_fields.h` include `services.h`; `net.h` also includes `tls.h`. `tls.h`,
`http_parse.h` and `trace.h` keep their content. What named `vm/agc.h` now names
the header that holds the item: `tests/test_frontend_bytecode.py` reads
`agc_opcode` from `value.h`, `unicode_data.c` includes `core.h`, and the development skill lists the
layers.

### 15.5 The layer check

`make vm-layers` (a target in `.PHONY` and in the list at the top of the
`Makefile`; it depends on `vm`) does three things: it compiles each header on
its own (§15.4), runs `vm/tools/check-layers.sh <object dir>`, and runs the
negative self-test, `vm/tools/check-layers-test.sh`. CI runs it in the
`vm-sanitizers` job of `ci.yml` after `make -j vm vm-test vm-fuzz`, on the
objects of the sanitizer build (the job runs when a pull request touches `vm/`
or the `Makefile`); that job checks that `rg` is installed and installs ripgrep
if not. The script fails when:

1. a `vm/*.c` or `vm/*.h` file is in no list, or a listed file does not exist;
2. a core file includes `services.h`, `net.h`, `tls.h`, `http_parse.h` or
   `http_fields.h`;
3. a service or adapter file includes `core.h`;
4. an adapter file includes `port.h`, `services.h`, `net.h` or `http_fields.h`
   (it may include `value.h`; rule 8 keeps it to the memory functions);
5. a third-party header is included outside its place: `<gc.h>` only in
   `value.c`; `<openssl/...>` only in `tls_openssl.c`; `<picohttpparser.h>` only
   in `http_pico.c`; `"yyjson.h"` only in `json.c`; `<uv.h>` only in `loop.c`
   and the stream services (`stream.c`, `duplex.c`, `process.c`, `tcp.c`,
   `http_client.c`). `input.c` and `files.c` put stdin, FIFOs and character
   devices on loop handles through `agc_poller_*` (§15.2) and include no libuv
   header;
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
9. the header chain: `value.h` includes only `trace.h` of ours, `port.h` only
   `value.h`, `core.h` and `services.h` only `port.h`, `net.h` only `services.h`
   and `tls.h`, `http_fields.h` only `services.h` and `http_parse.h`,
   `list_impl.h` only `value.h`, and `tls.h`, `http_parse.h` and `trace.h` none;
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
must fail with its own message: a text one for rules 1, 2, 3, 4, 5, 6, 9
(including `core.h` in `net.h`) and 10 (`list_impl.h` in `text.c`), and two link
ones. The link ones are a core file that calls `agc_utf8_encode` through a
typedef'd declaration (`plant_fn agc_utf8_encode;`), which rule 6 misses, so
only rule 7 sees it, and an adapter that calls `agc_error_value` (rule 8). They
rebuild the planted object with the VM's compiler flags before the script runs,
so the script never reads a stale object. CI checks the sanitizer objects; run
`make vm-layers` on the release objects locally too, to cover code that a
configuration turns off. The patterns of rule 6 match nothing in `vm/*.c`.

### 15.6 Violations found

Mapped at 7a40b78 by listing, for each `vm/*.c` file, the `agc_` functions it
calls that another file defines; a review build checked the list against `nm`
and found no other core-to-service call. PR 1 mapped them again at d99f273 and
checked the objects after the moves with `nm` (the link rule of §15.5): the only
core-to-service call left was the one V1's move brought in, V15. V1 to V5 are
done; their lines cite where the code was before it moved. Each row is a place
where the core names a service or service data, or a layer reaches past the
port.

| # | Where | What | Fix |
|---|---|---|---|
| V1 | `text.c:149`, `281`, `286`; `equal.c:66` | `to_s`, `inspect` and `==` of a `Json` value call `agc_json_encode` in `json.c` (a service) | **Move (done).** The Json value is a core type (`AGC_T_JSON`), so its code is in a new core file, `json_value.c`: the writer (`agc_json_put`, the string and scalar writers, `agc_json_encode`), `agc_json_from` and its frame walker, `agc_json_leaf`, `agc_json_number`, `agc_json_pair`, `agc_json_object`, `agc_json_array`, `agc_json_find`, `agc_json_ascii`, `agc_json_grow`, and the node code shared with the parser: `agc_json_container`, `agc_json_store` and `agc_json_finish` (which sorts the members by key bytes and drops repeated keys), the former statics `container`, `store` and `finish`. The parser's `leaf` is `agc_json_leaf`. `json.c` keeps the yyjson parser (`convert`, `agc_json_parse`), `agc_json_status_message`, `agc_json_to_float` and the `JSON.*` builtins; `agc_json_decode` and `agc_json_schema` stay in `json_typed.c` |
| V2 | `builtins.c:433-444` | the builtin table list names every service's table (`agc_file_builtins`, `agc_tcp_builtins`, `agc_test_builtins`, ...) | **Move (done)** of the list, in the same order (`agc_find_builtin` returns the first match), to a new driver file, `builtin_tables.c`: `agc_builtin_tables` and `agc_builtin_table_count`. `agc_find_builtin` stays in `builtins.c` (`builtins.c:428`) and reads the list through `core.h`. `builtins.c` exports its own table as `agc_core_builtins` with `agc_core_builtin_count`, like the other libraries. The list is the one place that wires the services in, like `main.c` |
| V3 | `loop.c:284-290` | `discard` (a detached job's result) skipped `AGC_T_PROCESS` by name: a process rule in the loop | **Port data (done).** The tag check became a new `agc_resource` field, `keep_detached`, that `process.c` sets when it registers the process (`process.c:781`); `discard` reads the field, not the tag (`loop.c:287`) |
| V4 | `task.c:461`, `505` | `await_task` and `builtin_unobserved_crash` build their error with `agc_error_value`, which was defined in `stream.c` (a service) | **Move (done)** of `agc_error_value` (four lines) to `value.c`, next to `agc_make_string` |
| V5 | `testing.c:276` | `Test.run` had a `wait_for` that set `vm->task->awaiting`, put the task on `target->waiters` and parked: the waiting half of `await_task`, without its crashed and cancelled branches | **Port function (done)** `bool agc_task_join(agc_vm *vm, agc_task *target)` in `task.c:443`: if the target is done, clear `awaiting` and return false; else set `awaiting`, enqueue the task on the target's waiters, park (with retry) and return true. `wait_for` is gone: `Test.run` calls `agc_task_join`, and `await_task` (`task.c:452`) calls it and, after false, handles the result (crashed, cancelled, value) as before |
| V6 | `testing.c:186-206` | `cancel_leftovers`, `unobserved_of` and `observe_test` walk `caller->children` and `vm->crashes` and read `t->test` | **Accepted for now.** Reads only, and every change goes through `agc_task_cancel` and `agc_task_observe`. 24b's one hand-off form may give a task group to replace them; if it does, they move behind the port then |
| V7 | `loop.c` (`agc_owned_of`) | the core reads the `state` field of `agc_socket`, `agc_listener` and `agc_process` | **Accepted**: those handle values are declared in `value.h`, since ownership (§14.5) must find a value's resource. As built in 24b, its callers are `agc_task_spawn_owning` in `task.c` and `discard` in `loop.c` |
| V8 | `value.h` (`agc_tag` and the inline constructors and `agc_as_*`), `value.c` (the service resources'); `text.c:105-112` | the tag enum, constructors, `agc_as_*` and the printed names (`<Socket>`, `<Process>`, ...) of service values live in the core | **Accepted**: the tag set is one closed enum that the loader, `text.c` and `equal.c` need; no service code is called |
| V9 | `port.h` (`struct agc_task`, `struct agc_vm`, `agc_runtime`), `task.c:409` | service state in core structs: `agc_task`'s `test`, `note` and `test_run` (a spawned task inherits `test`), `agc_vm.process_guard`, and the `allow_run`, `drop_uring_env` and `no_files` settings | **Accepted**: opaque pointers and settings, no calls. The driver sets the settings |
| V10 | `output.c:78`, `output.c:528`, `input.c:268`, `input.c:375` | 25b's `mid_line` and `agc_write_record`, the reserved stdin and `agc_protocol_line` (core code that exists for `testing.c`) | **Removed (done, 25c, row 7.2.1a):** the child protocol moved to fd 3 (`vm/duplex.c`); `mid_line`, `agc_write_record`, the reserved stdin and `agc_protocol_line` are gone |
| V11 | `main.c:189`, `385-392`, `482`, `488` (now `agentica.c` and `launch.c`) | the driver calls `agc_files_init`, `agc_files_close`, `agc_parent_take`, `agc_tls_version` and `agc_json_version` | **Accepted**: `agentica.c` is the driver |
| V12 | `http_body.c:142-146` | an adapter calls `agc_size_mul` and `agc_out_of_memory` | **Accepted**: memory only, so out of memory keeps its exit code (§6.3); rule 8 of §15.5 keeps it to memory |
| V13 | `loop.c` (`agc_owned_of`), 20c | the core reads the `state` field of `agc_http_server` too, so a server passed to `Task.spawn_owning` can be handed over | **Accepted with V7**, for the same reason. 24b kept the lookup in `agc_task_spawn_owning`; the fix, if it is ever wanted, is a resource found through a field the service sets at `agc_register`, not a tag list in the core |
| V14 | `task.c:264` (`quiet_slot`), 20c | the crash list reads `hidden` and `t->test` to keep one entry per test for HTTP connection tasks | **Accepted with V6**: a flag the service sets, read by the core; no service call |
| V15 | `json_value.c` (`agc_json_encode`) | found by PR 1: once V1 moved the Json writer into the core, it counted the characters of its output with `agc_utf8_count`, which `strings.c` (a service) defined | **Move (done)** of `agc_utf8_count` (four lines) to `value.c`, with the other UTF-8 functions; `strings.c`, `json.c` and `json_typed.c` call it from there. It is in `value.h`, not `services.h` (§15.4) |

Not violations: `loader.c:460` calls `agc_find_builtin` (core); the core's other
cross-file calls stay inside the core; the services call the core only through
the functions of §15.2 and the value API.

### 15.7 Implementation PRs

Two PRs, both VM-only and mechanical, both with no change to the goldens. HTTP
20c and the blocked-read fix, which changed `input.c`, `files.c` and the HTTP
services, are done, so the moves no longer conflict with them. The PRs come
before 25c and 24b, so that 25c's new `Process` builtins and 24b's ownership
change are written on the port. Each PR first maps the calls again on the tree
it starts from (as in §15.6) and updates §15 where the tree has moved.

1. **Moves (done).** V1 (`json_value.c`), V2 (`builtin_tables.c`), V3 (the
   resource field), V4 (`agc_error_value`), V5 (`agc_task_join`) and V15
   (`agc_utf8_count`, found by the `nm` check of this PR). Both new files join
   `VM_SRC` in the `Makefile`. `agc.h` stays one header in this PR. It runs
   `make dup-check`: the jscpd baseline (`.jscpd-baseline.json`) holds
   fingerprints, so a moved clone can show up as new; remove the copy rather
   than grow the baseline.
2. **Headers and the check (done).** Split `agc.h` into `value.h`, `port.h`,
   `core.h` and `services.h` (§15.4), with each `.c` file including its layer's
   header and each header compiled on its own; update the places that name
   `agc.h` (§15.4); add `vm/tools/check-layers.sh`, `make vm-layers`, its
   negative self-test and the CI step (§15.5); tick row 7.2.1b and add the
   layers to the development skill (`references/vm.md`: the "which layer" note;
   the file tables of `references/vm-core.md`, `vm-io.md`, `vm-net.md` and
   `vm-tasks.md`; `references/ci.md`: the new check).

Order (the owner, 2026-10-13): after the architecture note (§16, row 7.2.1c),
and before the asynchronous process close and the flush limit (row 7.2.1d),
channels (17b, row 7.2.1e), stdout and stderr on the loop (row 7.2.1f), and 25c
and 24b (row 7.2.1a).

After that, a PR that adds a `vm/*.c` file puts it in a layer list, and a
reviewer checks a new port function against §14 like any core change.
