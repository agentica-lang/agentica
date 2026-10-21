## The semantic queries, once: `check`, `outline`, `type-at`, `symbol` and `refs` of docs/future/39-semantic-cli.md.
## The command line (app/cli.agc, app/cli_query.agc) and `std/analysis` (stdlib/analysis.agc, which embeds this core)
## both call these functions, so the two cannot drift.
## Each one reads its files through the Workspace of the `settings`, which is where an unsaved buffer stands in for a
## file (modules/overlay.agc), and gives the data of model.agc or the first problem. What each caller does with them is
## its own: the command line prints and sets an exit status, the library returns.

import Ast from "../syntax/ast"
import Convert from "convert"
import Diag from "../diagnostics/diagnostic"
import DiagnosticModel from "../diagnostics/diagnostic_model"
import Env from "../modules/link_env"
import Front from "front"
import Model from "model"
import Outline from "../query/outline"
import Partial from "partial"
import PartialAt from "../query/partial_at"
import Problems from "../diagnostics/problem"
import QueryFiles from "../query/query_files"
import QueryOptions from "../query/query_options"
import QueryPosition from "../query/query_position"
import Refs from "../query/refs"
import RefsName from "../query/refs_name"
import SourceFile from "../syntax/source_file"
import Symbol from "../query/symbol"
import SymbolLink from "../query/symbol_link"
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

## The references for a position, the file cannot be read, or the first problem (QUERY-NO-EXPRESSION when the
## position names nothing).
export enum Referenced
  Done(Model.Refs)
  Unreadable
  Rejected(Problems.Problem)
end

## The matches of a `symbol` query, or why there is none.
export enum Found
  Done(Model.Symbols)
  Rejected(Problems.Problem)
end

# The file of a position, linked and checked, the file cannot be read, or the first problem.
enum Fronted
  Done(Front.Checked)
  Unreadable
  Rejected(Problems.Problem)
end

# The file of a position, linked and checked as far as it goes, the file cannot be read, or the first problem.
enum Partly
  Done(Partial.Recovered)
  Unreadable
  Rejected(Problems.Problem)
end

## Links and checks the file at `path`, as `agentica check` does: every rule of a build except that the program
## declares a `main`, so a library file passes.
export def check(settings: Env.Settings, path: String) -> Verdict
  case Front.read_root(settings.workspace, path)
    Front.Root.Unreadable(_) -> return Verdict.Unreadable
    Front.Root.Invalid(problem) -> return Verdict.Rejected(problem)
    Front.Root.Readable ->
      case Front.query_file(path, settings)
        Front.Outcome.Rejected(problem) -> return Verdict.Rejected(problem)
        Front.Outcome.Done(_) -> return Verdict.Passed
      end
  end
end

## The answer of `check` as data, for the file at `path`. A file that cannot be read is QUERY-USAGE, as for the
## queries.
export def checked(settings: Env.Settings, path: String) -> Model.Checked
  diagnostics: List[DiagnosticModel.Diagnostic] = []
  case check(settings, path)
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
## checked with what it imports and without requiring `main`.
export def type_at(settings: Env.Settings, asked: QueryPosition.Asked) -> Typed
  case position_front(settings, asked)
    Fronted.Unreadable -> return Typed.Unreadable
    Fronted.Rejected(problem) -> return Typed.Rejected(problem)
    Fronted.Done(front) -> return located(settings, asked, front)
  end
end

## `type_at` for a program that may not check (docs/future/39-semantic-cli.md, 39.6, `--partial`). When it checks, the
## answer is the one of `type_at`. When a function fails to check, the answer is marked `partial` and holds the
## `diagnostics` of those failures: a position in a function that checked gets its type and definition, and a name in
## one that did not gets its definition after linking and no type (`type` is ""). A file that does not link, one whose
## declarations (their types, `main`, the constants) do not check, and a position in a function that did not check
## that the link cannot name are the first problem, as for `type_at`; a position on no expression is
## QUERY-NO-EXPRESSION.
export def type_at_partial(settings: Env.Settings, asked: QueryPosition.Asked) -> Typed
  case partial_front(settings, asked)
    Partly.Unreadable -> return Typed.Unreadable
    Partly.Rejected(problem) -> return Typed.Rejected(problem)
    Partly.Done(found) ->
      if found.problems.size == 0
        return located(settings, asked, found.front)
      end
      case PartialAt.answer(found.front.linked, found.front.checked, found.failed, asked)
        Diag.Outcome.Failed(problem) -> return Typed.Rejected(unanswered(found, asked, problem))
        Diag.Outcome.Done(answered) ->
          marked = typed_model(settings, asked, answered)
          return Typed.Done(marked.with(partial: true, diagnostics: diagnostics(settings, found.problems, asked.file)))
      end
  end
end

