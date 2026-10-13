## 15. VM layers

**Status:** planned by the owner on 2026-10-13, row 7.2.1b of the [roadmap](../roadmap/README.md) (checklist in [`07-vm.md`](../roadmap/07-vm.md#7l-vm-layers)). No behavior change: the goldens do not move.

The C VM gets a light layering: three layers (core, services, adapters) with one-way dependencies, plus a driver on top that wires them; one small port between the services and the core; one header per layer; and a CI check that keeps the direction. It is not DDD and not a plugin system: calls stay direct, and function pointers stay where they already are (callbacks), not as tables around every module.

Words. §14 calls everything under the scheduler "the VM core" (`task.c`, `loop.c`, `input.c`, `files.c`, `process.c`, `tcp.c`, HTTP and TLS). Here **core** is narrower: the scheduler, the loop, the values and what they need. §14's five rules hold for the core and the services alike.

This is the first part of 7l ([§21](../future/21-vm-layers.md#21-vm-layers)): it replaces §21's first item (the `core`/`rt`/`lib` header split) with the split below. Opcode helpers, builtin metadata flags and the callback-builtin protocol stay in 7l at step 8.1. §14.6 asks of the layers: "Does each layer replace code, or only add a boundary?" Answer: mostly a boundary, checked by CI. It adds no runtime concept and replaces two pieces of code: `testing.c`'s hand-made wait becomes the port's `agc_task_join` (V5), and `loop.c`'s process tag check becomes a resource field that `process.c` sets (V3).

Line numbers in this section are from master at 7a40b78. HTTP 20c and the blocked-read fix land first and move `input.c`, `files.c` and the HTTP files, so each implementation PR maps the calls again on the tree it starts from (§15.7).

### 15.1 Layers

| Layer | Files | May use |
|---|---|---|
| **Core** | `value.c`, `map.c`, `equal.c`, `text.c`, `unicode_data.c`, `json_value.c` (new, §15.6 V1), `interp.c`, `task.c`, `loop.c`, `input.c`, `random.c`, `loader.c`, `builtins.c`, `diag.c`, `trace.c` | `value.h`, `port.h`, `core.h`, `trace.h`, Boehm GC, libuv |
| **Services** | `strings.c`, `numbers.c`, `json.c`, `json_typed.c`, `files.c`, `stream.c`, `process.c`, `tcp.c`, `http_client.c`, `testing.c` | `value.h`, `port.h`, `services.h`, `net.h`, `trace.h`, adapter headers, libuv, yyjson (`json.c` only) |
| **Adapters** | `tls_openssl.c` (`tls.h`), `http_pico.c` and `http_body.c` (`http_parse.h`) | their own header, their library, and from `value.h` only the memory functions (`agc_alloc`, `agc_alloc_atomic`, `agc_size_add`, `agc_size_mul`, `agc_out_of_memory`) |
| **Driver** (not a layer: it wires them) | `main.c`, `builtin_tables.c` (new, §15.6 V2), `fuzz.c`, `fuzz_main.c` | everything |

`vm/tests/*.c` may use everything. `trace.h` (tracing; `agc_trace_emit` is used by `http_client.c`, `process.c` and `tcp.c`) is shared by every layer but the adapters.

Notes on the choices:

- **`unicode_data.c` is core, not an adapter.** It is generated data, not a wrapper of a library, and `text.c` (core) prints strings with its `agc_write_*` ranges. Its case tables (used by `strings.c`) are data too; all its tables are declared in `value.h`.
- **`input.c` and `builtins.c` are core.** stdin's waiters are a list the scheduler owns (§14.1), and `agc_task_cancel` takes a task out of it (`task.c:126`). `builtins.c` holds the `IO`, `System`, `List`, `Map`, `Result` and `Range` builtins over core values, and `agc_find_builtin`, which the loader calls.
- **`stream.c` is a service.** It is the kit the stream services share (`agc_inbuf_*`, `agc_stream_lock`, `agc_stream_write`); only `process.c`, `tcp.c` and `http_client.c` use it.
- **`http_body.c` is an adapter, with `http_pico.c`.** `http_parse.h` is a plain protocol header with no VM values; `http_pico.c` calls `http_body.c`'s syntax helpers (`agc_http_token`, `agc_http_framing`, ...), so the two are one unit. `http_body.c` uses `agc_size_mul` and `agc_out_of_memory` (`http_body.c:142-146`), so an out-of-memory body still ends with exit 70 (§6.3).
- **yyjson has no adapter file.** `json.c`'s parser builds VM values straight from the yyjson tree (`convert`, `json.c:189`); a separate adapter would need an extra tree or VM values, so it would add code and replace none. Instead, the check (§15.5) keeps `yyjson.h` to `json.c`.
- **libuv is not wrapped.** The services own their own `uv_tcp_t`, `uv_pipe_t` and timers through `agc_io_uv`. A wrapper would be a second API over one library.
- **Services may call each other.** `http_client.c` uses `tcp.c` (`net.h`), `json_typed.c` uses `json.c`, `json.c` and `testing.c` use `strings.c` helpers. That is fine inside a layer.

### 15.2 The port

The port is what a service needs from the core to do I/O and to wait, as §14 allows it. It exists today, except `agc_task_join` (V5) and the resource field of V3, which PR 1 adds; this plan names it and puts it in its own header (`port.h`).

| Job | Functions |
|---|---|
| Park and wake a task | `agc_task_park` (`task.c:65`), `agc_task_enqueue` (`task.c:31`), `agc_task_wake` (`task.c:25`), `agc_task_wake_all` (`task.c:40`) |
| Submit a job (loop or pool), with its timeout | `agc_io_start` (`loop.c:377`) with an `agc_io_kind` (`work`, `done`, `expired`, `drop`, `cancel`), `agc_io_ready` (`loop.c:391`), `agc_io_detached` (`loop.c:385`), `agc_io_then` (a pool job's `more` step, which may keep it waiting on the loop) |
| Wait on a descriptor on the loop | `agc_poller_open`, `agc_poller_wait`, `agc_poller_pause`, `agc_poller_close` (a `uv_poll_t` that owns its descriptor; `files.c`, and `input.c` in the core) |
| Set a timer | no own function: a timer is the job's `timeout_ms` (§14.2); `Task.sleep` is a job with no work. The three other timers of §14.2 use libuv through `agc_io_uv` and stay exceptions |
| Register, own and close a handle | `agc_register` (`loop.c:49`), `agc_own` (`loop.c:73`) with an `agc_close_fn`, `agc_unregister` (`loop.c:120`), `agc_resource_id` (`loop.c:47`); the handle's lock FIFO: `agc_handle_wait` (`loop.c:420`); the resource's `goodbye` hook (a release-shaped function the exit path calls through `agc_io_goodbye`; `tcp.c` sets it for TLS `close_notify`); the V3 field (new) |
| Reach the loop and signals | `agc_io_uv` (`loop.c:337`), `agc_io_block_stop` (around a fork or a thread start). The list of stop signals is static in `loop.c`: since the blocked-read fix no service reads it (`process.c` has no signal watchers) |
| Spawn, wait for, cancel and observe tasks (for `Test.run`) | `agc_task_spawn` (`task.c:347`), `agc_task_cancel` (`task.c:146`), `agc_task_observe` (`task.c:292`), `agc_report_unobserved` (`task.c:285`), `agc_task_join` (new, V5) |
| Charge, fail, write | `agc_charge`, `agc_charge_bytes` (`interp.c:84`, `90`), `agc_value_units`, `agc_fail`, `agc_fail_text`, `agc_exit`, `agc_write`, `agc_flush` |
| Program lookups | `agc_builtin_struct` (`builtins.c:456`) |
| The test child protocol | `agc_protocol_line` (`input.c:290`, used by `testing.c:273`); 25c removes it (V10) |

The core calls services back only through function pointers that a service handed over: the job kind (`agc_io_kind`), `agc_close_fn` and `agc_release_fn` of a resource, and `agc_builtin_fn` of a builtin. It never calls a service by name.

Services still read fields of the runtime structs (`agc_vm`, `agc_task`, `agc_runtime`, `agc_resource`); making them opaque would not be a mechanical change. The rule: a service may read the run's settings in `vm->rt` (`trace`, `cwd`, `no_files`, `allow_run`, `program`, ...), the fields of a resource it registered, and the per-task fields that exist for it (`cursor` for `strings.c`, `random` for `numbers.c`, `test` and `test_run` for `testing.c`). It does not walk or change the scheduler's lists; V6 is the one exception left.

### 15.3 Function-pointer tables

Allowed only where two real implementations are chosen at run time. Today there is no such place, so the plan adds none:

- **TLS** has one implementation, `tls_openssl.c`, behind `tls.h`, chosen at link time. A second backend would be a second `.c` file behind the same header, still chosen by the Makefile; a table only if one binary needs both.
- **The loop backend** is not ours: libuv picks io_uring or epoll inside. The VM only sets `UV_USE_IO_URING=0` for itself (`loop.c:330-331`) and drops it from children's environment (`process.c:22`, `process.c:815`).
- **Platforms** are chosen at compile time with `#ifdef __linux__` stubs (`loop.c:583-631`, `files.c:1076`, `tcp.c:1181`, `process.c:981`, `http_client.c:956`, `input.c:152`). That stays.

The function pointers that exist are callbacks (job kinds, close and release functions, builtins, `agc_conn_watch`), not tables of implementations, and they stay.

### 15.4 Headers

`vm/agc.h` (655 lines, included by every `.c` file) is split into four headers in one chain:

```text
value.h  <-  port.h  <-  core.h
                     <-  services.h  <-  net.h
```

`port.h` includes `value.h`; `core.h` and `services.h` each include `port.h` and nothing else of ours, so a service never gets `core.h` indirectly. Every type a header's own declarations name is defined, or forward-declared, in that header or one below it. PR 2 compiles each header on its own (`cc -fsyntax-only` with the VM's flags, one per header, part of `make vm-layers`), so a missing type fails at once. What goes where, by name (line ranges of `agc.h` would be stale by then):

- **`value.h`** (includes `trace.h`): the limits; `agc_tag`; `agc_value` and the value structs (string, list, map, struct, enum, result, fn, range); the Json value types (`agc_json_kind`, `agc_json_member`, `agc_json`, `agc_json_buffer`); opcodes, `agc_instr`, `agc_span`, `agc_source`; forward typedefs of `agc_vm`, `agc_task` and `agc_resource`; the handle value structs `agc_process`, `agc_socket`, `agc_listener` and `agc_http_client` (anonymous typedefs, so they cannot be forward-declared; they hold only `agc_resource *` and an `int64_t`, and live here next to their constructors); `agc_test_case`; `agc_builtin_fn`, `agc_native_kind`, `agc_cost_rule` and `agc_builtin` (`agc_program` names `agc_builtin`); the program tables (`agc_function`, `agc_type`, the struct, enum and variant defs, `agc_program`); `agc_random` and its functions; `agc_gc_info`; memory (`agc_init` to `agc_gc_stats`); value constructors and `agc_as_*`; the UTF-8, string, map, text and equality functions; `agc_sort_by_keys`; every Unicode table; the Json value API (`agc_json_ascii`, `agc_json_grow`, `agc_json_put`, `agc_json_leaf`, `agc_json_object`, `agc_json_array`, `agc_json_find`, `agc_json_encode`, `agc_json_from`, and the node helpers that V1 exports); `agc_error_value`.
- **`port.h`**: `agc_release_fn`, `agc_close_fn`, `agc_resource_kind` and the body of `struct agc_resource`; forward typedefs of `agc_test_note` (the struct gets a tag, `struct agc_test_note`, so the forward typedef matches), `agc_test_run`, `agc_registry`, `agc_loop`, `agc_io_job` and `agc_native`; `agc_frame`; `agc_io_kind`; `agc_outcome_kind`, `agc_style`, `agc_outcome`; `agc_input_status` and `agc_input`; `agc_runtime`, `agc_task_state`, `agc_turn_result`, `agc_lock_status`, `struct agc_task`, `struct agc_vm`; `agc_file_id` and `agc_file_ids` (`rt->inherited`); and the port functions of §15.2, with `agc_io_block_stop` under `__linux__` (so `port.h` includes `<signal.h>` there).
- **`core.h`**: what only the core and the driver call: `agc_vm_init`; tasks and turns (`agc_new_task`, `agc_task_call`, `agc_task_enter`, `agc_task_remove`, `agc_turn_begin`, `agc_turn_charge`, `agc_turn_finish`, `agc_run_turn`, `agc_vm_run`); the loop's own life (`agc_uv_version`, `agc_io_init`, `agc_io_poll`, `agc_io_finish`, `agc_io_detach`, `agc_io_close`); the exit path and stop signals (`agc_io_watch_stop`, `agc_io_stop_signal`, `agc_io_children_stopped`, `agc_io_goodbye`, `agc_io_flush_files`, `agc_stop`); ownership internals (`agc_owned_of`, `agc_give_owned`, `agc_close_owned`, `agc_handle_leave`); the loader (`agc_load`, `agc_load_traced`); `agc_find_builtin`, the builtin table list type and its `extern` list (defined in `builtin_tables.c`), and `agc_task_builtins` with its count (defined in `task.c`, core); stdin (`agc_input_open`, `agc_input_peek`, `agc_input_line`, `agc_input_all`, `agc_input_bytes`); diagnostics (`agc_print_diagnostic`, `agc_crash_text`, `agc_print_unobserved`, `agc_print_flush_timeout`); `agc_fuzz_one`.
- **`services.h`**: the body of `struct agc_test_note`; `agc_inbuf`; the `strings.c` helpers others use (`agc_utf8_encode`, `agc_utf8_count`, `agc_utf8_offset`, `agc_text_find`, `agc_change_case`, `agc_parse_int`, `agc_parse_float`, `agc_around`) with `agc_number_status` and `AGC_NOT_FOUND`; the JSON parser and typed JSON (`agc_json_status`, `agc_json_version`, `agc_json_parse`, `agc_json_status_message`, `agc_json_to_float`, `agc_json_decode`, `agc_json_schema`); `files.c`'s exports (`agc_files_init`, `agc_files_close`, `agc_host_path`, `agc_utf8_error`, `agc_system_error`, `agc_each_fd`, `agc_files_inherited`, `agc_files_forget`); `agc_processes_stop` (`process.c`, called by the driver's exit path); the stream kit (`agc_new_lock`, `agc_stream_lock`, `agc_stream_bad_timeout`, `agc_stream_timed_out`, `agc_inbuf_*`, `agc_stream_write`, with forward `struct uv_stream_s` and `struct uv_write_s`); `agc_test_protocol`; the builtin tables of the services (strings, numbers, json, files, process, tcp, http, test) and their counts.

`net.h` (the `agc_conn` API of `tcp.c`, used by `http_client.c`) includes `services.h` and `tls.h`. `tls.h`, `http_parse.h` and `trace.h` keep their content.

Places that name `vm/agc.h` and change with the split: `tests/bytecode-test.rkt:15` (reads `agc_opcode`, now in `value.h`), `vm/tools/gen-unicode.rkt:186` (the include line of `unicode_data.c`), `vm/net.h:4`, every `vm/tests/*.c`, the development skill (`SKILL.md:51`, `74`, `111`; `references/vm.md:28`, `336`, `477`, `481`; `references/ci.md:136`, which says jscpd covers `vm/agc.h`; `.jscpd.json` scans all of `vm/`, so it needs no change), and the `docs/vm/` files that cite it.

### 15.5 The layer check

`vm/tools/check-layers.sh <object dir>`, run by `make vm-layers` (a new target, added to `.PHONY` and to the target list at the top of the `Makefile`; it depends on `vm`). CI runs it in the `test` job of `ci.yml` after `make vm vm-test`, since its link rule needs the objects; that job checks that `rg` is installed and installs ripgrep if not. It fails when:

1. a `vm/*.c` file is in no layer list, or a listed file does not exist;
2. a core file includes `services.h`, `net.h`, `tls.h` or `http_parse.h`;
3. a service or adapter file includes `core.h`;
4. an adapter file includes `port.h`, `services.h` or `net.h` (it may include `value.h`; rule 8 keeps it to the memory functions);
5. a third-party header is included outside its place: `<gc.h>` only in `value.c`; `<openssl/...>` only in `tls_openssl.c`; `<picohttpparser.h>` only in `http_pico.c`; `"yyjson.h"` only in `json.c`; `<uv.h>` only in `loop.c`, `input.c`, `files.c` and the stream services (`stream.c`, `process.c`, `tcp.c`, `http_client.c`). `input.c` and `files.c` are on the list because the blocked-read fix puts stdin, FIFOs and character devices on loop handles;
6. a `.c` file declares an `agc_` name at file scope instead of taking it from a header: a function prototype, or an `extern` or array declaration of an `agc_` variable (`extern char **environ` in `process.c` is not an `agc_` name);
7. **the link rule**: after the build, a core object's undefined symbols (`nm -u`) include a symbol that a service object defines (`nm -g --defined-only`);
8. an adapter object's undefined `agc_` symbols are other than the memory functions of §15.1 and symbols of another adapter object (`http_pico.o` uses `http_body.o`).

The link rules (7, 8) are the authority: a declaration that rule 6 misses still fails there. Rules 1 to 6 need no build and give a fast, readable error. An `rg` exit status of 2 (a bad pattern, a missing file) is a failure, not "no match".

```sh
#!/bin/sh
set -eu
obj="$(cd "${1:?usage: check-layers.sh OBJECT_DIR}" && pwd)"
cd "$(dirname "$0")/.."
core="value.c map.c equal.c text.c unicode_data.c json_value.c interp.c task.c loop.c input.c random.c loader.c builtins.c diag.c trace.c"
services="strings.c numbers.c json.c json_typed.c files.c stream.c process.c tcp.c http_client.c testing.c"
adapters="tls_openssl.c http_pico.c http_body.c"
driver="main.c builtin_tables.c fuzz.c fuzz_main.c"
memory="agc_alloc agc_alloc_atomic agc_size_add agc_size_mul agc_out_of_memory"
fail=0
bad() { echo "vm layers: $*" >&2; fail=1; }
found() { s=0; rg "$@" || s=$?; [ "$s" -le 1 ] || { bad "rg failed: $*"; return 1; }; [ "$s" -eq 0 ]; }
for f in *.c; do
  case " $core $services $adapters $driver " in *" $f "*) ;; *) bad "$f is in no layer" ;; esac
done
for f in $core $services $adapters $driver; do [ -f "$f" ] || bad "$f is listed but missing"; done
if found -n '#include "(services|net|tls|http_parse)\.h"' $core; then bad "a core file includes a service or adapter header"; fi
if found -n '#include "core\.h"' $services $adapters; then bad "a service or adapter includes core.h"; fi
if found -n '#include "(port|services|net)\.h"' $adapters; then bad "an adapter includes the port or a service header"; fi
only() { if found -n --max-depth 1 "$1" --glob '*.c' --glob '*.h' $(for f in $2; do printf -- "--glob !%s " "$f"; done) .; then bad "$1 outside $2"; fi; }
only '#include <gc\.h>' "value.c"
only '#include <openssl/' "tls_openssl.c"
only '#include <picohttpparser\.h>' "http_pico.c"
only '#include "yyjson\.h"' "json.c"
only '#include <uv\.h>' "loop.c input.c files.c stream.c process.c tcp.c http_client.c"
if found -n --max-depth 1 --pcre2 '^[A-Za-z_][\w \*]*\bagc_\w+\([^{]*\)\s*;\s*$' --glob '*.c' .; then bad "an agc_ prototype in a .c file"; fi
if found -n --max-depth 1 '^\s*extern\b.*\bagc_|^[A-Za-z_][\w \*]*\bagc_\w+\s*\[[^\]]*\]\s*;' --glob '*.c' .; then bad "an agc_ variable declared in a .c file"; fi
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
defined() { for f in $1; do nm -g --defined-only "$obj/${f%.c}.o"; done | awk '{print $NF}' | sort -u; }
used() { nm -u "$obj/${1%.c}.o" | awk '{print $NF}' | sort -u; }
defined "$services" > "$tmp/services"
for f in $core; do
  used "$f" | comm -12 - "$tmp/services" > "$tmp/hit"
  if [ -s "$tmp/hit" ]; then bad "core $f uses service symbols: $(tr '\n' ' ' < "$tmp/hit")"; fi
done
{ printf '%s\n' $memory; defined "$adapters"; } | sort -u > "$tmp/adapter-ok"
for f in $adapters; do
  used "$f" | { rg '^agc_' || true; } | comm -23 - "$tmp/adapter-ok" > "$tmp/hit"
  if [ -s "$tmp/hit" ]; then bad "adapter $f uses: $(tr '\n' ' ' < "$tmp/hit")"; fi
done
exit "$fail"
```

This is a sketch for Linux (ELF `nm`); its PR runs it, with one negative self-test: in a scratch copy of `vm/`, a planted violation (a core file calling a service function through a local prototype) must make it exit 1. The two declaration patterns of rule 6 match nothing at 7a40b78.

### 15.6 Violations found

Mapped at 7a40b78 by listing, for each `vm/*.c` file, the `agc_` functions it calls that another file defines; a review build checked the list against `nm` and found no other core-to-service call. Each row is a place where the core names a service or service data, or a layer reaches past the port.

| # | Where | What | Fix |
|---|---|---|---|
| V1 | `text.c:148`, `280`, `285`; `equal.c:66` | `to_s`, `inspect` and `==` of a `Json` value call `agc_json_encode` in `json.c` (a service) | **Move.** The Json value is a core type (`AGC_T_JSON`), so its code goes to a new core file `json_value.c`: `walk_frame` (`json.c:20-26`); `new_node`, `leaf` and `agc_json_ascii` (`json.c:49-60`; `failure()` at `json.c:543` keeps calling `agc_json_ascii`); `key_compare` and `sort_members` (`json.c:105-131`, shared by the parser and `agc_json_find`); `container`, `store`, `finish` and `agc_json_grow` (`json.c:132-163`); the writer and `agc_json_from` (`json.c:317-538`); `agc_json_leaf`, `agc_json_object`, `agc_json_array` and `agc_json_find` (`json.c:556-578`). The statics the parser still needs become `agc_json_*` functions in `value.h`. `json.c` keeps the yyjson parser, `agc_json_status_message`, `agc_json_to_float` and the `JSON.*` builtins; `agc_json_decode` and `agc_json_schema` stay in `json_typed.c` |
| V2 | `builtins.c:433-444` | the builtin table list names every service's table (`agc_file_builtins`, `agc_tcp_builtins`, `agc_test_builtins`, ...) | **Move** the list, in the same order (`agc_find_builtin` returns the first match), to a new driver file `builtin_tables.c`; `agc_find_builtin` stays in `builtins.c` and reads the list through `core.h`. The list is the one place that wires the services in, like `main.c` |
| V3 | `loop.c:253` | `discard` (a detached job's result) skips `AGC_T_PROCESS` by name: a process rule in the loop | **Port data.** The tag check becomes a new `agc_resource` field (`keep_detached`, say) that `process.c` sets when it registers the process; `discard` reads the field, not the tag |
| V4 | `task.c:377` | `await_task` builds its error with `agc_error_value`, defined in `stream.c` (a service) | **Move** `agc_error_value` (four lines, `stream.c:18-21`) to `value.c` |
| V5 | `testing.c:224-231` | `wait_for` sets `vm->task->awaiting`, puts the task on `target->waiters` and parks: the waiting half of `await_task` (`task.c:367`), without its crashed and cancelled branches | **Port function** `bool agc_task_join(agc_vm *vm, agc_task *target)` in `task.c`: if the target is done, clear `awaiting` and return false; else set `awaiting`, enqueue the task on the target's waiters, park (with retry) and return true. `wait_for` becomes this call; `await_task` calls it and, after false, handles the result (crashed, cancelled, value) as today |
| V6 | `testing.c:186-205` | `cancel_leftovers`, `unobserved_of` and `observe_test` walk `caller->children` and `vm->crashes` and read `t->test` | **Accepted for now.** Reads only, and every change goes through `agc_task_cancel` and `agc_task_observe`. 24b's one hand-off form may give a task group to replace them; if it does, they move behind the port then |
| V7 | `loop.c:79-82` (`agc_owned_of`) | the core reads the `state` field of `agc_socket`, `agc_listener` and `agc_process` | **Accepted**: those handle values are declared in `value.h`, since ownership (§14.5) must find a value's resource. 24b replaces its caller in `builtin_spawn` (`task.c:362`) |
| V8 | `value.c:268-313`, `445-478`; `text.c:105-111`; `agc.h:33` | the tag enum, constructors, `agc_as_*` and the printed names (`<Socket>`, `<Process>`, ...) of service values live in the core | **Accepted**: the tag set is one closed enum that the loader, `text.c` and `equal.c` need; no service code is called |
| V9 | `agc.h:375-377`, `task.c:350`; `agc.h:391`; `agc.h:334` | service state in core structs: `agc_task`'s `test`, `note` and `test_run` (a spawned task inherits `test`), `agc_vm.process_guard`, and the `allow_run`, `drop_uring_env` and `no_files` settings | **Accepted**: opaque pointers and settings, no calls. The driver sets the settings |
| V10 | `interp.c:54`, `input.c:183`, `input.c:290` | 25b's `out_mid_line`, the reserved stdin and `agc_protocol_line` (core code that exists for `testing.c`) | **Removed by 25c** (row 7.2.1a), which comes after this row and moves the child protocol to fd 3 |
| V11 | `main.c:409-430` | the driver calls `agc_files_init`, `agc_files_close`, `agc_test_protocol`, `agc_tls_version` and `agc_json_version` | **Accepted**: `main.c` is the driver |
| V12 | `http_body.c:142-146` | an adapter calls `agc_size_mul` and `agc_out_of_memory` | **Accepted**: memory only, so out of memory keeps its exit code (§6.3); rule 8 of §15.5 keeps it to memory |

Not violations: `loader.c:460` calls `agc_find_builtin` (core); the core's other cross-file calls stay inside the core; the services call the core only through the functions of §15.2 and the value API.

### 15.7 Implementation PRs

Two PRs, both VM-only and mechanical, both with no change to the goldens. They wait for HTTP 20c and for the blocked-read fix (both change `input.c`, `files.c` and the HTTP services, so the moves would conflict), and come before 25c and 24b, so that 25c's new `Process` builtins and 24b's ownership change are written on the port. Each PR first maps the calls again on the tree it starts from (as in §15.6) and updates §15 where 20c or the fix changed them.

1. **Moves.** V1 (`json_value.c`), V2 (`builtin_tables.c`), V3 (the resource field), V4 (`agc_error_value`) and V5 (`agc_task_join`). Both new files join `VM_SRC` in the `Makefile`. `agc.h` stays one header in this PR. It runs `make dup-check`: the jscpd baseline (`.jscpd-baseline.json`) holds fingerprints, so a moved clone can show up as new; remove the copy rather than grow the baseline.
2. **Headers and the check.** Split `agc.h` into `value.h`, `port.h`, `core.h` and `services.h` (§15.4), with each `.c` file including its layer's header and each header compiled on its own; update the places that name `agc.h` (§15.4); add `vm/tools/check-layers.sh`, `make vm-layers`, its negative self-test and the CI step (§15.5); tick row 7.2.1b and add the layers to the development skill (`references/vm.md`: the file table and a "which layer" note; `references/ci.md`: the new check).

After that, a PR that adds a `vm/*.c` file puts it in a layer list, and a reviewer checks a new port function against §14 like any core change.
