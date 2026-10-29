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
Exit 0 and the output the request asks for mean done. Exit 1 prints the first
diagnostic (stable code, span, a `help` line): fix it and rerun. Exit 2 is bad
usage. A check does not test behavior: run all cases in one command, `for f in
cases/*.txt; do agentica p.agc < "$f" || break; done`.

## Rules agents break

- Ruby only: no braces, `let`, `match`, `where` (`PARSE-UNEXPECTED-TOKEN`), `;`
  (`LEX-UNEXPECTED-CHAR`) or `continue` (use `next`); guards are `pattern if
  cond ->`; strings are double-quoted.
- Values never change: `xs = xs.push(4)`; a block cannot assign an outer
  variable (`reduce` for a total; a `for` loop, which can, to update several).
- No implicit Int/Float (`n.to_f`); `<` only on numbers (strings: `a.compare(b)
  < 0`); `==` only on Int, Float, Bool, String, Nil, Bytes, Range
  (`CHECK-TYPE-MISMATCH`).
- `try` only in a function that returns `Result[T]`, never in `main`;
  `"x".to_i` is a Result: `try s.to_i`, not `try s.to_i!`.
- A method not in `references/` does not exist (`contains?` on a List, `value!`,
  `len`): `CHECK-UNKNOWN-METHOD`.

## References

Read only what the task needs.

| File in `references/` | Covers |
|---|---|
| `language-running.md` | `agentica` flags, `compile` and `run` of bytecode, the cache, `--sandbox` |
| `language-program-types.md` | file shape, constants, `def`, `struct`, `enum`, types, `Void`, defaults |
| `language-statements-expressions.md` | `case`, loops, assignment, literals, heredocs, operators, pipes, foreign forms |
| `language-blocks-results.md` | blocks and closures, `Fn` values, `Result`, `try` |
| `builtins.md` | IO, Int/Float, String, List, Map, Set, Range, Result, System, Time, Random, `to_s`; Ruby names |
| `examples.md` | complete programs to start from |
| `diagnostics.md` | meaning and fix of a diagnostic code, call stacks |
| `modules.md` | several files, `std/`, `pkg/`, packages |
| `json.md` | parse, encode, decode into structs |
| `files.md` | File, Dir, Path, locks |
| `bytes.md` | `Bytes`: the byte string type, `s.bytes`, slicing, joining, keys |
| `compression.md` | Zlib bytes and Lazy byte streams (deflate, zlib, gzip) |
| `archive.md` | `std/archive` (explicit-allowlist TAR extraction into a new directory) |
| `processes.md` | Process, `IO.read_bytes`, flush, `System.env/os/pid` |
| `network.md` | TCP, TLS, HTTP client and server |
| `tasks.md` | Task, `Task.map`, Channel, ATS tables, timeouts, cancel, who owns state |
| `lazy.md` | Lazy pipelines, endless sources, big files |
| `testing.md` | unit tests (`Test`, `*_test.agc`) |
| `bdd.md` | `.feature` specs and step programs |
| `performance.md` | slow code, `Profile`, step costs |
| `binary.md` | bytes, bit operations, `Digest` hashes, `HMAC`, `Base64`, hex, `SecureRandom`, `std/binary` (`read_u16_be`, `frame`) |
| `logger.md` | `std/logger` |
| `toml.md` | `std/toml` |
| `uri.md` | `std/uri` (percent-encoding, query strings) |
| `html.md` | `std/html` (HTML escaping) |
| `cookie.md` | `std/cookie` (`Cookie` and `Set-Cookie` headers) |
| `mime.md` | `std/mime` (media type of a file) |
| `native.md` | C functions (`extern`, `compute def`, `C.Pointer`, memory reads, resources) |
| `queries.md` | `outline`, `type-at`, `refs`, `symbol` |
| `analysis.md` | compiler answers in a program (`std/analysis`) |

Style: `agentica-code-guidelines`. Docs:
`https://agentica-lang.github.io/agentica/llms.txt`.
