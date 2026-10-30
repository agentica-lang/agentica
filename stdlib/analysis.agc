## Asks the questions of `agentica check`, `outline`, `type-at`, `symbol` and `refs` from a program, and gets the
## answers as data.
##
## Import it with `import Analysis from "std/analysis"`. A `Session` holds the working folder (the disk) and the text
## of the files an editor has open and not saved: `Analysis.update` puts a buffer in a new session, `Analysis.close`
## takes it out, and a question reads the files of the disk except those with a buffer. The answers are plain structs,
## with no enum: the shapes of the `--json` forms (an absent text is `""`, and an absent definition is an empty list).
## The command line runs the same code, so `Analysis.outline_json`, `Analysis.type_at_json`, `Analysis.symbols_json`
## and `Analysis.refs_json` give byte for byte what `agentica --json outline`, `type-at`, `symbol` and `refs` print,
## and `Analysis.diagnostic_json` what `--json check` prints on stderr.
##
## `outline`, `type_at`, `type_at_partial`, `symbol`, `refs` and `refs_partial` return a `Result`: its error message is
## the diagnostic as one JSON object, the form of `--json`, and `Analysis.diagnostic` reads it back, so `try` works.
## The codes are those of the command line (`LEX-`, `PARSE-`, `CHECK-`, `PKG-`, and `QUERY-USAGE` for a file that
## cannot be read or a position below line 1 or column 1, `QUERY-NO-EXPRESSION`, `QUERY-NOT-FOUND`).
##
## The compiler is part of the program that imports this module (as the private `std/internal/compiler`), so a program
## that imports it pays the compile time of the compiler's core once. The checker and the catalog of builtins are the
## ones of the binary that compiled the program, frozen in it; the `std/` sources are read from the binary that runs
## it. The loader refuses a `.agcb` file of another Agentica version, so recompile a tool after upgrading agentica.
## A session is a value: tasks may ask one session at once, and an `update` in one task leaves the others' copy as it
## was.
##
## `Analysis.refresh` makes the questions about a file fast: it returns a session whose cache holds the linked and
## checked program of the file, and the parsed modules it reads. A loop that keeps one session does `update`, then
## `refresh`, then asks. A question reads the files again and uses the cache only where the modules and their texts are
## the ones it was made from (a buffer, a closed buffer, a change on the disk, a new or a removed file all count), so
## the answers are the same with or without `refresh`, whatever the cache holds. The cache keeps at most 16 checked
## files, the least recently refreshed leaving first, and the parsed modules that these reach. It lives in the value:
## there is no task or lock. The caller owns the loop: run `refresh` in a task, one at a time, and store the session it
## returns; two refreshes of one session give two caches, and keeping one drops the work of the other (it costs time,
## not correctness). To share the cache between tasks, `entry` takes from a refreshed session what it kept for a file,
## as plain data that an `ATS` table can hold, and `adopt` puts such an entry in another session: tasks that refresh
## different files lose nothing.
##
## A refresh does not check again a module whose text is the same as in the last program of the file that checked, when
## every module it imports is the same too: it takes what that check left for the module, so an edit of the file costs
## about the file itself, and an edit of an imported module checks that module and those that import it. The answers
## are those of a check from the start.

import Ast from "std/internal/compiler/syntax/ast"
import Cache from "std/internal/compiler/analysis/cache"
import Core from "std/internal/compiler/analysis/analysis"
import DiagnosticJson from "std/internal/compiler/diagnostics/diagnostic_json"
import DiagnosticModel from "std/internal/compiler/diagnostics/diagnostic_model"
import DiagnosticRead from "std/internal/compiler/diagnostics/diagnostic_read"
import Env from "std/internal/compiler/modules/link_env"
import Host from "std/internal/compiler/io/host"
import Model from "std/internal/compiler/analysis/model"
import Overlay from "std/internal/compiler/modules/overlay"
import OutlineJson from "std/internal/compiler/query/outline_json"
import Problems from "std/internal/compiler/diagnostics/problem"
import QueryPosition from "std/internal/compiler/query/query_position"
import RefsJson from "std/internal/compiler/query/refs_json"
import Sessions from "std/internal/compiler/analysis/session"
import SymbolJson from "std/internal/compiler/query/symbol_json"
import TypeAtJson from "std/internal/compiler/query/type_at_json"

## A place in a text: line and column count from 1, in characters.
export type Position = DiagnosticModel.Position

