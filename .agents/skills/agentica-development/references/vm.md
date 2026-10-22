# Bytecode VM development (phase 7)

The VM's codename is Aurora (Aurora VM). Only the docs use it: the binary,
the `AGENTICA_VM_*` variables, the `agc_` prefix, `.agcb` and `vm/` keep
their names.

`docs/vm/` is the contract (`docs/vm/README.md` gives the file for each
section), and `docs/roadmap/07-vm.md` lists what is built. When this guide and
`docs/vm/` disagree, `docs/vm/` wins. The VM is the only backend and the
reference: roadmap 7i deleted the Racket evaluator. Notes below that compare
with "the evaluator" record why a rule was copied from it.

Every C edit also reads `references/vm-c.md`.

## Pipeline and files

```text
check          (compiler/check/checker.agc)         the type of each expression, by node id
lower          (compiler/lower/lowering.agc)        checked program -> IR, or LOWER-UNSUPPORTED / LOWER-INTERNAL
bytecode write (compiler/bytecode/bytecode_writer.agc) IR -> bytecode; adjacent STEP merge; BYTECODE-LIMIT / -INTERNAL; the versioned .agcb file (magic, format version, Agentica version)
vm/agentica.c dist/agentica WORDS...: the front end (compiler/front_end.agc, carried in the binary) in a first runtime, then the program it hands over in a second (references/vm-core.md)
vm/agentica.c dist/agentica run [--max-steps N] [--seed N] [--flush-timeout MS] [--schedulers N] [--deny-run] [--deny-native] [--ai|--json] [--source-root DIR] -- file.agcb [args...]   (AGENTICA_FLUSH_TIMEOUT_MS sets the flush limit, default 30000; AGENTICA_SCHEDULERS sets the scheduler count, default one per logical core, at most 1024; --schedulers wins)
```

## Which layer

`vm/*.c` has three layers and a driver (`docs/vm/15-layers.md` §15). A file
includes the header of its layer, and `make vm-layers` keeps the direction. A
new `vm/*.c` file goes in `VM_SRC` (a driver file that has a `main` or only the
binary links, such as `launch.c` and `agentica.c`, has its own rule) and in one
list of `vm/tools/check-layers.sh`.

- **Core** (`core.h`): values, maps, text, the Json value, the interpreter, the
  scheduler, the loop, stdin, the loader, core builtins, diagnostics, tracing.
  It never includes or links a service.
- **Services** (`services.h`; `net.h` and `http_fields.h` include it): strings,
  numbers, JSON, files, streams, processes, TCP, HTTP, `Test`. They reach the
  core through the port in `port.h` (park and wake a task, jobs with a timeout,
  register and close a handle, spawn and cancel, fail and charge) and the value
  API in `value.h`, never `core.h`.
- **Adapters** (`tls.h`, `http_parse.h`): TLS over OpenSSL and the HTTP head and
  body parsers. They use their library and, from `value.h`, only the memory
  functions.
- **Driver** (`launch.c`, `agentica.c`, `builtin_tables.c`, `fuzz*.c`): wires
  the layers and includes `core.h` and `services.h`; `launch.h` and `embedded.h`
  are theirs.

Where a declaration goes: a type or function that values and services both need
goes in `value.h`; one a service calls to wait, do I/O or own a handle goes in
`port.h` (check a new one against `docs/vm/14-core-invariants.md`); one only the
core and the driver call goes in `core.h`; a service's export goes in
`services.h`. A `vm/tests/*.c` file includes what it uses. Third-party headers
stay in their place: `gc.h` in `value.c`, `uv.h` in `loop.c` and the stream
services, OpenSSL in `tls_openssl.c` (and `tls_trust*.c`) and
`digest_openssl.c`, picohttpparser in `http_pico.c`,
`yyjson.h` in `json.c`, `ffi.h` in `ffi_libffi.c`.

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
hand-checked expected output; a regenerated one needs a reviewed diff. Error
strings a program prints are program data: when a library
message changes, switch the fixtures that print it to printing only ok or
error in the same PR, or update their goldens on purpose. Message text,
spans, stderr wording, OS error text, exact step counts and the step-limit
span may change, but VM messages must stay clear for agents. Lowering may
optimize (inline, fold constants, move or merge `STEP`s) as long as the
goldens hold. Differences from the old evaluator in exit code, stdout or
code are recorded in `docs/vm/`.

**Trust model.** A `.agcb` is untrusted. Whatever it contains, the VM has no
memory errors or undefined behavior, runs no children with its own
`--deny-run`, and stops within `--max-steps`. Native code (`extern`) and
processes are allowed by default: run untrusted bytecode with `--deny-run`,
which turns on `--deny-native` too. The loader enforces the
termination rules: every backward jump lands on a `STEP`, every function that
calls starts with one, and a function without a leading `STEP` has at most 2
instructions. A file with Globals slots may write them only in the entry
function, which has no backward jump and is never called. A file that loads may
still compute wrong values or end with
`RUNTIME-INTERNAL`.

## Read next

- **Read:** `references/vm-c.md`
  - **When:** writing or reviewing any C in `vm/`: C style, failure and exit,
    Boehm GC rules

- **Read:** `references/vm-core.md`
  - **When:** values, lists, maps, strings, text forms, the interpreter,
    builtins tables, the loader, JSON, diagnostics, tracing

- **Read:** `references/vm-io.md`
  - **When:** the libuv loop and registry, stdin, stdout and stderr, `File`,
    `Dir`, `Path`

- **Read:** `references/vm-tasks.md`
  - **When:** the scheduler, task cancellation, `Channel`, the `Test` builtins,
    the latency test

- **Read:** `references/vm-net.md`
  - **When:** processes, the child channel, streams, TCP, TLS (OpenSSL), the
    HTTP client and server

- **Read:** `references/vm-lowering.md`
  - **When:** `compiler/lower/*.agc`, `compiler/bytecode/*.agc`, a new form or
    opcode, linked programs, closures, ranges, Results, tail calls

- **Read:** `references/vm-builtins.md`
  - **When:** adding or changing a C builtin (`VM_BUILTINS` in
    `compiler/lower/lower_tables.agc`, the tables) or a trace point

- **Read:** `references/vm-build.md`
  - **When:** make targets, the golden harness (`tests/vm_diff_support.py`,
    `make goldens`, the step-limit sweep), submodules (bdwgc, yyjson, libuv,
    picohttpparser, OpenSSL), sanitizers, fuzzing, portability

- **Read:** `references/vm-tests.md`
  - **When:** which C test (`vm/tests/`) or unittest module
    (`tests/test_vm_*.py`) covers a file, the sweep cost rule, and the timing
    and race rules of the tests
