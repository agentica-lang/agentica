# Code analysis (`std/analysis`)

`import Analysis from "std/analysis"`. A program asks what `agentica check`,
`outline`, `type-at`, `symbol` and `refs` ask and gets plain structs. The
command line runs the same code, so the `*_json` functions give byte for byte
the `--json` output (`references/queries.md` has the shapes and the rules for
names).

```text
Analysis.workspace() -> Analysis.Workspace          # version: 1, buffers: {}
Analysis.open(files: Analysis.Workspace) -> Analysis.Session
Analysis.update(session, path: String, text: String) -> Analysis.Session
Analysis.close(session, path: String) -> Analysis.Session
Analysis.refresh(session, path: String) -> Analysis.Session   # fills the cache for path
Analysis.check(session, path: String) -> Analysis.Checked
Analysis.outline(session, path: String) -> Result[Analysis.Outline]
Analysis.type_at(session, path: String, line: Int, column: Int) -> Result[Analysis.TypeAt]
Analysis.symbol(session, name: String, paths: List[String]) -> Result[Analysis.Symbols]
Analysis.refs(session, path: String, line: Int, column: Int) -> Result[Analysis.Refs]
Analysis.diagnostic(message: String) -> Result[Analysis.Diagnostic]
Analysis.outline_json(found) -> Json     # also type_at_json, symbols_json, refs_json,
                                         # diagnostic_json
```

- Files come from the disk of the working folder, except those with a buffer
  (`update`, or `Workspace.buffers`): the text stands in for the file, whether
  or not the disk has it, for the file and for every file that imports it.
  `close` gives the disk back. Two spellings of one file are one buffer (create the folder of a new file
  before `update`). `Workspace.version` is reserved (1).
- A `Session` is an immutable value: tasks may share and ask it at once, and an
  `update` leaves the copy of other tasks as it was. `Session.internal` is not
  API.
- `refresh` keeps the linked and checked program of `path` and the parsed
  modules in the session (at most 16 checked files, the least recently
  refreshed leaving first). `check`, `type_at` and `refs` use the checked
  program; `symbol` only the parsed modules. A question reads the files again and uses the cache
  only where the modules and their texts are the ones it was made from, so the
  answers are the same with or without `refresh`. Without it, each question
  runs the stages from the start. Run one `refresh` at a time and store the
  session it returns; two refreshes of one session give two caches, and keeping
  one drops the other's work, not correctness. There is no task or lock.
- Answers are structs with no enum. An absent text is `""` (`""` where the JSON
  has `null`), an absent definition an empty list (`TypeAt.definition` holds 0
  or 1). `Checked.passed` is true when there is no problem, else `diagnostics`
  holds the first one. A range is `Region(start, stop)` of `Position(line,
  column)`, from 1, in characters. `kind` is an open set. The types are
  aliases: read their fields, do not construct them (`Analysis.Position(...)`
  is `CHECK-UNKNOWN-TYPE`), so a program cannot make a `Diagnostic` of its own,
  for a timeout say, except by reading JSON with `Analysis.diagnostic`. A
  diagnostic's `file` is the root as typed; `Checked.file` is the canonical
  name.
- `symbol` searches `paths` (files or folders, `.` when empty) and, first, every
  file with a buffer, as `--stdin` does, even outside `paths` and in the
  bytewise order of their canonical paths; unlinkable files are in `skipped`.
  A folder that only buffers make is `QUERY-USAGE` (folders are read from disk).
  `refs` answers for the file at the position and what it imports. A builtin
  has `module` `""` (`symbol`) or an empty `definition` and `builtin` set
  (`refs`).
- `outline`, `type_at`, `symbol` and `refs` return an error whose message is
  one JSON diagnostic (the `--json` object). `Analysis.diagnostic(message)`
  reads it, so `try` works. Codes are the command line's: `LEX-`, `PARSE-`,
  `CHECK-`, `PKG-`, `QUERY-NO-EXPRESSION`, `QUERY-NOT-FOUND`, and
  `QUERY-USAGE` for a file that cannot be read, a position below line 1 or
  column 1, an empty `symbol` name or a path with no `*.agc` file. Their
  `file` is the path asked, or `<arguments>` for `symbol`; the usage `help`
  of the command line is missing.
- Cost: the compiler's pure core is compiled into the program, about 24,000
  lines, so a run from source pays seconds. For a tool that runs often:
  `agentica compile tool.agc -o tool.agcb`, then `agentica run -- tool.agcb`.
- `std/internal/` is private to `std/`: another file that imports it gets
  `CHECK-IMPORT-IO`.
