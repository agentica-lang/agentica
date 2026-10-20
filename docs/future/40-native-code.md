## 40. Native code and FFI

**Status:** decided by the owner on 2026-10-20: packages, then the FFI, then the
JIT. The order and its reason are in [40.5](#405-order). The owner raised the
idea on 2026-10-14: "something like Cython, but for Agentica", and "FFI will be
needed to use interesting things already done in C/C++/Rust". Nothing here is
built yet.

### 40.1 Goal

Run hot Agentica code faster. Also call existing native libraries, written in C,
C++ or Rust, through the C ABI. Three things stay as they are: values are
immutable, the garbage collector manages memory, and libuv does the I/O. When
native code needs to wait in a way libuv cannot serve, it gets an explicit exit
(40.3a).

### 40.2 Why not a Cython-style dialect

Cython's main gain is adding static types to Python. Agentica already has static
types, so that gain is already here.

A separate "fast dialect" would be a second way to write the same function. That
breaks the one-way rule of [section
25](25-ruby-typed-idioms.md#25-ruby-typed-idioms): one way to do each thing. So
the same code should get faster instead. The JIT does that (40.3b). The FFI adds
calls into native libraries, not a second language.

### 40.3 Three parts, in this order

**a. FFI and native modules.** A native module declares its functions with a
typed signature. This is a sketch, not the final syntax:

```text
extern def crc32(data: String) -> Int
```

The native code is written against a small, stable C API of the VM. C++ and Rust
use `extern "C"`. The rules are:

- Native code gets immutable values. It returns new values through the API. It
  may change only its own buffers.
- A native function that returns nothing maps to the completion concept of the
  grammar's process rules (`ok()` for a `Result[Void]`), once the FFI's ABI and
  ownership rules land.
- It never stores GC pointers in `malloc` memory. This is the VM's existing rule
  ([`16-architecture.md`](../vm/16-architecture.md) §16.5).
- Conversions come first for `Int`, `Float`, `Bool`, `String`, `List`, `Map` and
  structs. `Bytes` can follow when the compact type of [section
  binary data (phase 13) lands.

Each native function declares a call kind, which says where it runs (40.3.1).
Only its task waits, and the scheduler keeps running. The libuv pool takes only
bounded work ([`14-core-invariants.md`](../vm/14-core-invariants.md) §14.1), so
a call that may wait for a long time cannot go there. Long-lived native work
needs its own thread with a cancel exit. Calls that need their own event loop
are out of scope at first.

The first FFI has no generator: native code is written by hand against the C
API header (40.3.1). Two layers come later. A thin `extern` layer generates the
C glue for simple signatures (Int, Float, Bool, String and `Bytes`, with no raw
pointers). A generator that reads C headers, as cgo or bindgen do, may come much
later, as an optional tool. The Cython-style dialect stays rejected (40.2).

**b. The JIT** ([section 22](22-jit.md), roadmap 9.1, already required). Hot
functions become native code and give the same results. There is no language
change.

**c. AOT, maybe later.** `agentica build --native` compiles a whole program to
native code. It reuses the opcode helpers of the VM layers (roadmap
[7l](../roadmap/07-vm.md#7l-vm-layers)), which the JIT also uses. Build it only
if measurements ask for it.

### 40.3.1 The native module header and its three call kinds

The owner's idea of 2026-10-15: a C header, for example `agentica_native.h`,
that helps integrate C and C++ libraries. It belongs to part 40.3a, so it comes
before the JIT (40.5).

The header is the stable public form of the VM's internal callback-builtin
protocol (roadmap row 8.1, [7l](../roadmap/07-vm.md#7l-vm-layers)). The callback
builtins
(`map`, `filter`, `reduce` and the rest) already switch out only between their
callbacks ([`10-io-scheduler.md`](../vm/10-io-scheduler.md) §10.2.1,
"Builtins"). A native module uses the same mechanism, so there is one mechanism,
not two. A native function declares its call kind in the header. The VM decides
where it runs, and the library never touches libuv directly.

The three call kinds:

1. **Fast.** Short, bounded work, such as a hash, crc32 or a small parse. It
   runs on the scheduler thread, like a builtin, and is charged as a long
   builtin (§10.2.1). It must not block or wait.
2. **Compute.** CPU-bound work that may take long: compression, image or numeric
   work. It runs on a compute pool that the VM owns, not on the libuv pool,
   which takes only bounded work (§14.1). The calling task parks, and other
   tasks keep running. The call gets a cancel flag that the native code polls,
   so a cancelled task or a stop ends the call at the next poll. The pool sees
   only copies of the arguments, made on the scheduler before the job starts,
   because a pool thread never touches GC memory (§16.5). The result is built
   through the API on the scheduler that resumes the task (§16.2).
3. **I/O.** A library that talks to the outside world: a database client, or a
   protocol. If it exposes a non-blocking file descriptor, the VM watches it
   with `uv_poll` on the I/O thread, the only libuv loop (§16.1), and calls the
   library back there. `uv_poll` sets the descriptor non-blocking, so the
   library must accept that. The callback must be short, must not block, and
   builds no GC values (§16.5). If the library can only block, it gets its own
   thread per handle, with a cancel exit (40.3a). The handle belongs to the task
   that opened it (§14.5).

- **Kind:** Fast
  - **Runs on:** the scheduler thread, in the task's turn
  - **Waits how:** does not wait; charged as a long builtin
  - **Cancel:** none: it runs to its end, as a builtin does
  - **Internal precedent:** `String.*`, `Int.bit_*` (ordinary builtins)

- **Kind:** Compute
  - **Runs on:** a compute pool of the VM, not the libuv pool
  - **Waits how:** the task parks on a job; other tasks run
  - **Cancel:** a cancel flag, polled by the native code
  - **Internal precedent:** file work on the libuv pool, which is bounded;
    compute needs a pool of its own

- **Kind:** I/O
  - **Runs on:** the I/O thread for a descriptor; a thread per handle for a
    library that can only block
  - **Waits how:** the task parks on the handle's job (§14.1)
  - **Cancel:** the job is detached and its cancel half stops the watch (§14.3)
  - **Internal precedent:** TCP and HTTP on the loop; `Process.*`

A compute pool is a new part of the core, so it must pass the entry rule of
§14.6: a use case, and an answer for how it waits, times out, is cancelled, ends
and owns its handles (§14.1 to §14.5).

**Values and trust.** The value rules of 40.3a apply to every kind: conversions
only, immutable inputs, new values through the API, and no GC pointer in
`malloc` memory (§16.5). A native module loads only with `--allow-native`
(40.4).

### 40.4 Open questions and risks

- **Trust.** Today an `.agcb` cannot break memory. The VM's trust model
  ([`docs/vm/README.md`](../vm/README.md) §1) says so. A native library can
  break memory. So native code needs an explicit flag, such as `--allow-native`,
  as `--allow-run` does for processes
  ([`10-io-processes.md`](../vm/10-io-processes.md)).
- **Distribution.** The toolchain stays one binary, `agentica`, with the front
  end and the VM inside ([§18](18-front-end-language.md)). That is enough for
  simple programs. A program that needs native C, C++ or Rust libraries may
  ship or load them, and that is acceptable. The package system
  ([§45](45-packages.md)) is planned as how such libraries get distributed and
  installed. Loading still needs `--allow-native`. Open: link native modules
  statically into the binary at build time, or load `.so` files only when the
  flag is set.
- **Multicore.** Schedulers run in parallel
  ([`16-architecture.md`](../vm/16-architecture.md)), so the C API must follow
  its rules. The C API is also a new part of the core, so it must pass the entry
  rule of [`14-core-invariants.md`](../vm/14-core-invariants.md) §14.6.
- **Step limits and turn costs.** A fast call is charged like a long builtin
  ([`10-io-scheduler.md`](../vm/10-io-scheduler.md) §10.2.1). It cannot be
  stopped in the middle, so `--max-steps` cannot end it while it runs. A compute
  call ends at its next poll of the cancel flag (40.3.1).
- **Errors and crashes.** A native error becomes an error `Result`, never a
  crash. A native crash, such as a segfault, still kills the VM, and the VM
  cannot catch it.
- **Platform.** Linux only for now, the same first target as the JIT.
- **Which libraries.** Each native module needs a real library that asks for it.
  Examples: compression, image or numeric libraries, SQLite, or a Rust crate.
- **Compute pool.** Its size, and how it shares the CPUs with the libuv pool and
  the schedulers. Fairness with the libuv pool is open: bounded file work must
  not wait behind a long compute job.
- **C++ exceptions.** Whether a C++ exception that crosses the API becomes an
  error `Result`. It must be caught at the boundary either way.
- **Turn cost of I/O callbacks.** How a native I/O callback charges turn cost.
  It runs on the I/O thread, outside any task's turn.
- **Header versioning.** The header carries an ABI version number, which the VM
  checks at load.

### 40.5 Order

The owner decided this order on 2026-10-20: the package system first, then the
FFI, then the JIT, then AOT if measurements ask for it. The reason: native
libraries reach a program as packages, so the packages come before the first
native module. This replaces the order of 2026-10-15 ("the FFI before the JIT,
right after the bootstrap"). The owner answered
[45.14](45-packages.md#4514-open-questions) on 2026-10-20, so the phases after
45-0 can start.

1. The package system ([§45](45-packages.md)). Native packages come after the
   FFI (45.10).
2. UDP (issue #399), in the core: it needs the event loop, so it is not a
   native module (see the stable core rule below).
3. The FFI with the native module header (40.3a, 40.3.1), after the bootstrap
   and the post-bootstrap list of
   [`docs/roadmap/README.md`](../roadmap/README.md). Its first native module is
   chosen when a concrete library asks for it, such as SQLite or a compression
   library.
4. The JIT (40.3b, roadmap row 9.1). Then measure.
5. AOT last, and only if measurements ask for it (40.3c).

The core stays small and stable (owner decision, 2026-10-20). It holds the
language, the VM, the scheduler and the OS primitives that need the event loop:
files, processes, timers, TCP, TLS and UDP. Extensions are packages written in
Agentica first; a native module is for a library that only exists in C, C++ or
Rust. So the C API keeps two rules: a call that may take long runs off the
scheduler (the compute and I/O kinds of 40.3.1), and native code sees copied
values and handles, never the GC's objects. After UDP and the FFI land, the
core changes only for bugs, platforms and speed.

The roadmap rule "std first, C later"
([roadmap](../roadmap/README.md#new-library-features-std-first))
still holds for moving Agentica code into C: a feature starts in Agentica, and
moves to C only when a measurement shows it is hot. A native module does not
move Agentica code. It wraps a library that already exists in C, C++ or Rust,
so its need is a concrete library, not a measurement.
