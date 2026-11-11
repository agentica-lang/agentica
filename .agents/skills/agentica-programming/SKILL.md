---
name: agentica-programming
description: >-
  Write, check, run and repair Agentica programs (`.agc` files), a Ruby-like
  language with static types and immutable values: language rules,
  builtins and `std/` modules (HTTP, JSON, tasks, regex, option_parser),
  `agentica.toml` packages, `agentica test` and BDD specs, and the `CHECK-`,
  `PARSE-`, `RUNTIME-` and `PKG-` diagnostics. Use whenever a task writes,
  edits, runs or debugs Agentica application code or fixes one of its
  diagnostics. Not for the interpreter, compiler, VM or its test suite (use
  agentica-development) or for style (use agentica-code-guidelines).
---

# Agentica programming

Ruby syntax, static types, immutable values. A form that is in no reference
does not exist; `agentica help NAME` prints a builtin's signature.

## Run and check

`agentica F.agc ARGS` checks, then runs (`def main() -> Void`); `agentica check
[PATH...]` only checks a file or a folder (use the path you are given if
`agentica` is not on PATH). Exit 0 and the output the request asks for mean
done. Exit 1 prints the first diagnostic (stable code, span, a `help` line): fix
it and rerun. Exit 2 is bad usage. A check does not test behavior: run all cases
in one command, `for f in cases/*.txt; do agentica p.agc < "$f" || break; done`.

## Rules agents break

- Ruby only: no braces, `let`, `match`, `where` (`PARSE-UNEXPECTED-TOKEN`), `;`
  (`LEX-UNEXPECTED-CHAR`) or `continue` (use `next`); guards are `pattern if
  cond ->`; strings are double-quoted.
- Values never change: `xs = xs.push(4)`; a block cannot assign an outer
  variable (`reduce` for a total; a `for` loop, which can, to update several).
- No implicit Int/Float (`n.to_f`); `<` only on numbers (strings: `a.compare(b)
  < 0`); `==` on two values of one type: primitives, Bytes, ranges, and lists,
  maps, sets, Optionals, Results, structs and enums of those; never on Fn,
  Task, Channel, handles, Json or a generic `T` (`CHECK-TYPE-MISMATCH`).
- `try` only in a function that returns `Result[T]`, never in `main`;
  `"x".to_i` is a Result: `try s.to_i`, not `try s.to_i!`.
- A value that may be missing is `Optional[T]` (`some(x)`, `none`), not `nil`
  and not an enum of your own; a failure with a reason is a `Result`.
- An unused import alias or variable (`CHECK-UNUSED-IMPORT`,
  `CHECK-UNUSED-VARIABLE`, which also covers `|ctx, args|` in BDD steps and
  `for i in`) and a statement after `return`, `break` or `next`
  (`CHECK-UNREACHABLE-CODE`) are errors: delete them, or write `_` or `_name`.
  A dropped `Result` from any call (`File.close(f, 1000)`, `ch.send(x, 0)`) is
  `CHECK-UNUSED-RESULT`: `try` it, `case` it or write `_ = f(...)`. A missing
  `end` is `PARSE-UNCLOSED-BLOCK` at the end of the file, or
  `PARSE-UNEXPECTED-TOKEN` at the next `def`: count the `end`s.
- A method not in `references/` does not exist (`contains?` on a List, `value!`,
  `len`): `CHECK-UNKNOWN-METHOD`.

## References

Read only what the task needs.

| File in `references/` | Covers |
|---|---|
| `language-running.md` | `agentica` flags, `compile` and `run` of bytecode, the cache, `--sandbox` |
| `language-program-types.md` | file shape, constants, `def`, `struct`, `enum`, types, `Void`, defaults |
| `language-statements-expressions.md` | `case`, loops, assignment, literals, heredocs, operators, pipes, foreign forms |
| `language-blocks-results.md` | blocks and closures, `Fn` values, `Result`, `try`, `Optional`, design patterns |
| `builtins.md` | IO, Int/Float, String, List, Map, Set, Range, Result, Optional, System, Time, Random, `to_s`; Ruby names |
| `examples.md` | complete programs to start from |
| `diagnostics.md` | meaning and fix of a diagnostic code, call stacks |
| `modules.md` | several files, `module` blocks, `std/`, `pkg/`, packages |
| `json.md` | parse, encode, decode into structs |
| `files.md` | File, Dir, Path, locks |
| `bytes.md` | `Bytes`: the byte string type, `s.bytes`, slicing, joining, keys |
| `compression.md` | Zlib bytes and Lazy byte streams (deflate, zlib, gzip) |
| `archive.md` | `std/archive` (explicit-allowlist TAR extraction into a new directory) |
| `processes.md` | Process, `IO.read_bytes`, flush, `System.env/os/pid` |
| `network.md` | TCP, TLS, `std/socks` (SOCKS5), HTTP client and server |
| `tasks.md` | Task, `Task.map`, Channel, ATS tables, timeouts, cancel, monitors, who owns state, `std/actor`, `std/supervisor` |
| `lazy.md` | Lazy pipelines, endless sources, big files |
| `testing.md` | unit tests (`Test`, `*_test.agc`) |
| `bdd.md` | `.feature` specs and step programs |
| `performance.md` | slow code, `Profile`, step costs |
| `binary.md` | bit operations, the `OpenSSL` family (`Digest` hashes, `HMAC`, `Cipher` for AES-GCM and Triple DES, `CMAC`, password hashing with `KDF`, `RSA`, secure `Random`), `Base64`, hex, `std/binary` |
| `logger.md` | `std/logger` |
| `toml.md` | `std/toml` |
| `uri.md` | `std/uri` (percent-encoding, query strings) |
| `html.md` | `std/html` (HTML escaping) |
| `cookie.md` | `std/cookie` (`Cookie` and `Set-Cookie` headers) |
| `option_parser.md` | `std/option_parser` (command-line options and arguments, typed getters, help) |
| `cache.md` | `std/cache` (a bounded cache of strings that tasks share) |
| `mime.md` | `std/mime` (media type of a file) |
| `utc.md` | `std/utc` (Unix ms to UTC date and RFC 3339 text) |
| `regex.md` | `std/regex` (regular expressions: match, find, replace, split) |
| `eag.md` | `<<~EAG` templates (Agentica's ERB) and `std/eag` |
| `native.md` | C functions (`extern`, `compute def`, `C.Pointer`, memory reads, resources) |
| `native-modules.md` | C code written for Agentica (`extern module`, the types that cross) |
| `queries.md` | `outline`, `type-at`, `refs`, `symbol` |
| `analysis.md` | compiler answers in a program (`std/analysis`) |

Style: `agentica-code-guidelines`. Docs:
`https://agentica-lang.github.io/agentica/llms.txt`.