## `refs` for a program that may not check (docs/future/39-semantic-cli.md, 39.6, `--partial`). When it checks, the
## answer is the one of `refs`. When a function fails to check, the answer is marked `partial` and holds the
## `diagnostics` of those failures; it is complete for a function, struct, enum, alias, constant or variant (the
## linker resolves every use, in a function that failed too) and for a local of a function that checked. A field or a
## builtin needs the types of every function, so the answer for one is the first problem, as for `refs`; so is a
## position in a function that did not check that the link cannot name. Any other position that names nothing is
## QUERY-NO-EXPRESSION.
export def refs_partial(settings: Env.Settings, asked: QueryPosition.Asked) -> Referenced
  case partial_front(settings, asked)
    Partly.Unreadable -> return Referenced.Unreadable
    Partly.Rejected(problem) -> return Referenced.Rejected(problem)
    Partly.Done(found) ->
      if found.problems.size == 0
        return referenced(settings, asked, found.front, [])
      end
      case Refs.answer(found.front.linked, found.front.checked, asked)
        Diag.Outcome.Failed(problem) -> return Referenced.Rejected(unanswered(found, asked, problem))
        Diag.Outcome.Done(answered) ->
          if Refs.needs_types?(answered)
            return Referenced.Rejected(found.problems[0])
          end
          query = "#{asked.file}:#{asked.line}:#{asked.column}"
          marked = Convert.refs(query, answered, [], file_names(settings, answered))
          return Referenced.Done(
            marked.with(partial: true, diagnostics: diagnostics(settings, found.problems, asked.file)),
          )
      end
  end
end

## The declaration of the name at the position `asked` and every reference to it, in the file of the position (linked
## and checked as for `type_at`) and what it imports. A file that only imports it is not seen: `refs_at` adds files.
export def refs(settings: Env.Settings, asked: QueryPosition.Asked) -> Referenced
  return refs_at(settings, asked, [], "")
end

## As `refs`, over the file of the position and the files and folders of `paths` too, linked together
## (`Linker.link_programs`), so a use in any of them is found. A file of `paths` that does not link is left out and
## listed in `skipped`; the file of the position must link. A path that names no `*.agc` file is QUERY-USAGE with
## `usage` as the help ("" for none).
export def refs_at(
  settings: Env.Settings,
  asked: QueryPosition.Asked,
  paths: List[String],
  usage: String,
) -> Referenced
  case Front.read_root(settings.workspace, asked.file)
    Front.Root.Unreadable(_) -> return Referenced.Unreadable
    Front.Root.Invalid(problem) -> return Referenced.Rejected(problem)
    Front.Root.Readable ->
      case SymbolPaths.expand_from(settings.workspace, asked.file, paths, usage)
        SymbolPaths.Expanded.Refused(problem) -> return Referenced.Rejected(problem)
        SymbolPaths.Expanded.Files(roots) ->
          linked = SymbolLink.link(roots, settings)
          case linked.program
            Ast.Optional.Absent -> return Referenced.Rejected(linked.skipped[0].problem)
            Ast.Optional.Present(program) ->
              # The file of the position is the first root: when it is left out there is nothing to ask about.
              if program.modules[0].key != roots[0].key
                return Referenced.Rejected(linked.skipped[0].problem)
              end
              case Front.query_linked(program, settings)
                Front.Outcome.Rejected(problem) -> return Referenced.Rejected(named_in(settings, problem, roots))
                Front.Outcome.Done(front) -> return referenced(settings, asked, front, linked.skipped)
              end
          end
      end
  end
end

## Every reference to the declaration that `name` names in the modules linked from `paths` (`.` when there are none; as
## for `symbol`, `buffer` is searched first). A name that nothing declares is QUERY-NOT-FOUND and one that several
## declarations answer to is QUERY-AMBIGUOUS-NAME, with the place of each candidate in the help. A builtin is a name
## too. The program is checked as for `refs`, so an error of the program is the first problem.
export def refs_named(
  settings: Env.Settings,
  name: String,
  paths: List[String],
  buffer: String,
  usage: String,
) -> Referenced
  if name == ""
    return Referenced.Rejected(QueryOptions.refusal("missing NAME or FILE:LINE:COL", usage))
  end
  case SymbolPaths.expand(settings.workspace, paths, buffer, usage)
    SymbolPaths.Expanded.Refused(problem) -> return Referenced.Rejected(problem)
    SymbolPaths.Expanded.Files(roots) ->
      linked = SymbolLink.link(roots, settings)
      case Symbol.search(name, roots, linked)
        Symbol.Outcome.Refused(problem) -> return Referenced.Rejected(problem)
        Symbol.Outcome.Found(found) ->
          case RefsName.pick(name, found.matches, settings)
            RefsName.Picked.Refused(problem) -> return Referenced.Rejected(problem)
            RefsName.Picked.One(match) -> return referenced_by_name(settings, name, match, linked, roots)
          end
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

