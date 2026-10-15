## Pending work: General programming and MCP (after the VM)

### Completed: Strict Void prerequisite

- [x] Separate no-value completion from Nil data; require main() -> Void and
  explicit returns from Nil functions.
- [x] Reject Void in data type/value positions; support completion in Fn return
  types, Result[Void], and Task[Void].
- [x] Add ok() for successful Result[Void] completion; preserve ok(nil), JSON
  null, and Nil task results.
- [x] Migrate side-effect APIs, HTTP/BDD callbacks, shipped programs,
  benchmarks, and evaluation prompts/fixtures; update both language references
  and development notes.

### Completed: Files and paths

Make local data processing possible before adding more protocol-specific APIs.

- [x] Specify file and path APIs, error behavior and byte limits in
  `docs/future/`; use host filesystem permissions without a new capability flag.
- [x] Read and write text and bytes, including explicit overwrite/append
  behavior and strict UTF-8 decoding.
- [x] List directories, create directories, inspect file metadata, and
  join/resolve paths.
- [x] Cover failures and resource cleanup with temporary-directory integration
  tests; add a small file-processing example.

### Completed: Processes (phase 5l)

Run existing tools for automation, then reuse the same API for stdio MCP
clients.

```text
Process.spawn(command: String, args: List[String], timeout_ms: Int) -> Result[Process]
Process.send(p: Process, text: String, timeout_ms: Int) -> Result[Void]
Process.send_bytes(p: Process, bytes: List[Int], timeout_ms: Int) -> Result[Void]
Process.read_line(p: Process, timeout_ms: Int) -> Result[String]
Process.read_bytes(p: Process, count: Int, timeout_ms: Int) -> Result[List[Int]]
Process.close_stdin(p: Process, timeout_ms: Int) -> Result[Void]
Process.wait(p: Process, timeout_ms: Int) -> Result[Int]
Process.close(p: Process) -> Void
```

- Opaque evaluation-owned Process handles; literal argv, inherited environment
  and working directory.
- Positive full-operation deadlines and independent read/write locks. Active
  stream timeouts abort; lock and wait timeouts preserve children.
- Per-call 1 MiB limits, strict UTF-8 lines, counted bytes with short/empty EOF,
  and fixed-buffer stderr forwarding. Output has no lifetime cap; use Task for
  concurrent consumption.
- Direct children are killed and reaped on close, main return, System.exit,
  diagnostics, task failure, budget exhaustion, and external interruption.
  Arbitrary descendant trees remain outside the guarantee.
- --allow-run defaults off and propagates to tasks, HTTP callbacks, BDD handlers
  and programs under test. Check and help need no flag.

- [x] Specify exit-code retrieval, stdin closure, output limits, and
  deadline/cleanup behavior alongside spawn/send/read/close.
- [x] Add the Process type and module over racket/subprocess, without shell
  interpolation of command arguments.
- [x] Test independent local Node children, including nonzero exits, full-duplex
  I/O, cancellation, PID cleanup, BDD allowance, and source/compiled CLI
  behavior; require Node in CI.
- [x] Add examples/process-tool.agc, which runs racket --version and checks its
  Result and exit code; include it in CI with --allow-run.

### 1. Everyday library (remaining phase 5n and supporting utilities)

Function values are already available, so collection callbacks need no new
closure or scheduler feature. Keep names and argument order consistent with the
existing builtin library.

- [x] `List.concat`, `take`, `drop`, `at`: immutable operations, clamped
  nonnegative counts, and zero-based checked indexes.
- [x] Settle `reduce` argument order before implementing callbacks: accumulator
  first, `f(accumulator, item)`.
- [x] `List.map`, `filter`, `reduce`: exact callback signatures, ordered
  immutable traversal, contextual empty inputs, and shared execution limits.
- [x] `List.sort`, `sort_by`: stable ascending order over Int, Float or String
  (keys), NaN last, one key call per element.
- [x] Add string search/replacement and missing numeric conversions:
  `String.index_of/at/reverse/code/from_code` (`String.replace` already existed)
  and `Float.from_int`, `Float.to_int`, `Float.to_int!`.
- [x] Specify and add basic time and randomness APIs: `Time.now_ms` (wall
  clock), `Time.monotonic_ms`, inclusive `Random.int`, `Random.float` in [0, 1),
  a per-run generator seeded from the OS or `--seed N`.
- [ ] Decide which other gaps in
  [`docs/future/05-list-operations.md`](../future/05-list-operations.md) ("Other
  gaps for code-challenge programs": math, conversions, strings, sets, input,
  performance) belong here after a real task needs them.
- [ ] Add harder 6b model-evaluation tasks that need sorting.

**Milestone:** useful everyday scripts and automation using files, processes and
the basic library.

### 2. Typed JSON, builders and schemas

#### Phase 5f2: Typed JSON decoding

```text
JSON.decode(s: String, type: T) -> Result[T]
```

The second argument is a struct name, not a value, as in
`JSON.decode(text, User)`. The checker types the call as `Result[User]`, and the
evaluator walks the declared fields.