## A part of a text: `stop` is the first place after it.
export type Region = DiagnosticModel.Region

## A note on a second part of the text.
export type Label = DiagnosticModel.Label

## One problem of a program, in the shape of the `--json` diagnostic.
export type Diagnostic = DiagnosticModel.Diagnostic

## The place a question asked about.
export type Place = Model.Place

## One parameter of a function.
export type Parameter = Model.Parameter

## One field of a struct.
export type Field = Model.Field

## One variant of an enum.
export type Variant = Model.Variant

## One top-level declaration of a file.
export type Item = Model.Item

## One name of an import list.
export type ImportName = Model.ImportName

## One import of a file.
export type Import = Model.Import

## What a file declares.
export type Outline = Model.Outline

## The declaration of what an expression names.
export type Definition = Model.Definition

## What a position is on.
export type TypeAt = Model.TypeAt

## The answer of `check`.
export type Checked = Model.Checked

## One declaration that `symbol` found.
export type Symbol = Model.Symbol

## A file of a `symbol` query that was left out, with the first problem it hit.
export type Skipped = Model.Skipped

## The answer of `symbol`.
export type Symbols = Model.Symbols

## One use of a declaration.
export type Reference = Model.Reference

## The answer of `refs`.
export type Refs = Model.Refs

## What a session reads: the disk of the working folder, except the files of `buffers`, which map a path to the text
## that stands in for it (an unsaved buffer), whether or not the disk has the file.
export struct Workspace
  ## The version of this shape, 1.
  version: Int
  ## The text of each buffer, by path.
  buffers: Map[String, String]
end

## The files and buffers that the questions read. Its field is not API: it changes without a new version.
export struct Session
  ## The state of the session.
  internal: Sessions.Session
end

## What `refresh` kept for one file: the program it linked and checked and the modules it parsed. Unlike a `Session`,
## which holds functions, it is plain data, so an `ATS` table can hold it and tasks can share it. Its field is not API.
export struct Entry
  ## The state of the entry.
  internal: Cache.Root
end

## Returns the workspace of the disk, with no buffer.
export def workspace() -> Workspace
  no_buffers: Map[String, String] = {}
  return Workspace(version: 1, buffers: no_buffers)
end

## Returns a session that reads `files`.
export def open(files: Workspace) -> Session
  return Session(internal: Sessions.open(settings(), files.buffers))
end

## Returns `session` with `text` as the content of the file `path`, whether or not the disk has it. Two spellings of
## one file are one buffer.
export def update(session: Session, path: String, text: String) -> Session
  return Session(internal: Sessions.update(session.internal, path, text))
end

## Returns `session` without the buffer of `path`: the disk answers for the file again.
export def close(session: Session, path: String) -> Session
  return Session(internal: Sessions.close(session.internal, path))
end

## Returns `session` with the file `path` linked and checked in its cache, so the questions about `path` that follow
## reuse them, and so do those about files that import the same modules. A file that cannot be read or linked leaves
## the cache as it was, and the questions say why. Run one `refresh` at a time per session and keep what it returns.
export def refresh(session: Session, path: String) -> Session
  return Session(internal: Sessions.refresh(session.internal, path))
end

## Returns the entry that the cache of `session` holds for the file `path`, as the last `refresh` of it left it. It is
## an error when the cache holds none: the file was not refreshed, could not be linked, or its entry left the cache.
export def entry(session: Session, path: String) -> Result[Entry]
  case Sessions.entry(session.internal, path)
    some(root) -> return ok(Entry(internal: root))
    none -> return error("the cache holds no entry for #{path}")
  end
end

## Returns `session` with the cache of `entry` alone in place of its own, and the same buffers. A `refresh` or a
## question about the file of `entry` that follows takes the program from it when the files and buffers are as they
## were when it was made, and else works as usual, checking again only the modules that changed or import one that did.
## The answers are the same with any entry, so one that is stale costs time and never gives a wrong answer. An entry
## made by one session can be adopted by another over the same folder: tasks that each `refresh` their own session and
## keep the entries in an `ATS` table share the work, where two refreshes of one session would drop one of the caches.
export def adopt(session: Session, entry: Entry) -> Session
  return Session(internal: Sessions.adopt(session.internal, entry.internal))
end

## Returns the answer of `agentica check` for the file `path`: it links and checks the program, and its `diagnostics`
## hold the first problem, if any. A file that cannot be read is a `QUERY-USAGE` diagnostic.
export def check(session: Session, path: String) -> Checked
  return Core.checked(session.internal.cache, Sessions.asking(session.internal), path)
