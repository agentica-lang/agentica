# Bytecode VM development (phase 7)

The VM's codename is Aurora (Aurora VM). Only the docs use it: the binary,
the `AGENTICA_VM_*` variables, the `agc_` prefix, `.agcb` and `vm/` keep
their names.

`docs/vm/` is the contract (`docs/vm/README.md` gives the file for each
section). When this guide and `docs/vm/` disagree, `docs/vm/` wins.

Every C edit also reads `references/vm-c.md`.

## Pipeline and files

```text
check          (compiler/check/checker.agc)         the type of each expression, by node id
lower          (compiler/lower/lowering.agc)        checked program -> IR, or LOWER-UNSUPPORTED / LOWER-INTERNAL
bytecode write (compiler/bytecode/bytecode_writer.agc) IR -> bytecode; adjacent STEP merge; BYTECODE-LIMIT / -INTERNAL; the versioned .agcb file (magic, format version, Agentica version)
vm/agentica.c dist/agentica WORDS...: the front end (compiler/front_end.agc, carried in the binary) in a first runtime, then the program it hands over in a second (references/vm-core.md)
vm/agentica.c dist/agentica run [flags] -- file.agcb [args...]   (`dist/agentica run` alone prints the flags and their variables)
```

## Which layer

`vm/*.c` has three layers and a driver (`docs/vm/15-layers.md` §15.1: what each
may include; §15.4: which declaration goes in which header). `make vm-layers`
checks the direction and the third-party header places. A new `vm/*.c` file
goes in `VM_SRC` (a driver file with a `main`, such as `launch.c` and
`agentica.c`, has its own rule) and in one list of `vm/tools/check-layers.sh`.
A `vm/tests/*.c` file includes what it uses.

## Rules every change keeps

**Goldens, not parity** (`docs/vm/README.md` §1). The VM is the reference: each
fixture's golden holds its exit code, stdout, program stderr (`IO.warn`) and
diagnostic code; a runaway program stops with `RUNTIME-STEP-LIMIT` under
`--max-steps`. Network, process and protocol work is tested with goldens and
independent Node/Python peers: where the VM must talk to a real implementation,
use one whose library does the protocol work (Node's `http` for HTTP streaming,
since Python's `http.server` does not decode chunked request bodies); for raw or
hostile cases, use the language the test file already uses. A new golden gets
hand-checked expected output; a regenerated one needs a reviewed diff. Error
strings a program prints are program data: when a library message changes,
switch the fixtures that print it to printing only ok or error in the same PR,
or update their goldens on purpose. Message text, spans, stderr wording, OS
error text, exact step counts and the step-limit span may change, but VM
messages must stay clear for agents. Lowering may optimize (inline, fold
constants, move or merge `STEP`s) as long as the goldens hold.

**Trust model.** A `.agcb` is untrusted. Whatever it contains, the VM has no
memory errors or undefined behavior, does nothing its own `--deny-*` flags turn
off, and stops within `--max-steps`. Everything is allowed by default: run
untrusted bytecode with `--sandbox` (every `--deny-*` flag, so `--deny-native`
too). The loader enforces the termination rules: every backward jump lands on a
`STEP`, every function that calls starts with one, and a function without a
leading `STEP` has at most 2 instructions. A file with Globals slots may write
them only in the entry function, which has no backward jump and is never called.
A file that loads may still compute wrong values or end with `RUNTIME-INTERNAL`.

## Read next

| Reference | When |
|---|---|
| `vm-c.md` | any C in `vm/`: C style, failure and exit, Boehm GC rules |
| `vm-core.md` | values, lists, maps, strings, text forms, the interpreter, builtin tables, the loader, JSON, diagnostics, tracing |
| `vm-io.md` | the libuv loop and registry, stdin, stdout, stderr, `File`, `Dir`, `Path` |
| `vm-tasks.md` | the scheduler, cancellation, `Channel`, the `Test` builtins, the latency test |
| `vm-net.md` | processes, the child channel, streams, TCP, TLS, the HTTP client and server |
| `vm-lowering.md` | `compiler/lower/`, `compiler/bytecode/`, a new form or opcode, closures, ranges, Results, tail calls |
| `vm-builtins.md` | adding or changing a C builtin (`VM_BUILTINS`, the tables) or a trace point |
| `vm-build.md` | make targets, the golden harness, the step-limit sweep, submodules, sanitizers, fuzzing, portability |
| `vm-tests.md` | finding the C test or `tests/test_vm_*.py` module of a file, what they cannot see, the sweep cost rule, timing and race rules |
