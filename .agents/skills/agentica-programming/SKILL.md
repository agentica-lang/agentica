---
name: agentica-programming
description: Write, check, run, and repair Agentica programs (`.agc` files). Use for Agentica application code; use agentica-development for interpreter, tests, or language implementation changes.
---

# Agentica programming

## Before coding

Read [references/language.md](references/language.md). It is the self-contained language reference; do not guess syntax or APIs that are not documented there.

## Write and verify

1. Save the requested program as a `.agc` file. It needs one `main() -> Void`.
2. Check and run it with `agentica program.agc`. Use `agentica check program.agc` for check-only, or `agentica --dump program.agc` to inspect the checked tree.
3. Fix diagnostics and rerun. Exit `1` means a program diagnostic; exit `2` means bad usage or an unreadable file. Diagnostics go to stderr and report the first error with a stable stage code (`LEX-`, `PARSE-`, `CHECK-`, `RUNTIME-`).
4. Finish only when the program exits successfully and its output matches the request. Checking alone does not verify runtime behavior.

Use `agentica help NAME --json` to inspect a builtin. If `agentica` is not on `PATH`, use the path supplied by the user. Pass program arguments after the file; `System.args()` reads them. Process spawning requires `--allow-run`; execution can be bounded with `--max-steps N`, and `--seed N` makes `Random` repeatable.

For fixed JSON records, prefer structs with typed fields. Use `Json`/`JSON.object` for genuinely dynamic data; maps and lists are homogeneous. For stdio protocols, write one message per line, flush stdout with `IO.flush()`, and send logs to stderr with `IO.warn()`.
