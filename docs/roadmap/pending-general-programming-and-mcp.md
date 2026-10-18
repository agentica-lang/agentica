## Pending work: General programming and MCP (after the VM)

### Completed: Strict Void prerequisite

**Done:** no-value completion separated from `Nil`; `main() -> Void`, explicit
returns, `ok()` for `Result[Void]`; side-effect APIs, callbacks, programs and
references migrated. Rules in the grammar.

### Completed: Files and paths

**Done:** file/path APIs with error behavior and byte limits, text and bytes
I/O, directories, metadata, temp-dir integration tests and a file-processing
example. Rules in the grammar and the programming skill.

### Completed: Processes (phase 5l)

**Done:** `Process` handles over the VM (no shell interpolation),
full-operation deadlines, 1 MiB per-call limits, strict UTF-8 lines, cleanup
of direct children on close/return/exit, `--allow-run` off by default; local
Node tests, CI and `examples/process-tool.agc`. API in the builtin catalog
([`06b-builtins.md`](../grammar/06b-builtins.md)).

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
- [ ] Decide which other gaps belong here after a real task needs them. From
  the code-challenge list: math (`abs`, `min`, `max`, `pow`, `sqrt`, `floor`,
  `ceil`, `gcd`), conversions, string helpers, input helpers (lines of
  integers), tuples, bounds and performance.
- [ ] Add harder 6b model-evaluation tasks that need sorting.

**Milestone:** useful everyday scripts and automation using files, processes and
the basic library.

### 2. Typed JSON, builders and schemas

**Done (phases 5f2, 5i):** `JSON.decode` into typed structs (decodable-type
rule, `CHECK-NOT-DECODABLE`, path errors, extras ignored) and builders/schemas
(`JSON.object/array/from/null/null?/schema`, MCP `inputSchema`). Rules in the
grammar and the builtin catalog.

### 3. Modules and imports

**Done (phases 3, 3a):** import/export syntax, naming, resolution, entrypoint,
visibility, cycles, spans; `std/` embedded sources with aliases, `pkg/` search
roots, symlink containment, compiled CLI and relocated bundles. Rules in
[`05b-modules.md`](../grammar/05b-modules.md).

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
waits. Channels are built
([§27.2](../future/27-iteration-and-concurrency.md#272-channels));
`Process.poll_line` remains proposed in
[§27.6](../future/27-iteration-and-concurrency.md#276-open-questions). UUID and
Base64
remain later utilities unless a real application establishes an earlier need.
A Ruby-style `Regex` is designed in
[§48](../future/48-regex.md#48-regular-expressions), and it waits until after
the bootstrap (roadmap row 7.10, phase 29).