end

## Returns the declarations of the file `path`, as `agentica outline` lists them. The file is only parsed, so its
## imports need not exist.
export def outline(session: Session, path: String) -> Result[Outline]
  settings = Sessions.asking(session.internal)
  buffered = Sessions.buffered?(session.internal, path)
  case Core.outline(settings, path, buffered)
    Core.Outlined.Done(found) -> return ok(found)
    Core.Outlined.Unreadable -> return error(failure(Core.unreadable(path)))
    Core.Outlined.Rejected(problem) -> return error(failure(Core.named(settings, problem, path)))
  end
end

## Returns what the position `line`, `column` (from 1, in characters) of the file `path` is on, as `agentica type-at`
## answers: the type of the innermost expression or name and the definition of what it names. The file is linked and
## checked with what it imports, and needs no `main`.
export def type_at(session: Session, path: String, line: Int, column: Int) -> Result[TypeAt]
  settings = Sessions.asking(session.internal)
  if path == "" or line < 1 or column < 1
    return error(failure(Core.refused("the position is FILE, LINE and COLUMN, from line 1 and column 1", path)))
  end
  case Core.type_at(session.internal.cache, settings, QueryPosition.Asked(file: path, line: line, column: column))
    Core.Typed.Done(found) -> return ok(found)
    Core.Typed.Unreadable -> return error(failure(Core.unreadable(path)))
    Core.Typed.Rejected(problem) -> return error(failure(Core.named(settings, problem, path)))
  end
end

## As `type_at`, but a program in which some functions do not check is answered too, as `agentica type-at --partial`
## does. A position in a function that checked gets its type and definition, and a name in one that did not gets its
## definition and no type (`type` is ""); the answer has `partial` true and the problems of those functions in
## `diagnostics`. A program that checks gives the answer of `type_at`. A file that does not link, a program whose
## declarations (their types, `main`, the constants) do not check, and a position that the link cannot name in a
## function that did not check are the first problem, an error as for `type_at`.
export def type_at_partial(session: Session, path: String, line: Int, column: Int) -> Result[TypeAt]
  settings = Sessions.asking(session.internal)
  if path == "" or line < 1 or column < 1
    return error(failure(Core.refused("the position is FILE, LINE and COLUMN, from line 1 and column 1", path)))
  end
  asked = QueryPosition.Asked(file: path, line: line, column: column)
  case Core.type_at_partial(session.internal.cache, settings, asked)
    Core.Typed.Done(found) -> return ok(found)
    Core.Typed.Unreadable -> return error(failure(Core.unreadable(path)))
    Core.Typed.Rejected(problem) -> return error(failure(Core.named(settings, problem, path)))
  end
end

## Returns where `name` is declared in the modules linked from the files and folders of `paths`, as `agentica symbol`
## answers (`.` when `paths` is empty). A folder means every `*.agc` file below it. The files are linked together, and
## the ones that do not link are in `skipped`. Every file with a buffer in the session is searched first, as `--stdin`
## does, whether or not `paths` names it (so a query cannot be scoped to a folder while other buffers are open), in the
## bytewise order of their canonical paths, whatever order the buffers were put in; a path of `paths` that a buffer
## stands in for is read from the buffer. A folder that only buffers make (a buffer `new/a.agc` and `paths` `["new"]`)
## is not listed, since folders are read from the disk: it is `QUERY-USAGE`, "cannot read". An empty `name` or a path
## that names no `*.agc` file is `QUERY-USAGE`, a name that nothing declares is `QUERY-NOT-FOUND`, and when no file
## links the error is the first problem of the first one. The `QUERY-` diagnostics of `symbol` have the file
## `<arguments>`, and no usage `help` (the command line's line); `QUERY-NOT-FOUND` keeps its `help`, the files not
## searched.
export def symbol(session: Session, name: String, paths: List[String]) -> Result[Symbols]
  settings = Sessions.asking(session.internal)
  # Sorted, since `update` moves a buffer to the end of the list and the order of the matches must not depend on it.
  ordered = session.internal.buffers.sort_by do |buffer: Overlay.Buffer| buffer.names.key end
  held = ordered.map do |buffer: Overlay.Buffer| buffer.names.typed end
  searched = paths
  # The buffers make the list non-empty, which would drop the default folder of an empty `paths`.
  if searched.size == 0 and held.size > 0
    searched = ["."]
  end
  case Core.symbol(session.internal.cache, settings, name, held.concat(searched), "", "")
    Core.Found.Done(found) -> return ok(found)
    Core.Found.Rejected(problem) -> return error(failure(named_in(settings, problem, held)))
  end
