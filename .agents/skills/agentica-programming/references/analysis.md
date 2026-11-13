# Code analysis (`std/analysis`)

`import Analysis from "std/analysis"`. A program asks what `agentica check`,
`outline`, `type-at`, `symbol` and `refs` ask and gets plain structs. The
command line runs the same code, so the `*_json` functions give byte for byte
the `--json` output (`queries.md` has the shapes and the rules for names).

```text
Analysis.workspace() -> Analysis.Workspace          # version: 1, buffers: {}
Analysis.open(files: Analysis.Workspace) -> Analysis.Session
Analysis.update(session, path: String, text: String) -> Analysis.Session
Analysis.close(session, path: String) -> Analysis.Session
Analysis.refresh(session, path: String) -> Analysis.Session   # fills the cache for path
Analysis.entry(session, path: String) -> Result[Analysis.Entry]   # what refresh kept for path
Analysis.adopt(session, entry: Analysis.Entry) -> Analysis.Session   # cache = that entry alone
Analysis.check(session, path: String) -> Analysis.Checked
Analysis.outline(session, path: String) -> Result[Analysis.Outline]
Analysis.type_at(session, path: String, line: Int, column: Int) -> Result[Analysis.TypeAt]
Analysis.type_at_partial(session, path: String, line: Int, column: Int) -> Result[Analysis.TypeAt]
Analysis.symbol(session, name: String, paths: List[String]) -> Result[Analysis.Symbols]
Analysis.refs(session, path: String, line: Int, column: Int) -> Result[Analysis.Refs]
Analysis.refs_partial(session, path: String, line: Int, column: Int) -> Result[Analysis.Refs]
Analysis.native_modules(session, path: String) -> Result[Analysis.NativeModules]
Analysis.bodies(session, path: String) -> Result[Analysis.Bodies]   # experimental
Analysis.diagnostic(message: String) -> Result[Analysis.Diagnostic]
Analysis.outline_json(found) -> JSON.Value     # also type_at_json, symbols_json, refs_json,
                                         # native_modules_json, bodies_json,
                                         # diagnostic_json
```

- Files come from the disk of the working folder, except those with a buffer
  (`update`, or `Workspace.buffers`): the text stands in for the file, on disk
  or not, for the file and for every file that imports it. `close` gives the
  disk back. Two spellings of one file are one buffer (create the folder of a
  new file before `update`). `Workspace.version` is reserved (1).
- A `Session` is an immutable value: tasks may share and ask it at once, and an
  `update` leaves other tasks' copy as it was. `Session.internal` is not API.
- `refresh` keeps the linked and checked program of `path` and the parsed
  modules in the session (at most 16 checked files, the least recently refreshed
  leaving first). A question uses the cache only where the modules and texts are
  the ones it was made from, so answers are the same with or without `refresh`;
  without it each question runs the stages from the start. Store the session
  `refresh` returns: two refreshes of one session give two caches, and keeping
  one drops the other's work, not correctness.
- Sharing the cache between tasks: a `Session` holds functions, so an `ATS`
  cannot hold one, but an `Analysis.Entry` is data. A task refreshes its own
  session and puts `Analysis.entry(refreshed, path)` in an
  `ATS[String, Analysis.Entry]`; a task that asks about `path` first does
  `Analysis.adopt(session, entry)`, which keeps the buffers and replaces the
  cache by that entry alone. A stale entry costs time only. `entry` is an error
  when `path` has none, and needs the same spelling of `path` as `refresh`.
  Entries of two files are separate caches. The program deletes the entries it
  no longer wants.
- Answers are structs with no enum. An absent text is `""` (where the JSON has
  `null`), an absent definition an empty list (`TypeAt.definition` holds 0 or
  1). `Checked.passed` is true when there is no problem, else `diagnostics`
  holds the first one. A range is `Region(start, stop)` of `Position(line,
  column)`, from 1, in characters. The types are aliases: read their fields, do
  not construct them (`Analysis.Position(...)` is `CHECK-UNKNOWN-TYPE`); a
  `Diagnostic` comes from `Analysis.diagnostic`. A diagnostic's `file` is the
  root as typed; `Checked.file` is the canonical name.
- `symbol` searches `paths` (files or folders, `.` when empty) and, first, every
  file with a buffer as `--stdin` does, even outside `paths`, in the bytewise
  order of their canonical paths; unlinkable files are in `skipped`. A folder
  that only buffers make is `QUERY-USAGE` (folders are read from disk). `refs`
  answers for the file at the position and what it imports. A builtin has
  `module` `""` (`symbol`) or an empty `definition` and `builtin` set (`refs`).
- `type_at_partial` and `refs_partial` are `--partial`: with a function that
  does not check they answer from the others (`partial` true, the failures in
  `diagnostics`); a declaration that fails is still the error. In a failed
  function `TypeAt.type` is `""`, and a position the link cannot name is the
  first problem, as an error.
- `native_modules` lists the `extern module` blocks of a file for a code
  generator (no command line form): per `NativeBlock` the `library`, `functions`
  (`mode` `short` or `dirty`, `parameters`, `result`, `signature`, and
  `types_in`/`types_out`, the types the parameters and the result reach),
  `resources`, the `types` that cross (`kind`, bare `name`, `members`, `shape`)
  and `api_major`/`api_minor`. `signature` and `shape` are the exact texts the
  loader compares with the module's tables. A block `range` covers its
  declarations only, and two blocks of one library are one.
- `bodies` (experimental: the shape may change between releases with no
  breaking mark) gives every function of a file with a body, private ones too:
  `name`, `linked`, `generics`, typed `params` (with `default`, one node or
  none) and `result` (`TypeShape`: `kind`, `name`, `args`), and `body`, a list
  of `Node` (`kind`, `type`, `range`, `text`, `target`, `new`, `children`).
  `modules` maps each `@N::` prefix of a linked name to its file. A `call` has
  the resolved `target` (`Int.shift_left`, `Bytes.length` for `data.size`,
  `Bytes.at` for `data[i]`, a linked function name) and may leave out
  defaulted arguments; `op` has the operator as written (`+`, `<=`); `let` has
  `new`, `_ = x` is `discard`; a node past what it covers yet is `other`
  (loops, lists, maps, structs, blocks). No command line form.
- `outline`, `type_at`, `type_at_partial`, `symbol`, `refs`, `refs_partial`,
  `native_modules` and `bodies` return an error whose message is one JSON
  diagnostic (the `--json` object); `Analysis.diagnostic(message)` reads it, so
  `try` works.
  Codes are the command line's, and `QUERY-USAGE` also covers a position below
  line 1 or column 1 and an empty `symbol` name.
- Cost: the compiler's pure core is compiled into the program, so a run from
  source pays seconds. For a tool that runs often: `agentica compile tool.agc -o
  tool.agcb`, then `agentica run -- tool.agcb`.
