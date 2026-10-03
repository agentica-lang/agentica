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
- [`examples/json-config.agc`](examples/json-config.agc): extract and validate a nested service config, then encode a typed struct.
- [`examples/json-expenses.agc`](examples/json-expenses.agc): aggregate a JSON array into a map of category totals; amounts are integer cents, with negative amounts for refunds.
- [`examples/json-lines.agc`](examples/json-lines.agc): transform one JSON record per line, recover from invalid records, and flush each response.
- [`examples/knight-tour.agc`](examples/knight-tour.agc): find an open knight tour with degree-ordered backtracking, visiting every square once.
- [`examples/traveling-salesman.agc`](examples/traveling-salesman.agc): find an optimal circuit through a small directed distance matrix.
- [`examples/maze-bfs.agc`](examples/maze-bfs.agc): find a shortest maze path with BFS, using maps for distances, predecessors, and a queue.

The three input-driven JSON examples read stdin:

```sh
printf '%s\n' '{"service":{"name":"api","port":8080,"enabled":false}}' | dist/agentica examples/json-config.agc
printf '%s\n' '[{"category":"food","amount":1200},{"category":"food","amount":-200}]' | dist/agentica examples/json-expenses.agc
printf '%s\n' '{"name":"Ana","score":75,"active":true}' 'not json' | dist/agentica examples/json-lines.agc
```

They print compact JSON on stdout. Configs require a nonempty name and port 1–65535; scores must be 0–100, and an active score of at least 60 passes. Extraction failures produce an error object, and the JSON-lines example continues with the next record.

The algorithm examples also read JSON from stdin:

```sh
printf '%s\n' '{"size":8,"start":0}' | dist/agentica --max-steps 5000000 examples/knight-tour.agc
printf '%s\n' '{"distances":[[0,10,15,20],[10,0,35,25],[15,35,0,30],[20,25,30,0]]}' | dist/agentica --max-steps 5000000 examples/traveling-salesman.agc
printf '%s\n' '{"grid":[".#.","..."],"start":0,"goal":2}' | dist/agentica --max-steps 5000000 examples/maze-bfs.agc
```

Knight tours accept square boards of size 1–8 and a zero-based starting square (`row * size + column`). Output is `{"found":true,"path":[...]}` or `{"found":false,"path":[]}` after exhausting the search. Tours are open. The traveling salesman accepts a complete directed square matrix of 1–8 cities, with zero diagonal and integer costs from 0 to 1,000,000,000. It returns an optimal `{"cost":...,"route":[0,...,0]}` circuit; one city yields `[0,0]` and cost zero. Both validate input and print `{"error":"invalid input"}` on invalid documents. Searches can be expensive: a runtime step-limit diagnostic does not mean there is no solution.

IO.gets now returns Result[String]; IO.gets! is the String-returning form that halts at EOF. String.to_int/to_float return Results; the existing bang forms retain their behavior. `try` is only valid inside a Result-returning function; main still returns Nil. Options precede the command/file, except the documented trailing --json on help. Arguments after a source file are program arguments.

The maze accepts rectangular grids with 1–32 rows and columns. `.` is open and `#` is blocked; only horizontal and vertical steps are allowed. Start and goal use `row * width + column` and must be open, in-range cells. The example above returns `{"found":true,"distance":4,"path":[0,3,4,5,2]}`. An unreachable goal returns `{"found":false,"distance":-1,"path":[]}`; invalid input returns `{"error":"invalid input"}`. Start equal to goal returns distance zero and a one-cell path. The queue uses numeric keys and deletes consumed entries; `Map.delete` maintains insertion order in O(n), so this example demonstrates the API rather than a queue with constant-time operations.

Enums and pattern matching are future extensions.
