---
title: Code analysis (std)
weight: 8
description: The std/analysis module, which answers the questions of check, outline and type-at from a program.
---

`std/analysis` asks the compiler about code from inside a program: `import Analysis from "std/analysis"`. It answers the questions of `agentica check`, `agentica outline` and `agentica type-at`, and gives the answers as plain structs. The command line runs the same code, so `Analysis.outline_json` and `Analysis.type_at_json` give byte for byte what `agentica --json outline` and `type-at` print, and `Analysis.diagnostic_json` what `--json check` prints on stderr.

```ruby
Analysis.workspace() -> Analysis.Workspace
Analysis.open(files: Analysis.Workspace) -> Analysis.Session
Analysis.update(session: Analysis.Session, path: String, text: String) -> Analysis.Session
Analysis.close(session: Analysis.Session, path: String) -> Analysis.Session
Analysis.check(session: Analysis.Session, path: String) -> Analysis.Checked
Analysis.outline(session: Analysis.Session, path: String) -> Result[Analysis.Outline]
Analysis.type_at(session: Analysis.Session, path: String, line: Int, column: Int) -> Result[Analysis.TypeAt]
Analysis.diagnostic(message: String) -> Result[Analysis.Diagnostic]
Analysis.outline_json(found: Analysis.Outline) -> Json
Analysis.type_at_json(found: Analysis.TypeAt) -> Json
Analysis.diagnostic_json(found: Analysis.Diagnostic) -> Json
```

## Sessions and buffers

A `Session` reads files from the disk of the working folder, except the files that have a buffer: the text an editor has open and has not saved. `Analysis.update(session, path, text)` returns a session where `path` has `text`, whether or not the disk has the file, and `Analysis.close` takes the buffer out. Two spellings of one file are one buffer; create the folder of a new file before `update`, or `close` it with the spelling you gave. A buffer counts for the file itself and for every file that imports it. `Analysis.open` takes a `Workspace`, `Analysis.workspace()` or one whose `buffers` map already holds paths and texts (its `version` is reserved and must be 1; when two paths are one file, the later one wins).

A session is a value. Tasks may share it and ask it at once, and an `update` in one task leaves the copy of the others as it was. Its field is not API. Each question runs the stages from the start: the session keeps no cache.

## Answers

The answers are structs of strings, ints, bools and lists, with no enum: the shapes of the `--json` forms, with the names of their keys (`range` is `Region`, with `start` and `stop`; the JSON key is `end`). A value that is absent is `""`, or an empty list for a struct: `Outline.doc`, `Item.doc` and `Import.alias` are `""` where the JSON has `null`, and `TypeAt.definition` is empty or holds one `Definition`. A `kind` is a string, an open set. The types are aliases of the library's own: a program reads their fields, but cannot construct them by name (`Analysis.Position(line: 3, column: 9)` is `CHECK-UNKNOWN-TYPE`), so it cannot make a `Diagnostic` of its own, for a timeout say, except by reading one from JSON with `Analysis.diagnostic`. An answer names a file as the command line does: by its canonical path, relative to the working folder when the file is below it. A diagnostic keeps the root file as the path you gave, as `check` does, so `Checked.file` and the `file` of its diagnostic may differ in spelling.

- `Analysis.check` links and checks the file as `agentica check` does. `Checked.passed` is true when the program has no problem, and `diagnostics` holds the first problem, if any.
- `Analysis.outline` lists what the file declares, as `agentica outline` does. The file is only parsed.
- `Analysis.type_at` gives the type and the definition at the position, as `agentica type-at` does. Line and column count from 1.

## Errors

`outline` and `type_at` return a `Result` whose error message is the diagnostic as one JSON object, the form of `--json`, so `try` works. `Analysis.diagnostic` reads it back into an `Analysis.Diagnostic`. The codes are those of the command line: `LEX-`, `PARSE-`, `CHECK-` and `PKG-`, `QUERY-NO-EXPRESSION` for a position that is on no expression, and `QUERY-USAGE` for a file that cannot be read or a position below line 1 or column 1; that diagnostic names the file.

```agentica {mode="check"}
import Analysis from "std/analysis"

def main() -> Void
  session = Analysis.open(Analysis.workspace())
  session = Analysis.update(session, "app.agc", "def twice(n: Int) -> Int\n  return n * 2\nend\n")
  outline = Analysis.outline(session, "app.agc")
  if outline.ok?
    for item in outline.unwrap!.items
      puts("#{item.kind} #{item.signature}")
    end
  else
    puts(Analysis.diagnostic(outline.message).unwrap!.code)
  end
end
```

## Cost

The compiler is part of the program that imports `std/analysis`: its pure core is carried by the binary as the private `std/internal/compiler/`, and only `std/` modules may import that. A program that imports `std/analysis` therefore checks and lowers about 24,000 more lines when it runs from source, and the checker and the catalog of builtins it asks are the ones of the binary that compiled it, frozen in the compiled program. The binary refuses a `.agcb` file of another Agentica version, so recompile a tool after upgrading agentica. A program that runs often can pay the compile time once: `agentica compile tool.agc -o tool.agcb`, then `agentica run -- tool.agcb`.
