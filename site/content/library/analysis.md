---
title: Code analysis (std)
weight: 8
description: The std/analysis module, which answers the questions of check, outline, type-at, symbol and refs from a program.
---

`std/analysis` answers, inside a program, the questions that the command line answers: `import Analysis from "std/analysis"`. The answers are plain structs. The `*_json` functions give the same bytes as the `--json` output of `agentica outline`, `type-at`, `symbol` and `refs` ([Getting started](/getting-started/#query-the-code)), and `Analysis.diagnostic_json` gives what `--json check` prints on stderr.

```ruby
Analysis.workspace() -> Analysis.Workspace
Analysis.open(files: Analysis.Workspace) -> Analysis.Session
Analysis.update(session: Analysis.Session, path: String, text: String) -> Analysis.Session
Analysis.close(session: Analysis.Session, path: String) -> Analysis.Session
Analysis.refresh(session: Analysis.Session, path: String) -> Analysis.Session
Analysis.check(session: Analysis.Session, path: String) -> Analysis.Checked
Analysis.outline(session: Analysis.Session, path: String) -> Result[Analysis.Outline]
Analysis.type_at(session: Analysis.Session, path: String, line: Int, column: Int) -> Result[Analysis.TypeAt]
Analysis.type_at_partial(session: Analysis.Session, path: String, line: Int, column: Int) -> Result[Analysis.TypeAt]
Analysis.symbol(session: Analysis.Session, name: String, paths: List[String]) -> Result[Analysis.Symbols]
Analysis.refs(session: Analysis.Session, path: String, line: Int, column: Int) -> Result[Analysis.Refs]
Analysis.refs_partial(session: Analysis.Session, path: String, line: Int, column: Int) -> Result[Analysis.Refs]
Analysis.diagnostic(message: String) -> Result[Analysis.Diagnostic]
Analysis.outline_json(found: Analysis.Outline) -> Json
Analysis.type_at_json(found: Analysis.TypeAt) -> Json
Analysis.symbols_json(found: Analysis.Symbols) -> Json
Analysis.refs_json(found: Analysis.Refs) -> Json
Analysis.diagnostic_json(found: Analysis.Diagnostic) -> Json
```

## Sessions and buffers

A `Session` reads files from the disk under the working folder, except files that have a buffer: text an editor has open and has not saved. `Analysis.update(session, path, text)` returns a session where `path` has `text`, whether or not the disk has the file. `Analysis.close` removes the buffer. Two spellings of one file are one buffer. Create the folder of a new file before `update`, and `close` it with the spelling you gave. A buffer answers for its own file and for every file that imports it.

`Analysis.open` takes a `Workspace`: `Analysis.workspace()` gives an empty one, or build one whose `buffers` map holds paths and texts. Its `version` must be 1. When two paths name one file, the later one wins.

A session is a value. Tasks may share one and ask it at once; an `update` in one task leaves the copies of the others unchanged. Its fields are not API. A new session has no cache: each question runs the stages from the start, until `refresh` fills it (next section).

## Refresh and the cache

`Analysis.refresh(session, path)` returns a session whose cache holds the linked and checked program of `path`, and the parsed modules it reads. A loop that keeps one session runs `update`, then `refresh`, then the questions, which then skip parsing and checking about `path`.

`check`, `type_at` and `refs` use the checked program in the cache; `symbol` links each file it searches and uses only its parsed modules. Each question reads the files again, starting at its own file, and uses the cache only where the modules and their texts are the ones the cache was made from. Buffer edits, `close`, changes on disk, new and removed files, and a change of `agentica.toml` that changes what an import means all count. So the answers are the same with or without `refresh`: a stale cache costs time, never a wrong answer. A refresh checks again only when a module changed, and parses only the modules whose text changed; the check always covers the whole program of `path`. A file that cannot be read or linked leaves the cache as it was, and the questions say why.

The cache keeps at most 16 checked files, the least recently refreshed leaving first, with the parsed modules they reach. It lives in the value: there is no task, channel or lock, so the caller owns the loop. Run one `refresh` at a time per session and keep the session it returns. Two refreshes from one session make two caches, and keeping one drops the other's work, which costs time only. A program that refreshes in a task and calls `update` on its own copy meanwhile adopts the refreshed session only if no `update` or `close` came after the refresh started; otherwise it keeps its own session and refreshes again later.

## Answers

The answers are structs of strings, ints, bools and lists, with no enum. Their fields are the keys of the `--json` forms, with the same names, except that `range` is a `Region` with `start` and `stop` (JSON `end`). An absent value is `""`, or an empty list for a struct: `Outline.doc`, `Item.doc` and `Import.alias` are `""` where the JSON has `null`. `TypeAt.definition` is empty or holds one `Definition`. A `kind` is a string, an open set: a program accepts a kind it does not know.

The types are aliases of the library's own. A program reads their fields but cannot build them by name: `Analysis.Position(line: 3, column: 9)` is `CHECK-UNKNOWN-TYPE`. To get a `Diagnostic`, for a timeout say, read one from JSON with `Analysis.diagnostic`.

A file is named as on the command line: by its canonical path, relative to the working folder when it is below it. A diagnostic keeps the root file as the path you gave, as `check` does, so `Checked.file` and the `file` of its diagnostic may be spelled differently.

- `Analysis.check` links and checks the file. `Checked.passed` is true when there is no problem; `diagnostics` holds the first one, if any.
- `Analysis.outline` lists what the file declares. The file is only parsed.
- `Analysis.type_at` gives the type and the definition at a position. Line and column count from 1.
- `Analysis.symbol` finds where `name` is declared in the files and folders of `paths` (`.` when the list is empty). A folder means every `*.agc` file below it. The files are linked together, and those that do not link are listed in `Symbols.skipped`. `Symbol.module` is the file (`""` for a builtin), and `help` is the object of `agentica help NAME --json` for a builtin, JSON null for the others. Every file with a buffer in the session is searched too, first, as `--stdin FILE` does, whether or not `paths` names it, so a query cannot be scoped to a folder while other buffers are open. Buffers come in the bytewise order of their canonical paths, whatever order they were put in, so `matches` does not depend on the history of `update` calls. Folders are listed on the disk: a folder that exists only as buffers (buffer `newdir/new.agc` with `paths` `["newdir"]`) is a `QUERY-USAGE` "cannot read". Name the buffer's file, or leave `paths` empty.
- `Analysis.refs` gives the declaration of the name at the position and every reference to it, as `agentica refs` does. It links and checks the file as `type_at` does, and sees the file and what it imports; a file that only imports it is not seen. `Refs.definition` is empty for a builtin, which `Refs.builtin` names (`""` for anything else). A `Reference` is the `range` of the name in its `file`.
- `Analysis.type_at_partial` and `Analysis.refs_partial` are `type_at` and `refs` with `--partial`: when some functions do not check, they answer from the others, with `partial` true and the failures in `diagnostics`; a declaration, `main` or constant that does not check, or a field or builtin for `refs_partial`, is still the first problem as an error. `TypeAt.type` is `""` for a name inside a function that did not check, and in such a function a position the link cannot name gives the first problem as the error.

## Errors

`outline`, `type_at`, `type_at_partial`, `symbol`, `refs` and `refs_partial` return a `Result` whose error message is the diagnostic as one JSON object, the `--json` form, so `try` works. `Analysis.diagnostic` reads it back into an `Analysis.Diagnostic`. The codes are those of the command line: `LEX-`, `PARSE-`, `CHECK-` and `PKG-`; `QUERY-NO-EXPRESSION` for a position on no expression; `QUERY-NOT-FOUND` for a `symbol` name that nothing declares; and `QUERY-USAGE` for a file that cannot be read, a position below line 1 or column 1, or a `symbol` with an empty name or a path that names no `*.agc` file. For `outline`, `type_at` and `refs` the diagnostic names the file; for `symbol` its `file` is `<arguments>`, as on the command line. Unlike the command line, `QUERY-USAGE` has no usage `help` line; `QUERY-NOT-FOUND` keeps its `help` (the files not searched).

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

The compiler is part of the program that imports `std/analysis`: its pure core is carried by the binary as the private `std/internal/compiler/`, and only `std/` modules may import that. A program that imports `std/analysis` therefore checks and lowers about 27,000 more lines when it runs from source, and the checker and the catalog of builtins it asks are the ones of the binary that compiled it, frozen in the compiled program. The binary refuses a `.agcb` file of another Agentica version, so recompile a tool after upgrading agentica. A program that runs often can pay the compile time once: `agentica compile tool.agc -o tool.agcb`, then `agentica run -- tool.agcb`.
