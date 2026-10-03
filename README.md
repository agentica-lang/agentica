# Agentica

Interpreter for the Agentica language, written in Racket. The language is
defined in [`docs/grammar.md`](docs/grammar.md), planned syntax is in
[`docs/future.md`](docs/future.md), and the phased plan is in
[`docs/roadmap.md`](docs/roadmap.md).

## Requirements

Racket CS 9.3 or newer. No other dependencies.

## Build

The interpreter is a pipeline of modules in `src/`:

```text
source text -> lexer.rkt -> parser.rkt -> checker.rkt -> evaluator.rkt
               tokens       AST           checked AST    runs main()
```

`main.rkt` is the command-line driver. There is nothing to install; compile
the modules to bytecode once:

```sh
raco make src/main.rkt
```

This writes `src/compiled/`. Without it Racket recompiles every module on each
run, and a hello world takes about 1.5 s instead of about 0.4 s. Run
`raco make` again after you change the code.

A `Makefile` wraps the common commands:

| Command      | Does                                                        |
| ------------ | ----------------------------------------------------------- |
| `make build` | `raco make src/main.rkt`                                    |
| `make test`  | `raco test tests/`                                          |
| `make exe`   | build, then `raco exe -o dist/agentica src/main.rkt`        |
| `make clean` | remove every `compiled/` directory and `dist/`              |

The `exe` target gives a single executable (`dist/agentica examples/hello.agc`).
It needs the Racket installation on the machine; use `raco distribute` to
bundle the runtime. `compiled/` and `dist/` are in `.gitignore`.

## Usage

```sh
racket src/main.rkt [--dump] [--ai|--json] [--max-steps N] [check] <file.agc>
racket src/main.rkt help String.to_int --json
```

Run a program. `main()` is the entry point, and `puts` prints to stdout:

```sh
racket src/main.rkt examples/hello.agc
# hello
```

| Option   | Effect                                                |
| -------- | ----------------------------------------------------- |
| `--dump` | Print the checked syntax tree instead of running it.  |
| `check`  | Subcommand, only as the first argument: check the file, print `check ok`, run nothing. It ignores `--dump` and program arguments; a program file named `check` runs as `./check`. |
| `--ai`   | Print a diagnostic as compact text for an agent (stderr).  |
| `--json` | Print a diagnostic as one JSON object (stderr).            |
| `help NAME --json` | Describe a builtin from the shared catalog, without a program file. Unknown targets exit 2. |
| `--max-steps N` | Limit expression/statement entries, including loop conditions; exhaustion is RUNTIME-STEP-LIMIT. Positive N only. Unlimited by default; check never runs. Not a blocking-I/O timeout. |

### Exit codes

| Code | Meaning                                                          |
| ---- | ---------------------------------------------------------------- |
| 0    | The program ran.                                                 |
| 1    | A lexer, parser, checker, or runtime diagnostic (first error).   |
| 2    | Bad usage, or the file cannot be read.                           |

### Diagnostics

The interpreter stops at the first error and prints it to stderr with the
file, line, column, a stable code, an explanation, and the offending source:

```text
bad.agc:2:14 error[CHECK-TYPE-MISMATCH]
expected Int, found String

2 |   age: Int = "25"
  |              ^^^^
```

Codes are prefixed by stage: `LEX-`, `PARSE-`, `CHECK-`, `RUNTIME-`.

## Examples

- [`examples/hello.agc`](examples/hello.agc): a minimal program.
- [`examples/classify.agc`](examples/classify.agc): functions, control flow, and `try` propagation.
- [`examples/tasks.agc`](examples/tasks.agc): structs, lists, and field access.
- [`examples/inventory.agc`](examples/inventory.agc): maps and the `Map` module.

- [`examples/result.agc`](examples/result.agc): Result values, propagation, messages, and fallbacks.
- [`examples/json.agc`](examples/json.agc): JSON encoding, parsing, extraction, and `try`.

IO.gets now returns Result[String]; IO.gets! is the String-returning form that halts at EOF. String.to_int/to_float return Results; the existing bang forms retain their behavior. `try` is only valid inside a Result-returning function; main still returns Nil. Options precede the command/file, except the documented trailing --json on help. Arguments after a source file are program arguments.

Enums and pattern matching are future extensions.