end

## Returns the declaration of the name at the position `line`, `column` (from 1, in characters) of the file `path` and
## every reference to it, as `agentica refs` answers: in that file, linked and checked as for `type_at`, and in what it
## imports; a file that only imports it is not seen. A position that names nothing is `QUERY-NO-EXPRESSION`.
export def refs(session: Session, path: String, line: Int, column: Int) -> Result[Refs]
  settings = Sessions.asking(session.internal)
  if path == "" or line < 1 or column < 1
    return error(failure(Core.refused("the position is FILE, LINE and COLUMN, from line 1 and column 1", path)))
  end
  case Core.refs(session.internal.cache, settings, QueryPosition.Asked(file: path, line: line, column: column))
    Core.Referenced.Done(found) -> return ok(found)
    Core.Referenced.Unreadable -> return error(failure(Core.unreadable(path)))
    Core.Referenced.Rejected(problem) -> return error(failure(Core.named(settings, problem, path)))
  end
end

## As `refs`, but a program in which some functions do not check is answered too, as `agentica refs --partial` does
## (a position alone: there is no `paths`). The answer has `partial` true and the problems of those functions in
## `diagnostics`; it is complete for a function, struct, enum, alias, constant, variant or a local of a function that
## checked. A field or a builtin needs the types of every function, so for one the error is the first problem, as for
## `refs`. A program that checks gives the answer of `refs`.
export def refs_partial(session: Session, path: String, line: Int, column: Int) -> Result[Refs]
  settings = Sessions.asking(session.internal)
  if path == "" or line < 1 or column < 1
    return error(failure(Core.refused("the position is FILE, LINE and COLUMN, from line 1 and column 1", path)))
  end
  asked = QueryPosition.Asked(file: path, line: line, column: column)
  case Core.refs_partial(session.internal.cache, settings, asked)
    Core.Referenced.Done(found) -> return ok(found)
    Core.Referenced.Unreadable -> return error(failure(Core.unreadable(path)))
    Core.Referenced.Rejected(problem) -> return error(failure(Core.named(settings, problem, path)))
  end
end

## Reads back the diagnostic that is the message of an error of `outline`, `type_at`, `type_at_partial`, `symbol`,
## `refs` or `refs_partial`.
export def diagnostic(message: String) -> Result[Diagnostic]
  return DiagnosticRead.read(message)
end

## Returns the JSON that `agentica --json outline` prints, without its final line feed.
export def outline_json(found: Outline) -> Json
  return OutlineJson.json(found)
end

## Returns the JSON that `agentica --json type-at` prints, without its final line feed.
export def type_at_json(found: TypeAt) -> Json
  return TypeAtJson.json(found)
end

## Returns the JSON that `agentica --json symbol` prints, without its final line feed.
export def symbols_json(found: Symbols) -> Json
  return SymbolJson.json(found)
end

## Returns the JSON that `agentica --json refs` prints, without its final line feed.
export def refs_json(found: Refs) -> Json
  return RefsJson.json(found)
end

## Returns the JSON that `agentica --json check` prints on stderr for a problem.
export def diagnostic_json(found: Diagnostic) -> Json
  return DiagnosticJson.object(found)
end

# The settings of the machine: the disk, the process environment and the std/ sources of this binary. The version is
# empty, since nothing is written.
def settings() -> Env.Settings
  return Env.embedded_settings(Host.workspace_with(&std_source), Host.process_env(), "", false)
end

def std_source(name: String) -> Result[String]
  return Std.source(name)
end

# Looping is safe: `Core.named` changes the file only when it is the canonical path of that buffer, and a path it has
# changed is the typed name, which is not the canonical path of another buffer.
# The problem with the file of a buffer named as the session was given it, as the command line names the `--stdin`
# file.
def named_in(settings: Env.Settings, problem: Problems.Problem, buffers: List[String]) -> Problems.Problem
  shown = problem
  for typed in buffers
    shown = Core.named(settings, shown, typed)
  end
  return shown
end

# The message of the error of a problem: the diagnostic as JSON text.
def failure(problem: Problems.Problem) -> String
  return JSON.encode(DiagnosticJson.json(problem))
end
