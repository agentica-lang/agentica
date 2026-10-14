## 6. Native runtime

The native runtime is now planned as a bytecode VM written in C11 with the Boehm
GC (roadmap Phase 7), instead of the earlier procedural C++20 idea. libevent
remains an option for the task and I/O event loop; Phase 7b decides. These
choices are not part of the grammar and must not appear in Agentica programs.

Integrating the native host with a C library does not by itself solve the FFI of
Agentica: an interpreter needs native wrappers or a call layer that respects the
ABI. Including libevent does not automatically provide fibers or actors either.

For now we do not introduce interfaces, traits, inheritance, JIT, distribution,
or parallelism. The semantics of the language must be preserved when the AST
evaluator is replaced by a future VM.

