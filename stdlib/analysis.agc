## Asks the questions of `agentica check`, `outline` and `type-at` from a program, and gets the answers as data.
##
## Import it with `import Analysis from "std/analysis"`. A `Session` holds the working folder (the disk) and the text
## of the files an editor has open and not saved: `Analysis.update` puts a buffer in a new session, `Analysis.close`
## takes it out, and a question reads the files of the disk except those with a buffer. The answers are plain structs,
## with no enum: the shapes of the `--json` forms (an absent text is `""`, and an absent definition is an empty list).
## The command line runs the same code, so `Analysis.outline_json` and `Analysis.type_at_json` give byte for byte what
## `agentica --json outline` and `type-at` print, and `Analysis.diagnostic_json` what `--json check` prints on stderr.
##
## `outline` and `type_at` return a `Result`: its error message is the diagnostic as one JSON object, the form of
## `--json`, and `Analysis.diagnostic` reads it back, so `try` works. The codes are those of the command line (`LEX-`,
## `PARSE-`, `CHECK-`, `PKG-`, and `QUERY-USAGE` for a file that cannot be read or a position below line 1 or column 1,
## `QUERY-NO-EXPRESSION`).
##
## The compiler is part of the program that imports this module (as the private `std/internal/compiler`), so a program
## that imports it pays the compile time of the compiler's core once, and it asks the checker that this binary carries.
## A session is a value: tasks may ask one session at once, and an `update` in one task leaves the others' copy as it
## was.

import Core from "std/internal/compiler/analysis/analysis"
import DiagnosticJson from "std/internal/compiler/diagnostics/diagnostic_json"
import DiagnosticModel from "std/internal/compiler/diagnostics/diagnostic_model"
import DiagnosticRead from "std/internal/compiler/diagnostics/diagnostic_read"
import Env from "std/internal/compiler/modules/link_env"
import Host from "std/internal/compiler/io/host"
import Model from "std/internal/compiler/analysis/model"
import OutlineJson from "std/internal/compiler/query/outline_json"
import Problems from "std/internal/compiler/diagnostics/problem"
import QueryPosition from "std/internal/compiler/query/query_position"
import Sessions from "std/internal/compiler/analysis/session"
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

## Returns the workspace of the disk, with no buffer.
export def workspace() -> Workspace
  none: Map[String, String] = {}
  return Workspace(version: 1, buffers: none)
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

## Returns the answer of `agentica check` for the file `path`: it links and checks the program, and its `diagnostics`
## hold the first problem, if any. A file that cannot be read is a `QUERY-USAGE` diagnostic.
export def check(session: Session, path: String) -> Checked
  return Core.checked(Sessions.asking(session.internal), path)
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
  case Core.type_at(settings, QueryPosition.Asked(file: path, line: line, column: column))
    Core.Typed.Done(found) -> return ok(found)
    Core.Typed.Unreadable -> return error(failure(Core.unreadable(path)))
    Core.Typed.Rejected(problem) -> return error(failure(Core.named(settings, problem, path)))
  end
end

## Reads back the diagnostic that is the message of an error of `outline` or `type_at`.
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

# The message of the error of a problem: the diagnostic as JSON text.
def failure(problem: Problems.Problem) -> String
  return JSON.encode(DiagnosticJson.json(problem))
end
