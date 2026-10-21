## The semantic queries, once: `check`, `outline`, `type-at` and `symbol` of docs/future/39-semantic-cli.md. The
## command line (app/cli.agc, app/cli_query.agc) and `std/analysis` (stdlib/analysis.agc, which embeds this core) both
## call these functions, so the two cannot drift (`symbol` has no function in `std/analysis` yet). Each one reads its
## files through the Workspace of the `settings`, which is where an unsaved buffer stands in for a file
## (modules/overlay.agc), and gives the data of model.agc or the first problem. What each caller does with them is its
## own: the command line prints and sets an exit status, the library returns.

import Cache from "cache"
import Convert from "convert"
import Diag from "../diagnostics/diagnostic"
import DiagnosticModel from "../diagnostics/diagnostic_model"
import Env from "../modules/link_env"
import Front from "front"
import Model from "model"
import Outline from "../query/outline"
import Problems from "../diagnostics/problem"
import QueryFiles from "../query/query_files"
import QueryOptions from "../query/query_options"
import QueryPosition from "../query/query_position"
import SourceFile from "../syntax/source_file"
import Symbol from "../query/symbol"
import SymbolPaths from "../query/symbol_paths"
import TypeAt from "../query/type_at"

## What `check` found: the program links and checks, the file cannot be read, or the first problem.
export enum Verdict
  Passed
  Unreadable
  Rejected(Problems.Problem)
end

## The outline of a file, the file cannot be read, or the first problem.
export enum Outlined
  Done(Model.Outline)
  Unreadable
  Rejected(Problems.Problem)
end

## The answer for a position, the file cannot be read, or the first problem (QUERY-NO-EXPRESSION when the position is
## on no expression).
export enum Typed
  Done(Model.TypeAt)
  Unreadable
  Rejected(Problems.Problem)
end

## The matches of a `symbol` query, or why there is none.
export enum Found
  Done(Model.Symbols)
  Rejected(Problems.Problem)
end

## Links and checks the file at `path`, as `agentica check` does: every rule of a build except that the program
## declares a `main`, so a library file passes. `cache` (cache.agc) only saves work: `Cache.empty()` gives the same
## answer.
export def check(cache: Cache.Cache, settings: Env.Settings, path: String) -> Verdict
  case Front.read_root(settings.workspace, path)
    Front.Root.Unreadable(_) -> return Verdict.Unreadable
    Front.Root.Invalid(problem) -> return Verdict.Rejected(problem)
    Front.Root.Readable ->
      case Front.query_cached(cache, path, settings)
        Front.Outcome.Rejected(problem) -> return Verdict.Rejected(problem)
        Front.Outcome.Done(_) -> return Verdict.Passed
      end
  end
end

## The answer of `check` as data, for the file at `path`. A file that cannot be read is QUERY-USAGE, as for the
## queries.
export def checked(cache: Cache.Cache, settings: Env.Settings, path: String) -> Model.Checked
  diagnostics: List[DiagnosticModel.Diagnostic] = []
  case check(cache, settings, path)
    Verdict.Passed -> diagnostics = diagnostics
    Verdict.Unreadable -> diagnostics = [DiagnosticModel.of_problem(unreadable(path))]
    Verdict.Rejected(problem) -> diagnostics = [DiagnosticModel.of_problem(named(settings, problem, path))]
  end
  return Convert.checked(QueryFiles.display(settings, path, true), diagnostics)
end

## The outline of `file`, which is lexed and parsed only: its imports need not exist. `buffered` is true when the
## Workspace of the `settings` holds a buffer as `file` (a `std/` name is then a path of the disk).
export def outline(settings: Env.Settings, file: String, buffered: Bool) -> Outlined
  case QueryFiles.read(settings, file, buffered)
    SourceFile.Read.Unreadable(_) -> return Outlined.Unreadable
    SourceFile.Read.Invalid(at) -> return Outlined.Rejected(Front.stage_problem(file, SourceFile.invalid_utf8(at)))
    SourceFile.Read.Text(text) ->
      case Outline.of_text(text)
        Diag.Outcome.Failed(problem) -> return Outlined.Rejected(Front.stage_problem(file, problem))
        Diag.Outcome.Done(found) ->
          return Outlined.Done(Convert.outline(QueryFiles.display(settings, file, buffered), found))
      end
  end
