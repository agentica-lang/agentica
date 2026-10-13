## 15. VM layers

**Status:** planned by the owner on 2026-10-13, row 7.2.1b of the [roadmap](../roadmap/README.md) (checklist in [`07-vm.md`](../roadmap/07-vm.md#7l-vm-layers)). No behavior change: the goldens do not move.

The C VM gets a light layering: three layers with one-way dependencies, one small port between the services and the core, and one header per layer, with a CI check that keeps the direction. It is not DDD and not a plugin system: calls stay direct, and function pointers stay where they already are (callbacks), not as tables around every module.

Words. §14 calls everything under the scheduler "the VM core" (`task.c`, `loop.c`, `input.c`, `files.c`, `process.c`, `tcp.c`, HTTP and TLS). Here **core** is narrower: the scheduler, the loop, the values and what they need. §14's five rules hold for the core and the services alike.

This is the first part of 7l ([§21](../future/21-vm-layers.md#21-vm-layers)): it replaces §21's first item (the `core`/`rt`/`lib` header split) with the split below. Opcode helpers, builtin metadata flags and the callback-builtin protocol stay in 7l at step 8.1. §14.6 asks of the layers: "Does each layer replace code, or only add a boundary?" Answer: mostly a boundary, checked by CI. It adds no runtime concept, and it removes two pieces of code: the hand-made await in `testing.c` and the process check in `loop.c` (§15.6, V5 and V3).

### 15.1 Layers

| Layer | Files | May use |
|---|---|---|
| **Core** | `value.c`, `map.c`, `equal.c`, `text.c`, `unicode_data.c`, `json_value.c` (new, §15.6 V1), `interp.c`, `task.c`, `loop.c`, `input.c`, `random.c`, `loader.c`, `builtins.c`, `diag.c`, `trace.c` | the core, Boehm GC, libuv |
| **Services** | `strings.c`, `numbers.c`, `json.c`, `json_typed.c`, `files.c`, `stream.c`, `process.c`, `tcp.c`, `http_client.c`, `testing.c` | the port, other services, adapters, libuv, yyjson (`json.c` only) |
| **Adapters** | `tls_openssl.c` (`tls.h`), `http_pico.c` and `http_body.c` (`http_parse.h`) | their own header, their library, the core's memory functions |
| **Driver** | `main.c`, `builtin_tables.c` (new, §15.6 V2), `fuzz.c`, `fuzz_main.c` | everything |

`vm/tests/*.c` may use everything.

Notes on the choices, where they differ from the first proposal:

- **`unicode_data.c` is core, not an adapter.** It is generated data, not a wrapper of a library, and `text.c` (core) prints strings with its `agc_write_*` ranges. Its case tables (used by `strings.c`) are data too; all its tables are declared in the core header.
- **`input.c` and `builtins.c` are core.** stdin's waiters are a list the scheduler owns (§14.1), and `agc_task_cancel` takes a task out of it (`task.c:126`). `builtins.c` holds the `IO`, `System`, `List`, `Map`, `Result` and `Range` builtins over core values, and `agc_find_builtin`, which the loader calls.
- **`stream.c` is a service.** It is the kit the stream services share (`agc_inbuf_*`, `agc_stream_lock`, `agc_stream_write`); only `process.c`, `tcp.c` and `http_client.c` use it.
- **`http_body.c` is an adapter, with `http_pico.c`.** `http_parse.h` is a plain protocol header with no VM values; `http_pico.c` calls `http_body.c`'s syntax helpers (`agc_http_token`, `agc_http_framing`, ...), so the two are one unit. `http_body.c` uses the core's `agc_size_mul` and `agc_out_of_memory` (`http_body.c:142-146`), so an out-of-memory body still ends with exit 70 (§6.3); adapters may use the core's memory functions and nothing else of it.
- **yyjson has no adapter file.** `json.c`'s parser builds VM values straight from the yyjson tree (`convert`, `json.c:189`); a separate adapter would need an extra tree or VM values, so it would add code and replace none. Instead, the check (§15.5) keeps `yyjson.h` to `json.c`.
- **libuv is not wrapped.** The services own their own `uv_tcp_t`, `uv_pipe_t` and timers through `agc_io_uv`. A wrapper would be a second API over one library.
- **Services may call each other.** `http_client.c` uses `tcp.c` (`net.h`), `json_typed.c` uses `json.c`, `json.c` and `testing.c` use `strings.c` helpers. That is fine inside a layer.

### 15.2 The port

The port is what a service needs from the core to do I/O and to wait, as §14 allows it. It exists today; this plan only names it and puts it in its own header (`port.h`).

| Job | Functions (today) |
|---|---|
| Park and wake a task | `agc_task_park` (`task.c:65`), `agc_task_enqueue` (`task.c:31`), `agc_task_wake` (`task.c:25`), `agc_task_wake_all` (`task.c:40`) |
| Submit a job (loop or pool), with its timeout | `agc_io_start` (`loop.c:377`) with an `agc_io_kind` (`work`, `done`, `expired`, `drop`, `cancel`), `agc_io_ready` (`loop.c:391`), `agc_io_detached` (`loop.c:385`) |
| Set a timer | no own function: a timer is the job's `timeout_ms` (§14.2); `Task.sleep` is a job with no work. The three other timers of §14.2 use libuv through `agc_io_uv` and stay exceptions |
| Register, own and close a handle | `agc_register` (`loop.c:49`), `agc_own` (`loop.c:73`) with an `agc_close_fn`, `agc_unregister` (`loop.c:120`), `agc_resource_id` (`loop.c:47`); the handle's lock FIFO: `agc_handle_wait` (`loop.c:420`) |
| Reach the loop | `agc_io_uv` (`loop.c:337`), `agc_io_block_stop` (`loop.c:314`, around a fork or a thread start) |
| Spawn, wait for, cancel and observe tasks (for `Test.run`) | `agc_task_spawn` (`task.c:347`), `agc_task_cancel` (`task.c:146`), `agc_task_observe` (`task.c:292`), `agc_report_unobserved` (`task.c:285`), and `agc_task_join` (new, §15.6 V5) |
| Charge, fail, write | `agc_charge`, `agc_charge_bytes` (`interp.c:84`, `90`), `agc_value_units`, `agc_fail`, `agc_fail_text`, `agc_exit`, `agc_write`, `agc_flush` |
| Program lookups | `agc_builtin_struct` (`builtins.c:456`) |

The core calls services back only through function pointers that a service handed over: the job kind (`agc_io_kind`), `agc_close_fn` and `agc_release_fn` of a resource, and `agc_builtin_fn` of a builtin. It never calls a service by name.

Services still read fields of the runtime structs (`agc_vm`, `agc_task`, `agc_runtime`, `agc_resource`); making them opaque would not be a mechanical change. The rule: a service may read the run's settings in `vm->rt` (`trace`, `cwd`, `no_files`, `allow_run`, `program`, ...), the fields of a resource it registered, and the per-task fields that exist for it (`cursor` for `strings.c`, `random` for `numbers.c`, `test` and `test_run` for `testing.c`). It does not walk or change the scheduler's lists; V6 is the one exception left.

### 15.3 Function-pointer tables

Allowed only where two real implementations are chosen at run time. Today there is no such place, so the plan adds none:

- **TLS** has one implementation, `tls_openssl.c`, behind `tls.h`, chosen at link time. A second backend would be a second `.c` file behind the same header, still chosen by the Makefile; a table only if one binary needs both.
- **The loop backend** is not ours: libuv picks io_uring or epoll inside. The VM only sets `UV_USE_IO_URING=0` for itself (`loop.c:330`) and drops it from children's environment (`process.c:22`, `process.c:815`).
- **Platforms** are chosen at compile time with `#ifdef __linux__` stubs (`loop.c:583-631`, `files.c:1076`, `tcp.c:1181`, `process.c:981`, `http_client.c:956`, `input.c:152`). That stays.

The function pointers that exist are callbacks (job kinds, close and release functions, builtins, `agc_conn_watch`), not tables of implementations, and they stay.

### 15.4 Headers

`vm/agc.h` (655 lines, included by every `.c` file) is split into four headers. Each header includes the one below it.

| Header | Holds | From `agc.h` | Included by |
|---|---|---|---|
| `value.h` | limits, tags, value structs, Json value, opcodes, spans, sources, program tables, memory, value constructors and `agc_as_*`, UTF-8, strings, maps, text, equality, Unicode tables, Json value API (`agc_json_encode`, `agc_json_from`, `agc_json_put`, `agc_json_leaf`, ...), `agc_error_value`, random | 1-142, 240-286, 295-311, 399-505, the Json value part of 524-538, 635-638 | everything, adapters only for memory |
| `port.h` | the runtime structs (`agc_resource`, `agc_runtime`, `agc_task`, `agc_vm`), handle values (`agc_process`, `agc_socket`, `agc_listener`, `agc_http_client`), `agc_io_kind`, `agc_builtin`, and the port functions of §15.2 | 144-238, 313-397, 554, the port part of 557-579 and 608-633 | core, services |
| `core.h` | what only the core and the driver call: `agc_vm_init`, tasks and turns (`agc_new_task`, `agc_task_call`, `agc_task_enter`, `agc_turn_*`, `agc_run_turn`, `agc_vm_run`), the loop's own end (`agc_io_init`, `agc_io_poll`, `agc_io_finish`, `agc_io_detach`, `agc_io_close`, `agc_uv_version`), ownership internals (`agc_owned_of`, `agc_give_owned`, `agc_close_owned`, `agc_handle_leave`), frames, the loader, `agc_find_builtin` and the table list, stdin, diagnostics, `agc_fuzz_one` | 288-293, 555, the rest of 557-579 and 608-633, 604-606, 640-653 | core, driver |
| `services.h` | the builtin tables of each service, the `strings.c` helpers others use (`agc_around`, `agc_parse_int`, `agc_utf8_count`, ...), `agc_json_parse` and the typed JSON entry points, `files.c`'s exports (`agc_files_init`, `agc_files_close`, `agc_host_path`, `agc_system_error`, `agc_utf8_error`), the stream kit (`agc_inbuf`, `agc_inbuf_*`, `agc_new_lock`, `agc_stream_*`), the test types and `agc_test_protocol` | 188-206, 507-553 without the Json value part, 580-602 | services, driver |

`net.h` (the `agc_conn` API of `tcp.c`, used by `http_client.c`) includes `services.h` and `tls.h`. `tls.h`, `http_parse.h` and `trace.h` stay as they are. `agc_protocol_line` and the stdin `reserved` flag sit in `port.h` and `core.h` until 25c removes them.

Places that name `vm/agc.h` and move with the split: `tests/bytecode-test.rkt:15` (reads `agc_opcode`, now in `value.h`), `vm/tools/gen-unicode.rkt:186` (the include line of `unicode_data.c`), `vm/net.h:4`, every `vm/tests/*.c`, the development skill (`SKILL.md`, `references/vm.md`, `references/ci.md`) and the `docs/vm/` files that cite it.

### 15.5 The layer check

`vm/tools/check-layers.sh`, run by `make vm-layers` and by a step in the `dup-check` job of `ci.yml` (it needs no build, so it runs on push too). It uses `rg`. It fails when:

1. a `vm/*.c` file is in no layer list (a new file must pick one);
2. a core file includes `services.h`, `net.h`, `tls.h` or `http_parse.h`;
3. a service or adapter file includes `core.h`;
4. an adapter file includes `port.h`, `services.h` or `net.h`;
5. a third-party header is included outside its place: `<gc.h>` only in `value.c`; `<openssl/...>` only in `tls_openssl.c`; `<picohttpparser.h>` only in `http_pico.c`; `"yyjson.h"` only in `json.c`; `<uv.h>` only in `loop.c` and the stream services (`stream.c`, `process.c`, `tcp.c`, `http_client.c`);
6. a `.c` file declares an `agc_` function or variable with `extern` (it would go around the headers; `extern char **environ` in `process.c` is not an `agc_` name).

Rules 2 and 6 with `-Werror` (`Makefile:125`) are what make "the core never calls a service by name" hold: a core file has no declaration to call.

```sh
#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
core="value.c map.c equal.c text.c unicode_data.c json_value.c interp.c task.c loop.c input.c random.c loader.c builtins.c diag.c trace.c"
services="strings.c numbers.c json.c json_typed.c files.c stream.c process.c tcp.c http_client.c testing.c"
adapters="tls_openssl.c http_pico.c http_body.c"
driver="main.c builtin_tables.c fuzz.c fuzz_main.c"
fail=0
bad() { echo "vm layers: $*" >&2; fail=1; }
for f in *.c; do
  case " $core $services $adapters $driver " in *" $f "*) ;; *) bad "$f is in no layer" ;; esac
done
if rg -n '#include "(services|net|tls|http_parse)\.h"' $core; then bad "a core file includes a service or adapter header"; fi
if rg -n '#include "core\.h"' $services $adapters; then bad "a service or adapter includes core.h"; fi
if rg -n '#include "(port|services|net)\.h"' $adapters; then bad "an adapter includes the port or a service header"; fi
only() { if rg -n --max-depth 1 "$1" --glob '*.c' --glob '*.h' $(for f in $2; do printf -- "--glob !%s " "$f"; done) .; then bad "$1 outside $2"; fi; }
only '#include <gc\.h>' "value.c"
only '#include <openssl/' "tls_openssl.c"
only '#include <picohttpparser\.h>' "http_pico.c"
only '#include "yyjson\.h"' "json.c"
only '#include <uv\.h>' "loop.c stream.c process.c tcp.c http_client.c"
if rg -n --max-depth 1 '^\s*extern\b.*\bagc_' --glob '*.c' .; then bad "an extern agc_ declaration in a .c file"; fi
exit "$fail"
```

This is a sketch; its PR runs it. Rules 5 and 6 already pass on today's tree.

### 15.6 Violations found

Mapped on master at 7a40b78 by listing, for each `vm/*.c` file, the `agc_` functions it calls that another file defines. Each row is a place where the core names a service or service data, or a layer reaches past the port.

| # | Where | What | Fix |
|---|---|---|---|
| V1 | `text.c:148`, `280`, `285`; `equal.c:66` | `to_s`, `inspect` and `==` of a `Json` value call `agc_json_encode` in `json.c` (a service) | **Move.** The Json value is a core type (`AGC_T_JSON`), so its code goes to a new core file `json_value.c`: the writer, `agc_json_from` and their walker (`walk_frame`, `json.c:20-26`; `json.c:317-538`), the constructors and `agc_json_find` (`json.c:556-578`), and the node helpers that the parser shares with `agc_json_from` (`json.c:49-60`, `105-163`: `new_node`, `leaf`, `container`, `store`, `finish`, `agc_json_grow`), which `value.h` then declares. `json.c` keeps the yyjson parser, `agc_json_status_message` and the `JSON.*` builtins |
| V2 | `builtins.c:433-444` | the builtin table list names every service's table (`agc_file_builtins`, `agc_tcp_builtins`, `agc_test_builtins`, ...) | **Move** the list to a new driver file `builtin_tables.c`; `agc_find_builtin` stays in `builtins.c` and reads the list through `core.h`. The list is the one place that wires the services in, like `main.c` |
| V3 | `loop.c:253` | `discard` (a detached job's result) skips `AGC_T_PROCESS` by name: a process rule in the loop | **Callback through the port**, as data: a resource flag that `process.c` sets when it registers the process (`agc_resource.keep_detached`, say); `discard` reads the flag, not the tag |
| V4 | `task.c:377` | `await_task` builds its error with `agc_error_value`, defined in `stream.c` (a service) | **Move** `agc_error_value` (one line) to `value.c` |
| V5 | `testing.c:224-231` | `wait_for` sets `vm->task->awaiting`, puts the task on `target->waiters` and parks: a copy of `await_task` (`task.c:367`) | **Port function.** `agc_task_join(vm, target)` in `task.c`, used by `await_task` and by `Test.run`; the copy goes |
| V6 | `testing.c:186-205` | `cancel_leftovers`, `unobserved_of` and `observe_test` walk `caller->children` and `vm->crashes` and read `t->test` | **Accepted for now.** Reads only, and every change goes through `agc_task_cancel` and `agc_task_observe`. 24b's one hand-off form may give a task group to replace them; if it does, they move behind the port then |
| V7 | `loop.c:79-82` (`agc_owned_of`) | the core reads the `state` field of `agc_socket`, `agc_listener` and `agc_process` | **Accepted**: those handle values are declared in `port.h`, since ownership (§14.5) must find a value's resource. 24b replaces its caller in `builtin_spawn` (`task.c:362`) |
| V8 | `value.c:268-313`, `445-478`; `text.c:105-111`; `agc.h:33` | the tag enum, constructors, `agc_as_*` and the printed names (`<Socket>`, `<Process>`, ...) of service values live in the core | **Accepted**: the tag set is one closed enum that the loader, `text.c` and `equal.c` need; no service code is called |
| V9 | `agc.h:375-377`, `task.c:350`; `agc.h:391`; `agc.h:334` | service state in core structs: `agc_task`'s `test`, `note` and `test_run` (a spawned task inherits `test`), `agc_vm.process_guard`, and the `allow_run`, `drop_uring_env` and `no_files` settings | **Accepted**: opaque pointers and settings, no calls. The driver sets the settings |
| V10 | `interp.c:54`, `input.c:183`, `input.c:290` | 25b's `out_mid_line`, the reserved stdin and `agc_protocol_line` (core code that exists for `testing.c`) | **Removed by 25c** (row 7.2.1a), which comes after this row and moves the child protocol to fd 3 |
| V11 | `main.c:409-430` | the driver calls `agc_files_init`, `agc_files_close`, `agc_test_protocol`, `agc_tls_version` and `agc_json_version` | **Accepted**: `main.c` is the driver |
| V12 | `http_body.c:142-146` | an adapter calls the core's `agc_size_mul` and `agc_out_of_memory` | **Accepted**: memory only, so out of memory keeps its exit code (§6.3) |

Not violations: `loader.c:460` calls `agc_find_builtin` (core); the core's other cross-file calls stay inside the core; the services call the core only through the functions of §15.2 and the value API.

### 15.7 Implementation PRs

Two PRs, both VM-only and mechanical, both with no change to the goldens. They come after HTTP 20c and the blocked-read fix (both change `input.c`, `files.c` and the HTTP services, so the moves would conflict), and before 25c and 24b, so that 25c's new `Process` builtins and 24b's ownership change are written on the port.

1. **Moves.** V1 (`json_value.c`), V2 (`builtin_tables.c`), V3 (the resource flag), V4 (`agc_error_value`) and V5 (`agc_task_join`). Both new files join `VM_SRC` in the `Makefile`. `agc.h` stays one header in this PR.
2. **Headers and the check.** Split `agc.h` into `value.h`, `port.h`, `core.h` and `services.h` (§15.4), with each `.c` file including its layer's header; update the places that name `agc.h` (§15.4); add `vm/tools/check-layers.sh`, `make vm-layers` and the CI step (§15.5); tick row 7.2.1b and add the layers to the development skill (`references/vm.md`: the file table and a "which layer" note).

After that, a PR that adds a `vm/*.c` file puts it in a layer list, and a reviewer checks a new port function against §14 like any core change.
