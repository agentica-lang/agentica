## 21. VM layers

**Status:** planned (roadmap 7l), after the tasks PR, next to the review of what the VM inherited from Racket (7k). A prerequisite for the JIT (section 22). No behavior change.

- Split `vm/agc.h` into layer headers. Done as row 7.2.1b of the roadmap, in [`docs/vm/15-layers.md`](../vm/15-layers.md) (§15): core, services and adapters, with `value.h`, `port.h`, `core.h` and `services.h` and a CI check. It replaced the core/rt/lib split first planned here.
- Move each opcode's semantics out of the `vm/interp.c` switch into helpers (`agc_op_concat`, `agc_op_eq`, ...) that both the interpreter and a JIT call.
- Add metadata flags to the builtin table: `pure`, `may_fail`, `allocates`, `may_yield`.
- Give the callback builtins (`map`, `filter`, `reduce`, `each`, `any?`, `all?`, `sort_by`, `Range.each`, `times`, `upto`, `downto`), today special `AGC_NATIVE_*` state machines inside `vm/interp.c`, a protocol that compiled code can use too.

