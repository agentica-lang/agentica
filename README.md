# Agentica

Interpreter for the Agentica language: a Racket front end and a bytecode VM
in C. Agentica is Ruby
with static types: Ruby-like syntax, checked before running, with immutable
values. The language is defined in [`docs/grammar.md`](docs/grammar.md); the
self-contained reference for agents writing Agentica is the
[`agentica-programming` skill](.agents/skills/agentica-programming/SKILL.md).
Planned syntax is in
[`docs/future/`](docs/future/README.md), and the phased plan is in
[`docs/roadmap/`](docs/roadmap/README.md).

User documentation (a guide, a language tour and the library) is published at
<https://sonic182.github.io/agentica/> (source in `site/`; build it with
`make site`, preview it with `make site-serve`).

## Requirements

Racket CS 9.3 or newer, and a C11 compiler (gcc or clang) and `make` to build
the VM from the vendored submodules. The release archive for Linux x86-64
needs neither: it bundles Racket and `agentica-vm`, and runs on glibc 2.28 or
newer.

## Build

The interpreter is a Racket front end in `src/` and a bytecode VM in C in
`vm/`:

```text
source text -> lexer.rkt -> parser.rkt -> checker.rkt -> lower.rkt -> bytecode.rkt -> agentica-vm
               tokens       AST           checked AST    VM IR        .agcb bytes     runs main()
```

`main.rkt` is the command-line driver: it compiles in-process and runs
`dist/agentica-vm`. The Racket evaluator (`evaluator.rkt`) is frozen and runs
only programs the VM cannot run yet: those that use `TCP`, `TLS`, `HTTP` or
`BDD`, which fall back to it with a one-line notice on stderr, and
`agentica test`. There is nothing to install; build the VM (it needs the git
submodules: `git submodule update --init`) and compile the modules to
bytecode once:

```sh
make vm
raco make src/main.rkt
```

This writes `src/compiled/`. Without it Racket recompiles every module on each
run, and a hello world takes about 1.5 s instead of about 0.4 s. Run
`raco make` again after you change the code.

A `Makefile` wraps the common commands:

| Command      | Does                                                        |
| ------------ | ----------------------------------------------------------- |
| `make build` | `raco make src/main.rkt`                                    |
| `make vm`    | build the VM, `dist/agentica-vm`                            |
| `make test`  | build the VM, then `raco test tests/`                       |
| `make goldens` | rewrite the expected outcomes in `tests/fixtures/vm/` from the VM |
| `make exe`   | build `src/` and the VM, then `raco exe -o dist/agentica src/main.rkt` |
| `make clean` | remove every `compiled/` directory and `dist/`              |

The `exe` target gives an executable (`dist/agentica examples/hello.agc`) that
runs `dist/agentica-vm` next to it. It needs the Racket installation on the
machine; use `raco distribute` to bundle the runtime, and copy `agentica-vm`
into its `bin/`, as the release archive does. `compiled/` and `dist/` are in `.gitignore`.

## Usage

