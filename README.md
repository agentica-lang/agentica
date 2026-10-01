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
racket src/main.rkt [--dump] [check] <file.agc>
```

Run a program. `main()` is the entry point, and `puts` prints to stdout:

```sh
racket src/main.rkt examples/hello.agc
# hello
```

| Option   | Effect                                                |
| -------- | ----------------------------------------------------- |
| `--dump` | Print the checked syntax tree instead of running it.  |
| `check`  | Subcommand: check the file, print `check ok`, run nothing. |

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
- [`examples/classify.agc`](examples/classify.agc): functions and control flow.
- [`examples/tasks.agc`](examples/tasks.agc): structs, lists, and field access.
- [`examples/inventory.agc`](examples/inventory.agc): maps and the `Map` module.

Enums and pattern matching are future extensions.
