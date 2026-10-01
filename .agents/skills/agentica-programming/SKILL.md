---
name: agentica-programming
description: Write, run, and repair programs in the Agentica language (`.agc` files) using the `agentica` binary and its diagnostics. Use when asked to write or fix an Agentica program. Do not use for changing the interpreter itself (lexer, parser, checker, evaluator, tests); that is the agentica-development skill.
---

# Programming in Agentica

Agentica is a small statically typed language with Ruby-like syntax. The language is defined in `docs/grammar.md`; read the sections you need before writing code, and do not guess syntax. Valid programs to copy from are in `examples/`: `hello.agc`, `classify.agc` (functions and control flow), `tasks.agc` (structs, lists), `inventory.agc` (maps), `strings.agc` (String library), `echo.agc` (input).

## Run and check

Use the `agentica` binary, not `racket`:

```sh
agentica program.agc            # check, then run main()
agentica --dump program.agc     # check only; prints the checked tree, runs nothing
agentica program.agc a b        # extra arguments reach System.args()
```

If `agentica` is not on the `PATH`, use the path the user gave you, or `dist/agentica` in the repository (`make exe` builds it).

Exit codes: `0` ok, `1` the program has a diagnostic (the stage that failed stopped at its first error), `2` bad usage or unreadable file.

## Read a diagnostic

Diagnostics go to stderr:

```text
bad.agc:2:14 error[CHECK-TYPE-MISMATCH]
expected Int, found String

2 |   age: Int = "25"
  |              ^^^^
```

The header gives the file, line, column, and a stable code. The code prefix names the stage: `LEX-`, `PARSE-`, `CHECK-` (before running), `RUNTIME-` (while running). The caret marks the offending source. Only the first error is reported, so fixing it can reveal the next one.

## Work loop

1. Read the relevant grammar sections and the closest example.
2. Write the program to a `.agc` file. Every program needs one `main() -> Nil`.
3. Run `agentica` on it. If it exits `1`, fix the code at the reported position and run again.
4. Stop when it exits `0` and the output is what the task asked for. A program that only passes the checker is not done: run it and compare the output.
