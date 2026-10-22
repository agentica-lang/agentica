---
name: agentica-programming
description: >-
  Write, check, run and repair Agentica programs (`.agc` files): a Ruby-like
  language with static types and immutable values. Use for Agentica application
  code. Not for interpreter, VM or test-suite changes (use
  agentica-development).
---

# Agentica programming

Ruby syntax, static types, immutable values. A form that is in no reference
does not exist; `agentica help NAME` prints a builtin's signature.

## Run and check

`agentica F.agc ARGS` checks, then runs (`def main() -> Void`); `agentica check
F.agc` only checks (use the path you are given if `agentica` is not on PATH).
Exit 0 is done. Exit 1 prints the first diagnostic (stable code, span, a `help`
line): fix it and rerun. Exit 2 is bad usage. A check does not test behavior:
run all cases in one command, `for f in cases/*.txt; do agentica p.agc < "$f" ||
break; done`.

## Rules agents break

- Ruby only: no `;`, braces, `let`, `match`, `continue` (use `next`), `where`;
  guards are `pattern if cond ->`; strings are double-quoted.
- Values never change: `xs = xs.push(4)`; a block cannot assign an outer
  variable (use `for` or `reduce`).
- No implicit Int/Float (`n.to_f`); `<` only on numbers; `==` only on Int,
  Float, Bool, String, Nil (`CHECK-TYPE-MISMATCH`).
- `try` only in a function that returns `Result[T]`, never in `main`;
  `"x".to_i` is a Result.
- A method not in `references/builtins.md` does not exist (`contains?` on a
  List, `value!`, `len`): `CHECK-UNKNOWN-METHOD`.

## References

Read only what the task needs.

| File in `references/` | Covers |
|---|---|
| `language.md` | checker rules, core syntax, `--ai`, `--json`, `--deny-*` |
| `builtins.md` | IO, String, List, Map, Set, Range, Result; Ruby names |
| `examples.md` | complete programs to start from |
| `diagnostics.md` | meaning and fix of a diagnostic code |
| `modules.md` | several files, `std/`, `pkg/`, packages |
| `json.md` | parse, encode, decode into structs |
| `files.md` | File, Dir, Path, locks |
| `processes.md` | Process, `IO.read_bytes`, flush, `System.env/os/pid` |
| `network.md` | TCP, TLS, HTTP client and server |
| `tasks.md` | Task, Channel, timeouts, cancel |
| `lazy.md` | Lazy pipelines, endless sources, big files |
| `testing.md` | unit tests (`Test`, `*_test.agc`) |
| `bdd.md` | `.feature` specs and step programs |
| `performance.md` | slow code, `Profile`, step costs |
| `binary.md` | bytes, bit operations, `Crypto` |
| `logger.md` | `std/logger` |
| `toml.md` | `std/toml` |
| `native.md` | C functions (`extern`, `compute def`) |
| `queries.md` | `outline`, `type-at`, `refs`, `symbol` |
| `analysis.md` | compiler answers in a program (`std/analysis`) |

Style: `agentica-code-guidelines`. Docs:
`https://sonic182.github.io/agentica/llms.txt`.
