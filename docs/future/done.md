# Future: landed and decided

These sections were proposals and have landed or been decided. The rules that programs follow are in [`grammar.md`](../grammar.md); each section below says where. The text is kept as it was, because some of it (the reasons in §14, for example) is not in `grammar.md`.

## 2. Landed: enums and pattern matching

Generic enums and exhaustive Elixir-style `case` matching are implemented. Their normative syntax and semantics are now in sections 4–6 of [`grammar.md`](../grammar.md), with the same self-contained rules in the programming reference. Further extensions remain proposals.

## 9. Files and paths (implemented)

The filesystem phase is implemented; its normative signatures and behavior now
live in [`grammar.md`](../grammar/06d-io-and-network.md#files-and-paths). It adds `File`, `Dir` and
`Path`, an opaque evaluation-owned `FileHandle`, and the `FileInfo` record.
Host filesystem permissions apply without a separate capability flag. Reads
and writes are limited to regular files and symlinks to regular files. Whole
text helpers and each stream operation cap data at 1 MiB and use strict UTF-8.
Timed stream operations serialize per handle and close the handle only when
active I/O times out. `Dir.mkdir` is recursive and idempotent; path resolution
is lexical and does not resolve symlinks.

## 10. Void and processes (implemented)

Strict `Void` and the `Process` module are core. Their normative signatures,
completion/type restrictions, stream limits, deadlines, and cleanup rules live
in `grammar.md`. `Nil` remains data; successful fallible completion uses
`Result[Void]` and `ok()`. Native FFI can map a foreign void return to the same
completion concept when its ABI and ownership design lands.

Process spawning requires `--allow-run`, off by default. Operations use literal
arguments, inherited environment/working directory, and per-call 1 MiB stream
limits. Direct children are killed and reaped when evaluation ends. Process
polling and arbitrary descendant-tree supervision remain future designs.

## 14. Decided: no shadowing

**Rule:** a name visible in an outer scope cannot be declared again in an inner scope, and block parameters cannot reuse a visible name (`CHECK-SHADOWED-NAME`). This stays.

**Why:**

- `x = ...` without an annotation updates the visible variable or creates a new one. With shadowing, the same line would have two meanings depending on the scope.
- Blocks capture by value, and assigning to an outer variable inside a block is `CHECK-CAPTURED-ASSIGNMENT`. A block parameter that hides an outer variable would make it unclear which `x` the block captured.
- One name means one variable in a scope. This helps agents write correct code on the first try and keeps diagnostics clear.
- The evaluation logs ([`eval.md`](../eval.md)) show no `CHECK-SHADOWED-NAME` errors. The skill already tells agents that shadowing is not allowed, so this shows only that agents follow the rule without trouble, not that nobody wants shadowing.

**Also rejected:** binding the same name again with a new type in the same scope, like Rust's `let n = n.parse()`. Today a plain `n = <other type>` is `CHECK-TYPE-MISMATCH`, and an annotated `n: T = ...` on an existing name is `CHECK-ANNOTATION-ON-EXISTING`. Use two names instead:

```agentica
text = "42"
count = String.to_int!(text)
puts((count + 1).to_s)
```

