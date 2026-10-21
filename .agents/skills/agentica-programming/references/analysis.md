# Code analysis (`std/analysis`)

`import Analysis from "std/analysis"`. A program asks what `agentica check`,
`outline` and `type-at` ask and gets plain structs. The command line runs the
same code, so the `*_json` functions give byte for byte the `--json` output
(`references/queries.md` has the shapes and the rules for names).

```text
Analysis.workspace() -> Analysis.Workspace          # version: 1, buffers: {}
Analysis.open(files: Analysis.Workspace) -> Analysis.Session
Analysis.update(session, path: String, text: String) -> Analysis.Session
Analysis.close(session, path: String) -> Analysis.Session
Analysis.check(session, path: String) -> Analysis.Checked
Analysis.outline(session, path: String) -> Result[Analysis.Outline]
Analysis.type_at(session, path: String, line: Int, column: Int) -> Result[Analysis.TypeAt]
Analysis.diagnostic(message: String) -> Result[Analysis.Diagnostic]
Analysis.outline_json(found) -> Json     # also type_at_json, diagnostic_json
```

- Files come from the disk of the working folder, except those with a buffer
  (`update`, or `Workspace.buffers`): the text stands in for the file, whether
  or not the disk has it, for the file and for every file that imports it.
  `close` gives the disk back. Two spellings of one file are one buffer.
- A `Session` is an immutable value: tasks may share and ask it at once, and an
  `update` leaves the copy of other tasks as it was. `Session.internal` is not
  API. There is no cache: each question runs the stages from the start.
- Answers are structs with no enum. An absent text is `""` (`""` where the JSON
  has `null`), an absent definition an empty list (`TypeAt.definition` holds 0
  or 1). `Checked.passed` is true when there is no problem, else `diagnostics`
  holds the first one. A range is `Region(start, stop)` of `Position(line,
  column)`, from 1, in characters. `kind` is an open set.
- `outline` and `type_at` return an error whose message is one JSON diagnostic
  (the `--json` object). `Analysis.diagnostic(message)` reads it, so `try`
  works. Codes are the command line's: `LEX-`, `PARSE-`, `CHECK-`, `PKG-`,
  `QUERY-NO-EXPRESSION`, and `QUERY-USAGE` for a file that cannot be read or a
  position below line 1 or column 1.
- Cost: the compiler's pure core is compiled into the program, about 24,000
  lines, so a run from source pays seconds. For a tool that runs often:
  `agentica compile tool.agc -o tool.agcb`, then `agentica run -- tool.agcb`.
- `std/internal/` is private to `std/`: another file that imports it gets
  `CHECK-IMPORT-IO`.