def position_front(settings: Env.Settings, asked: QueryPosition.Asked) -> Fronted
  case Front.read_root(settings.workspace, asked.file)
    Front.Root.Unreadable(_) -> return Fronted.Unreadable
    Front.Root.Invalid(problem) -> return Fronted.Rejected(problem)
    Front.Root.Readable ->
      case Front.query_file(asked.file, settings)
        Front.Outcome.Rejected(problem) -> return Fronted.Rejected(problem)
        Front.Outcome.Done(front) -> return Fronted.Done(front)
      end
  end
end

def partial_front(settings: Env.Settings, asked: QueryPosition.Asked) -> Partly
  case Front.read_root(settings.workspace, asked.file)
    Front.Root.Unreadable(_) -> return Partly.Unreadable
    Front.Root.Invalid(problem) -> return Partly.Rejected(problem)
    Front.Root.Readable ->
      case Partial.query_file(asked.file, settings)
        Partial.Outcome.Rejected(problem) -> return Partly.Rejected(problem)
        Partial.Outcome.Done(found) -> return Partly.Done(found)
      end
  end
end

# Why a program with failed functions has no answer for a position: its first problem when the position is in a failed
# function and could name something there, else the position is on no expression.
def unanswered(found: Partial.Recovered, asked: QueryPosition.Asked, missed: Diag.Diagnostic) -> Problems.Problem
  if PartialAt.unclear?(found.front.linked, found.failed, asked)
    return found.problems[0]
  end
  return Front.stage_problem(asked.file, missed)
end

def located(settings: Env.Settings, asked: QueryPosition.Asked, front: Front.Checked) -> Typed
  case TypeAt.answer(front.linked, front.checked, asked)
    Diag.Outcome.Failed(problem) -> return Typed.Rejected(Front.stage_problem(asked.file, problem))
    Diag.Outcome.Done(found) -> return Typed.Done(typed_model(settings, asked, found))
  end
end

def typed_model(settings: Env.Settings, asked: QueryPosition.Asked, found: TypeAt.Answer) -> Model.TypeAt
  name = QueryFiles.display(settings, asked.file, true)
  home = QueryFiles.display(settings, TypeAt.definition_file(found), true)
  return Convert.type_at(name, asked, found, home)
end

# The problems as the answer gives them: the file of the question as it was typed.
def diagnostics(
  settings: Env.Settings,
  problems: List[Problems.Problem],
  source: String,
) -> List[DiagnosticModel.Diagnostic]
  return problems.map do |problem: Problems.Problem| DiagnosticModel.of_problem(named(settings, problem, source)) end
end

def referenced(
  settings: Env.Settings,
  asked: QueryPosition.Asked,
  front: Front.Checked,
  skipped: List[SymbolLink.Skipped],
) -> Referenced
  case Refs.answer(front.linked, front.checked, asked)
    Diag.Outcome.Failed(problem) -> return Referenced.Rejected(Front.stage_problem(asked.file, problem))
    Diag.Outcome.Done(found) ->
      query = "#{asked.file}:#{asked.line}:#{asked.column}"
      return Referenced.Done(Convert.refs(query, found, skipped, file_names(settings, found)))
  end
end

# The references to the declaration `match` of a name, once the program checks.
def referenced_by_name(
  settings: Env.Settings,
  name: String,
  match: Symbol.Match,
  linked: SymbolLink.Linked,
  roots: List[SymbolPaths.Root],
) -> Referenced
  case linked.program
    Ast.Optional.Absent -> return Referenced.Rejected(linked.skipped[0].problem)
    Ast.Optional.Present(program) ->
      case Front.query_linked(program, settings)
        Front.Outcome.Rejected(problem) -> return Referenced.Rejected(named_in(settings, problem, roots))
        Front.Outcome.Done(front) ->
          found = Refs.of_match(front.linked, front.checked, match)
          return Referenced.Done(Convert.refs(name, found, linked.skipped, file_names(settings, found)))
      end
  end
end

# The problem with a file of the roots named as it was typed: the checker knows a root by its canonical path, and a
# diagnostic keeps the name as typed (docs/future/39-semantic-cli.md, 39.4), as `named` does for the one file of a
# check.
def named_in(settings: Env.Settings, problem: Problems.Problem, roots: List[SymbolPaths.Root]) -> Problems.Problem
  for root in roots
    if root?(problem.file, root.typed, settings)
      return problem.with(file: root.typed)
    end
  end
  return problem
end

# The name that the answer gives each file it mentions.
def file_names(settings: Env.Settings, found: Refs.Answer) -> Map[String, String]
  files: List[String] = found.references.map do |use: Refs.Reference| use.file end
  case found.definition
    Ast.Optional.Present(declared) -> files = files.push(declared.file)
    Ast.Optional.Absent -> files = files
  end
  names: Map[String, String] = {}
  for file in files
    if !names.has_key?(file)
      names = names.put(file, QueryFiles.display(settings, file, true))
    end
  end
  return names
end

# The match with the name its answer gives its file; a builtin has none.
def shown(settings: Env.Settings, match: Symbol.Match) -> Symbol.Match
  if match.file == ""
    return match
  end
  return match.with(file: QueryFiles.display(settings, match.file, true))
end