end

## The type and the definition at the position `asked` of a file of the disk (never a `std/` module), linked and
## checked with what it imports and without requiring `main`. `cache` only saves work, as for `check`.
export def type_at(cache: Cache.Cache, settings: Env.Settings, asked: QueryPosition.Asked) -> Typed
  case Front.read_root(settings.workspace, asked.file)
    Front.Root.Unreadable(_) -> return Typed.Unreadable
    Front.Root.Invalid(problem) -> return Typed.Rejected(problem)
    Front.Root.Readable ->
      case Front.query_cached(cache, asked.file, settings)
        Front.Outcome.Rejected(problem) -> return Typed.Rejected(problem)
        Front.Outcome.Done(front) -> return located(settings, asked, front)
      end
  end
end

## Where `name` is declared in the modules linked from the files and folders of `paths` (`.` when there are none).
## `buffer` is the FILE that the Workspace of the `settings` holds as a buffer ("" for none); it is searched first. A
## missing name and a path that names no `*.agc` file are QUERY-USAGE with `usage` as the help ("" for none), a name
## that nothing declares is QUERY-NOT-FOUND, and when no file links the answer is the first problem of the first one.
export def symbol(settings: Env.Settings, name: String, paths: List[String], buffer: String, usage: String) -> Found
  if name == ""
    return Found.Rejected(QueryOptions.refusal("missing NAME", usage))
  end
  case SymbolPaths.expand(settings.workspace, paths, buffer, usage)
    SymbolPaths.Expanded.Refused(problem) -> return Found.Rejected(problem)
    SymbolPaths.Expanded.Files(roots) ->
      case Symbol.answer(name, roots, settings)
        Symbol.Outcome.Refused(problem) -> return Found.Rejected(problem)
        Symbol.Outcome.Found(found) ->
          named = found.with(matches: found.matches.map do |match: Symbol.Match| shown(settings, match) end)
          return Found.Done(Convert.symbols(name, named))
      end
  end
end

## The problem with the root file named as the caller wrote it (`source`): the linker knows it by its canonical path. A
## problem in another file keeps its canonical path.
export def named(settings: Env.Settings, problem: Problems.Problem, source: String) -> Problems.Problem
  if root?(problem.file, source, settings)
    return problem.with(file: source)
  end
  return problem
end

## Whether a file that a problem names is the root file typed as `typed`. The Workspace answers for the canonical path
## of the root, which is not a file of the disk when it is a buffer.
export def root?(named: String, typed: String, settings: Env.Settings) -> Bool
  if named == typed
    return true
  end
  real = settings.workspace.real_path.call(typed)
  return real.ok? and real.unwrap! == named
end

## The QUERY-USAGE problem of a file that cannot be read, in that file.
export def unreadable(path: String) -> Problems.Problem
  return QueryFiles.unreadable(path, "").with(file: path)
end

## The QUERY-USAGE problem of a question that is wrong in itself, such as a position below line 1, put in `path`.
export def refused(message: String, path: String) -> Problems.Problem
  return QueryOptions.refusal(message, "").with(file: path)
end

def located(settings: Env.Settings, asked: QueryPosition.Asked, front: Front.Checked) -> Typed
  case TypeAt.answer(front.linked, front.checked, asked)
    Diag.Outcome.Failed(problem) -> return Typed.Rejected(Front.stage_problem(asked.file, problem))
    Diag.Outcome.Done(found) ->
      name = QueryFiles.display(settings, asked.file, true)
      home = QueryFiles.display(settings, TypeAt.definition_file(found), true)
      return Typed.Done(Convert.type_at(name, asked, found, home))
  end
end

# The match with the name its answer gives its file; a builtin has none.
def shown(settings: Env.Settings, match: Symbol.Match) -> Symbol.Match
  if match.file == ""
    return match
  end
  return match.with(file: QueryFiles.display(settings, match.file, true))
end