```sh
racket src/main.rkt [--dump] [--ai|--json] [--max-steps N] [--seed N] [--allow-run] [check] <file.agc>
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
| `--seed N` | Seed `Random` with N (0..2147483647) so runs repeat; `agentica test` passes it to handlers and programs under test. Without it, each run is seeded from OS randomness. |
| `--dump-ir` | Print the lowered VM IR instead of running it (VM subset only; see `docs/vm/`). |
| `--vm` | Accepted and ignored: programs run on the bytecode VM by default (tested on Linux only; elsewhere the VM has no guard against outliving the driver: macOS skips only the parent check, while the `O_NOFOLLOW`, privacy and inode checks run on every non-Windows system, and Windows skips both checks). The driver compiles to a temporary bytecode file and runs `agentica-vm`, found next to the `agentica` executable (`bin/` of the release archive), or in `dist/` of the checkout for `racket src/main.rkt`; `AGENTICA_VM=path` picks another VM, and a missing VM exits 2. It passes `--max-steps`, `--seed` (a seeded run repeats, with other `Random` values than the old evaluator), `--allow-run`, `--ai`, `--json` and program arguments. A program that uses `TCP`, `TLS`, `HTTP` or `BDD` runs on the legacy evaluator after one notice line on stderr (`agentica: the VM does not support the builtin HTTP.get yet; running on the legacy evaluator`), and so does `agentica test`. |
| `compile FILE -o OUT` | Subcommand, only as the first argument: write VM bytecode for `dist/agentica-vm` (built by `make vm`). Programs that use `TCP`, `TLS`, `HTTP` or `BDD` fail with `LOWER-UNSUPPORTED`. |

Use `--allow-run` before the command or source file to enable `Process.spawn`; spawning is disabled by default. `main()` now returns `Void`, and side-effect APIs return `Void` or `Result[Void]`. Use `ok()` for successful completion; `nil` remains data and JSON null. `racket src/main.rkt --allow-run examples/process-tool.agc` demonstrates tool execution and exit checks.

### Libraries

The standard library ships embedded in the executable—no separate download or
`.venv` is needed. Its implementation is Agentica source, not native builtins:

```ruby
import "std/queue.agc" as Queue
```

See [examples/queue.agc](examples/queue.agc) for the immutable String FIFO.

External `pkg/` imports search `agc_libs/` beside the root program, absolute
roots in `AGENTICA_PATH` (colon-separated on Unix, semicolon-separated on
Windows), the user data directory, then Unix system data directories.
For example, `import "pkg/acme/tools.agc" as Tools` looks for `acme/tools.agc`
inside each root. The Unix user root defaults to
`~/.local/share/agentica/lib/` and respects `XDG_DATA_HOME`; system roots are
`/usr/local/share/agentica/lib/` and `/usr/share/agentica/lib/`.
Windows uses `%LOCALAPPDATA%/agentica/lib/` and no default system roots.
These roots never override `std/`; ordinary relative imports still resolve
from the importing file. See [the language reference](docs/grammar.md#standard-library-and-external-libraries)
for path validation and precedence rules.

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
- [`examples/inventory.agc`](examples/inventory.agc): maps, methods and interpolation.
- [`examples/strings.agc`](examples/strings.agc): string methods in Ruby style.
- [`examples/blocks.agc`](examples/blocks.agc): blocks and closures (`xs.map do |x| ... end`).
- [`examples/dispatch.agc`](examples/dispatch.agc): function values and `.call`.
- [`examples/echo.agc`](examples/echo.agc): read stdin line by line until EOF.
- [`examples/file-summary.agc`](examples/file-summary.agc): read a file given as an argument.
- [`examples/concurrency.agc`](examples/concurrency.agc): lightweight tasks with `Task.spawn` and `Task.await`.
- [`examples/process-tool.agc`](examples/process-tool.agc): run another program (needs `--allow-run`).
- [`examples/tcp_echo.agc`](examples/tcp_echo.agc), [`examples/http_get.agc`](examples/http_get.agc), [`examples/http_server.agc`](examples/http_server.agc): TCP and HTTP.
- [`examples/queue.agc`](examples/queue.agc): the embedded `std/queue.agc` library.
- [`examples/json-modules.agc`](examples/json-modules.agc): a program split across files (`examples/modules/json-tools.agc`).
- [`examples/mcp/stdio.agc`](examples/mcp/stdio.agc): a minimal MCP stdio server.
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

IO.gets (and top-level gets) returns Result[String]; IO.gets! (and gets!) is the String-returning form that halts at EOF. String.to_int/to_float return Results; the existing bang forms retain their behavior. `try` is only valid inside a Result-returning function; main returns Void. Options precede the command/file, except the documented trailing --json on help. Arguments after a source file are program arguments.

The maze accepts rectangular grids with 1–32 rows and columns. `.` is open and `#` is blocked; only horizontal and vertical steps are allowed. Start and goal use `row * width + column` and must be open, in-range cells. The example above returns `{"found":true,"distance":4,"path":[0,3,4,5,2]}`. An unreachable goal returns `{"found":false,"distance":-1,"path":[]}`; invalid input returns `{"error":"invalid input"}`. Start equal to goal returns distance zero and a one-cell path. The queue uses numeric keys and deletes consumed entries; `Map.delete` maintains insertion order in O(n), so this example demonstrates the API rather than a queue with constant-time operations.

## License

Agentica is licensed under the Apache License 2.0 with the LLVM exception
(SPDX: `Apache-2.0 WITH LLVM-exception`). See [`LICENSE`](LICENSE) and
[`NOTICE`](NOTICE).

- If you redistribute Agentica, as source or binaries, changed or not, keep
  `LICENSE` and `NOTICE` with it and mark files you changed (Apache-2.0
  section 4 has the full conditions).
- Programs you write in Agentica are yours; this license does not cover
  them. When compiling your program puts parts of Agentica into the compiled
  output (for example an imported `std/` module linked into your `.agcb`),
  the LLVM exception lets you ship that output without Agentica's `LICENSE`
  and `NOTICE`. Shipping Agentica itself with your program (`agentica`,
  `agentica-vm`) is redistribution: keep `LICENSE` and `NOTICE` with it. If
  you combine Agentica with GPLv2 software and a court finds a part of this
  license in conflict with GPLv2, the exception also lets you set that part
  aside for the combined software.
- Third-party components keep their own licenses, and the LLVM exception
  does not cover them; their notices apply wherever they are shipped:
  - the Boehm GC (`vm/third_party/bdwgc`): the Boehm-GC license, with its
    notice in `README.QUICK`;
  - libuv (`vm/third_party/libuv`): MIT, with BSD-2-Clause and ISC parts in
    its `LICENSE-extra`;
  - yyjson (`vm/third_party/yyjson`): MIT;
  - the Unicode character data in `vm/unicode_data.c` (generated from the
    Unicode Character Database): Unicode License v3;
  - picohttpparser: MIT (planned);
  - OpenSSL 3: Apache-2.0 (planned);
  - Racket CS (MIT or Apache-2.0) and the Chez Scheme it embeds
    (Apache-2.0), bundled in the release archives, which ship their
    license files and Chez Scheme's `NOTICE` in `licenses/racket/`.

  The release archives ship these notices in `licenses/`: `bdwgc/NOTICE`,
  `libuv/LICENSE` and `LICENSE-extra`, `yyjson/LICENSE`,
  `unicode/LICENSE.txt` (also in this repository) and `racket/`.
