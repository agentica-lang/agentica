## 40. Native code and FFI

**Status:** idea, not in the roadmap order. The owner raised it on 2026-10-14: "something like Cython, but for Agentica", and "FFI will be needed to use interesting things already done in C/C++/Rust". Nothing here is decided, and it does not change the roadmap. The order in 40.5 is for the owner to review.

### 40.1 Goal

Run hot Agentica code faster. Also call existing native libraries, written in C, C++ or Rust, through the C ABI. Three things stay as they are: values are immutable, the garbage collector manages memory, and libuv does the I/O. When native code needs to wait in a way libuv cannot serve, it gets an explicit exit (40.3b).

### 40.2 Why not a Cython-style dialect

Cython's main gain is adding static types to Python. Agentica already has static types, so that gain is already here.

A separate "fast dialect" would be a second way to write the same function. That breaks the one-way rule of [section 25](25-ruby-typed-idioms.md#25-ruby-typed-idioms): one way to do each thing. So the same code should get faster instead. The JIT does that (40.3a). The FFI adds calls into native libraries, not a second language.

### 40.3 Three parts, in this order

**a. The JIT** ([section 22](22-jit.md), roadmap 9.1, already required). Hot functions become native code and give the same results. There is no language change.

**b. FFI and native modules.** A native module declares its functions with a typed signature. This is a sketch, not the final syntax:

```text
extern def crc32(data: String) -> Int
```

The native code is written against a small, stable C API of the VM. C++ and Rust use `extern "C"`. The rules are:

- Native code gets immutable values. It returns new values through the API. It may change only its own buffers.
- It never stores GC pointers in `malloc` memory. This is the VM's existing rule ([`16-architecture.md`](../vm/16-architecture.md) §16.5).
- Conversions come first for `Int`, `Float`, `Bool`, `String`, `List`, `Map` and structs. `Bytes` can follow when the compact type of [section 23](23-binary-data.md) lands.

A native function marked blocking runs on the libuv pool, as file work does. Only its task waits, and the scheduler keeps running. The pool takes only bounded work ([`14-core-invariants.md`](../vm/14-core-invariants.md) §14.1), so a call that may wait for a long time cannot go there. Long-lived native work needs its own thread with a cancel exit. Calls that need their own event loop or threads are out of scope at first.

**c. AOT, maybe later.** `agentica build --native` compiles a whole program to native code. It reuses the opcode helpers of the VM layers ([section 21](21-vm-layers.md)), which the JIT also uses. Build it only if measurements ask for it.

### 40.4 Open questions and risks

- **Trust.** Today an `.agcb` cannot break memory. The VM's trust model ([`docs/vm/README.md`](../vm/README.md) §1) says so. A native library can break memory. So native code needs an explicit flag, such as `--allow-native`, as `--allow-run` does for processes ([`10-io-processes.md`](../vm/10-io-processes.md)).
- **Distribution.** Shared libraries conflict with the one-binary goal of [section 35](35-self-hosting.md). Either link native modules statically into the binary at build time, or load `.so` files only when the flag is set.
- **Multicore.** If more schedulers come ([`16-architecture.md`](../vm/16-architecture.md)), the C API must follow its rules. The C API is also a new part of the core, so it must pass the entry rule of [`14-core-invariants.md`](../vm/14-core-invariants.md) §14.6.
- **Step limits and turn costs.** A native call is charged like a long builtin ([`10-io-scheduler.md`](../vm/10-io-scheduler.md) §10.2.1). It cannot be stopped in the middle, so `--max-steps` cannot end a call that is still running.
- **Errors and crashes.** A native error becomes an error `Result`, never a crash. A native crash, such as a segfault, still kills the VM, and the VM cannot catch it.
- **Platform.** Linux only for now, the same first target as the JIT.
- **Which libraries.** Each native module needs a real library that asks for it. Examples: compression, image or numeric libraries, SQLite, or a Rust crate.

### 40.5 Order

1. The JIT first (40.3a). Then measure.
2. FFI when a concrete library is needed, or when the numbers ask for it (40.3b).
3. AOT last, and only if measurements ask for it (40.3c).

This follows the roadmap rule "std first, C later" ([`docs/roadmap/README.md`](../roadmap/README.md#new-library-features-std-first)): a feature starts in Agentica, and moves to C only when a measurement shows it is hot. Native modules are C, so they wait for the same kind of need.