- The target type may contain only `Int`, `Float`, `Bool`, `String`, `List[T]`,
  `Map[String, V]`, and other structs. Anything else is `CHECK-NOT-DECODABLE`,
  reported before the program runs.
- Fields map to JSON keys by name. Struct tags such as Go's `json:"user_name"`
  are out of scope.
- A missing field or a wrong type is `error("age: expected Int, found String")`,
  with the path to the field. Extra keys are ignored.
- A JSON integer decodes to `Float` when the field is `Float`, but a JSON float
  never decodes to `Int`.

- [x] Parse a bare type name as an expression and accept it only in JSON type
  argument positions (JSON.decode and JSON.schema).
- [x] Check that the target type is decodable.
- [x] Decode nested structs, lists, and maps, with the path in error messages.
- [x] Add a round-trip test: `JSON.encode` then `JSON.decode` gives back the
  same field values (compare fields, since structs have no `==`).

#### Phase 5i: JSON builders and schemas

Construct structured output at run time, including future JSON-RPC replies.

```text
JSON.object(fields: Map[String, Json]) -> Json
JSON.array(items: List[Json]) -> Json
JSON.from(value: T) -> Json
JSON.null() -> Json
JSON.null?(j: Json) -> Bool
JSON.schema(type: T) -> Json
```

- `JSON.from` accepts the same types as `JSON.encode`.
- `JSON.schema(AddArgs)` takes a struct name, as in `JSON.decode`, and returns
  its JSON Schema (`type`, `properties`, `required`). MCP tools declare an
  `inputSchema`, so a tool is a struct plus a function.
- Same decodable-type rule as 5f2: `CHECK-NOT-DECODABLE` otherwise.

- [x] Add the functions above and focused behavior tests.
- [x] Verify `JSON.schema` output against an independent expected schema for one
  struct.

### 3. Modules and imports

Split larger programs across files with explicit exports and predictable
resolution. This is planned language syntax, not an extension to implement
without a specification.

- [x] Define import/export syntax, module naming, path resolution and the
  entrypoint rule; normative rules now live in grammar.md.
- [x] Decide visibility, duplicate-name handling, import cycles and diagnostic
  spans across files.
- [x] Implement loading, checking and execution without resetting the
  execution's shared budget or resource ownership.
- [x] Test a program spanning multiple files and controlled diagnostics for
  missing imports, cycles and private names.

### 3a. Embedded standard library and external resolution

- [x] Reserve `std/` for embedded Agentica sources, retaining explicit import
  aliases.
- [x] Ship a String FIFO in `stdlib/queue.agc` without native queue dispatch.
- [x] Add `pkg/` search roots: entrypoint-local agc_libs, AGENTICA_PATH, user
  data, system data.
- [x] Validate paths and symlink containment; preserve module identities, source
  spans and BDD loading.
- [x] Verify queue behavior, precedence, compiled CLI and relocated release
  bundles.
- [x] Document imports/API in the grammar and programming reference together.

### 7. Real applications

Use complete programs to expose missing APIs before broadening the language.

- [ ] Build a file-processing CLI with useful error handling and structured
  output.
- [ ] Build a tool-running automation script that checks exits and cleans up
  children.
- [ ] Build a small HTTP service using typed JSON and modules.
- [ ] Add functional tests at each application's boundary and use Phase 6 agent
  evaluations to identify the next gaps.

**Milestone:** practical larger general-purpose programs, demonstrated by these
applications rather than a feature checklist alone.

### 8. MCP examples (phase 5m), then Streamable HTTP

Build stdio examples first on the file/process/JSON/module foundations. A
minimal protocol scaffold lives at `examples/mcp/stdio.agc`; it handles
`initialize`, `ping`, and an empty `tools/list`, but is not the planned tool
server yet.

- [x] Add the minimal `examples/mcp/stdio.agc` stdio scaffold with flushed
  JSON-RPC replies.
- [ ] `examples/mcp_server.agc`: a stdio server that answers `initialize`,
  `tools/list`, and `tools/call` for one or two tools. Logs go to standard error
  with `IO.warn`, so standard output carries only protocol messages.
- [ ] `examples/mcp_client.agc`: spawns the server above, initializes, lists
  tools, and calls one.
- [ ] A test that runs the client against the server and checks the result.
- [ ] Independent fixtures (see "Independent integration fixtures"): the
  Agentica client against an independent stdio server, and an independent client
  against the Agentica server. Required in CI; local runs may visibly skip when
  the chosen tool is missing.
- [ ] Specify dedicated SSE and Streamable HTTP behavior, then implement it over
  the existing HTTP/1.1 streaming APIs with independent interoperability tests.

Task concurrency is already available for handling notifications while a client
waits. Channels are planned in phase 17
([`docs/future/27-iteration-and-concurrency.md`
§27.2](../future/27-iteration-and-concurrency.md#272-channels));
`Process.poll_line` remains proposed in [`docs/future/08-concurrency.md` section
8](../future/08-concurrency.md#8-concurrency-and-parallelism). UUID and Base64
remain later utilities unless a real application establishes an earlier need.
A Ruby-style `Regex` is designed in
[§48](../future/48-regex.md#48-regular-expressions), and it waits until after
the bootstrap (roadmap row 7.10, phase 29).

