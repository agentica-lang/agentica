## The semantic queries, once: `check`, `outline`, `type-at`, `symbol` and `refs` of docs/grammar/06b-builtins.md.
## The command line (app/cli.agc, app/cli_query.agc) and `std/analysis` (stdlib/analysis.agc, which embeds this core)
## both call these functions, so the two cannot drift.
## Each one reads its files through the Workspace of the `settings`, which is where an unsaved buffer stands in for a
## file (modules/overlay.agc), and gives the data of model.agc or the first problem. What each caller does with them is
## its own: the command line prints and sets an exit status, the library returns.

import Diag from "../diagnostics/diagnostic"
import DiagnosticModel from "../diagnostics/diagnostic_model"
import Problems from "../diagnostics/problem"
import Env from "../modules/link_env"
import Linker from "../modules/linker"
import TestFiles from "../modules/test_files"
import Workspace from "../modules/workspace"
import Outline from "../query/outline"
import PartialAt from "../query/partial_at"
import QueryFiles from "../query/query_files"
import QueryOptions from "../query/query_options"
import QueryPosition from "../query/query_position"
import Refs from "../query/refs"
import RefsName from "../query/refs_name"
import Symbol from "../query/symbol"
import SymbolLink from "../query/symbol_link"
import SymbolPaths from "../query/symbol_paths"
import TypeAt from "../query/type_at"
import SourceFile from "../syntax/source_file"
import Bodies from "bodies"
import Cache from "cache"
import Convert from "convert"
import Front from "front"
import Model from "model"
import NativeModules from "native_modules"
import Partial from "partial"

## What `check` found: the program links and checks, the file cannot be read, or the first problem.
enum Verdict
  Passed
  Unreadable
  Rejected(Problems.Problem)
end

## The outline of a file, the file cannot be read, or the first problem.
enum Outlined
  Done(Model.Outline)
  Unreadable
  Rejected(Problems.Problem)
end

## The answer for a position, the file cannot be read, or the first problem (QUERY-NO-EXPRESSION when the position is
## on no expression).
enum Typed
  Done(Model.TypeAt)
  Unreadable
  Rejected(Problems.Problem)
end

## The references for a position, the file cannot be read, or the first problem (QUERY-NO-EXPRESSION when the
## position names nothing).
enum Referenced
  Done(Model.Refs)
  Unreadable
  Rejected(Problems.Problem)
end

## The matches of a `symbol` query, or why there is none.
enum Found
  Done(Model.Symbols)
  Rejected(Problems.Problem)
end

## The `extern module` blocks of a file, the file cannot be read, or the first problem.
enum Natived
  Done(Model.NativeModules)
  Unreadable
  Rejected(Problems.Problem)
end

## The answer of `bodies`.
enum Bodied
  Done(Model.Bodies)
  Unreadable
  Rejected(Problems.Problem)
end

## Links and checks the file at `path`, as `agentica check` does: every rule of a build except that the program
## declares a `main`, so a library file passes. A test file (`*_test.agc`) is checked as one, and it and a `steps.agc`
## may import the test group of the manifest (modules/test_files.agc). `cache` (cache.agc) only saves work:
## `Cache.empty()` gives the same answer.
def check(cache: Cache.Cache, given: Env.Settings, path: String) -> Verdict
  settings = TestFiles.for_root(given, path)
  case Front.read_root(settings.workspace, path)
    Front.Root.Unreadable(_) -> Verdict.Unreadable
    Front.Root.Invalid(problem) -> Verdict.Rejected(problem)
    Front.Root.Readable ->
      case Front.query_checked(cache, path, settings)
        Front.Outcome.Rejected(problem) -> Verdict.Rejected(problem)
        Front.Outcome.Done(_) -> Verdict.Passed
      end
  end
end

## The answer of `check` as data, for the file at `path`. A file that cannot be read is QUERY-USAGE, as for the
## queries.
def checked(cache: Cache.Cache, settings: Env.Settings, path: String) -> Model.Checked
  diagnostics: List[DiagnosticModel.Diagnostic] = []
  case check(cache, settings, path)
    Verdict.Passed -> diagnostics = diagnostics
    Verdict.Unreadable -> diagnostics = [DiagnosticModel.of_problem(unreadable(path))]
    Verdict.Rejected(problem) -> diagnostics = [DiagnosticModel.of_problem(named(settings, problem, path))]
  end

  Convert.checked(QueryFiles.display(settings, path, true), diagnostics)
end

## The outline of `file`, which is lexed and parsed only: its imports need not exist. `buffered` is true when the
## Workspace of the `settings` holds a buffer as `file` (a `std/` name is then a path of the disk).
def outline(settings: Env.Settings, file: String, buffered: Bool) -> Outlined
  case QueryFiles.read(settings, file, buffered)
    SourceFile.Read.Unreadable(_) -> Outlined.Unreadable
    SourceFile.Read.Invalid(at) -> Outlined.Rejected(Front.stage_problem(file, SourceFile.invalid_utf8(at)))
    SourceFile.Read.Text(text) ->
      case Outline.of_file(settings, file, text)
        Diag.Outcome.Failed(problem) -> Outlined.Rejected(Front.stage_problem(file, problem))
        Diag.Outcome.Done(found) -> Outlined.Done(Convert.outline(QueryFiles.display(settings, file, buffered), found))
      end
  end
end

## The `extern module "NAME"` blocks of the file at `path` (never a `std/` module), linked and checked with what it
## imports and without requiring `main`, described for a code generator: native_modules.agc. `cache` only saves work.
def native_modules(cache: Cache.Cache, settings: Env.Settings, path: String) -> Natived
  settings = for_query(settings, path)
  case Front.read_root(settings.workspace, path)
    Front.Root.Unreadable(_) -> Natived.Unreadable
    Front.Root.Invalid(problem) -> Natived.Rejected(problem)
    Front.Root.Readable ->
      case Front.query_cached(cache, path, settings)
        Front.Outcome.Rejected(problem) -> Natived.Rejected(problem)
        Front.Outcome.Done(front) ->
          name = QueryFiles.display(settings, path, true)
          case NativeModules.of_program(name, front.linked, front.checked)
            Diag.Outcome.Failed(problem) -> Natived.Rejected(Front.stage_problem(path, problem))
            Diag.Outcome.Done(found) -> Natived.Done(found)
          end
      end
  end
end

## The functions of the file at `path` with their bodies as a typed tree, linked and checked with what it imports and
## without requiring `main`: bodies.agc. A `std/` name that is not a buffer (`buffered`) is the module the provider of
## the settings carries, checked as a std/ module. Experimental. `cache` only saves work.
def bodies(cache: Cache.Cache, settings: Env.Settings, path: String, buffered: Bool) -> Bodied
  settings = for_query(settings, path)
  root = path
  if QueryFiles.embedded?(path, buffered)
    root = QueryFiles.std_key(path)
    settings = settings.with(workspace: std_root(settings, path, root))
  end

  case Front.read_root(settings.workspace, root)
    Front.Root.Unreadable(_) -> Bodied.Unreadable
    Front.Root.Invalid(problem) -> Bodied.Rejected(problem)
    Front.Root.Readable ->
      case Front.query_cached(cache, root, settings)
        Front.Outcome.Rejected(problem) -> Bodied.Rejected(problem)
        Front.Outcome.Done(front) ->
          name = root
          if root == path
            name = QueryFiles.display(settings, path, true)
          end

          modules = front.linked.modules.map do |module: Linker.LinkedModule|
            shown = name
            if module.file != front.linked.modules[0].file
              shown = QueryFiles.display(settings, module.file, false)
            end

            Model.BodyModule(prefix: module.prefix, file: shown)
          end

          Bodied.Done(Bodies.of_program(name, modules, front.linked, front.checked))
      end
  end
end

## The type and the definition at the position `asked` of a file of the disk (never a `std/` module), linked and
## checked with what it imports and without requiring `main`. `cache` only saves work, as for `check`.
def type_at(cache: Cache.Cache, settings: Env.Settings, asked: QueryPosition.Asked) -> Typed
  settings = for_query(settings, asked.file)
  case position_front(cache, settings, asked, true)
    Fronted.Unreadable -> Typed.Unreadable
    Fronted.Rejected(problem) -> Typed.Rejected(problem)
    Fronted.Done(front) -> located(settings, asked, front)
  end
end

## `type_at` for a program that may not check (docs/grammar/06b-builtins.md, `--partial`). When it checks, the
## answer is the one of `type_at`. When a function fails to check, the answer is marked `partial` and holds the
## `diagnostics` of those failures: a position in a function that checked gets its type and definition, and a name in
## one that did not gets its definition after linking and no type (`type` is ""). A file that does not link, one whose
## declarations (their types, `main`, the constants) do not check, and a position in a function that did not check
## that the link cannot name are the first problem, as for `type_at`; a position on no expression is
## QUERY-NO-EXPRESSION.
def type_at_partial(cache: Cache.Cache, settings: Env.Settings, asked: QueryPosition.Asked) -> Typed
  settings = for_query(settings, asked.file)
  case partial_front(cache, settings, asked)
    Partly.Unreadable -> Typed.Unreadable
    Partly.Rejected(problem) -> Typed.Rejected(problem)
    Partly.Done(found) ->
      return located(settings, asked, found.front) if found.problems.size == 0

      case PartialAt.answer(found.front.linked, found.front.checked, found.failed, asked)
        Diag.Outcome.Failed(problem) -> Typed.Rejected(unanswered(found, asked, problem))
        Diag.Outcome.Done(answered) ->
          marked = typed_model(settings, asked, answered)
          Typed.Done(marked.with(partial: true, diagnostics: diagnostics(settings, found.problems, asked.file)))
      end
  end
end

## `refs` for a program that may not check (docs/grammar/06b-builtins.md, `--partial`). When it checks, the
## answer is the one of `refs`. When a function fails to check, the answer is marked `partial` and holds the
## `diagnostics` of those failures; it is complete for a function, struct, enum, alias, constant or variant (the
## linker resolves every use, in a function that failed too) and for a local of a function that checked. A field or a
## builtin needs the types of every function, so the answer for one is the first problem, as for `refs`; so is a
## position in a function that did not check that the link cannot name. Any other position that names nothing is
## QUERY-NO-EXPRESSION.
def refs_partial(cache: Cache.Cache, settings: Env.Settings, asked: QueryPosition.Asked) -> Referenced
  settings = for_query(settings, asked.file)
  case partial_front(cache, settings, asked)
    Partly.Unreadable -> Referenced.Unreadable
    Partly.Rejected(problem) -> Referenced.Rejected(problem)
    Partly.Done(found) ->
      return referenced(settings, asked, found.front, []) if found.problems.size == 0

      case Refs.answer(found.front.linked, found.front.checked, asked)
        Diag.Outcome.Failed(problem) -> Referenced.Rejected(unanswered(found, asked, problem))
        Diag.Outcome.Done(answered) ->
          return Referenced.Rejected(found.problems[0]) if Refs.needs_types?(answered)

          query = "#{asked.file}:#{asked.line}:#{asked.column}"
          marked = Convert.refs(query, answered, [], file_names(settings, answered))
          Referenced.Done(marked.with(partial: true, diagnostics: diagnostics(settings, found.problems, asked.file)))
      end
  end
end

## The declaration of the name at the position `asked` and every reference to it, in the file of the position (linked
## and checked as for `type_at`) and what it imports; a file that only imports it is not seen: `refs_at` adds files.
## `cache` only saves work.
def refs(cache: Cache.Cache, settings: Env.Settings, asked: QueryPosition.Asked) -> Referenced
  settings = for_query(settings, asked.file)
  case position_front(cache, settings, asked, false)
    Fronted.Unreadable -> Referenced.Unreadable
    Fronted.Rejected(problem) -> Referenced.Rejected(problem)
    Fronted.Done(front) -> referenced(settings, asked, front, [])
  end
end

## As `refs`, over the file of the position and the files and folders of `paths` too, linked together
## (`Linker.link_programs`), so a use in any of them is found. Without `paths` it is `refs`, which `cache` also saves
## the work of. A file of `paths` that does not link is left out and
## listed in `skipped`; the file of the position must link. A path that names no `*.agc` file is QUERY-USAGE with
## `usage` as the help ("" for none).
def refs_at(
  cache: Cache.Cache,
  settings: Env.Settings,
  asked: QueryPosition.Asked,
  paths: List[String],
  usage: String,
) -> Referenced
  settings = for_query(settings, asked.file)
  return refs(cache, settings, asked) if paths.size == 0

  case Front.read_root(settings.workspace, asked.file)
    Front.Root.Unreadable(_) -> Referenced.Unreadable
    Front.Root.Invalid(problem) -> Referenced.Rejected(problem)
    Front.Root.Readable ->
      case SymbolPaths.expand_from(settings.workspace, asked.file, paths, usage)
        SymbolPaths.Expanded.Refused(problem) -> Referenced.Rejected(problem)
        SymbolPaths.Expanded.Files(roots) ->
          linked = SymbolLink.link(roots, settings, cache.parses)
          case linked.program
            none -> Referenced.Rejected(linked.skipped[0].problem)
            some(program) ->
              # The file of the position is the first root: when it is left out there is nothing to ask about.
              return Referenced.Rejected(linked.skipped[0].problem) if program.modules[0].key != roots[0].key

              case Front.query_linked(program, settings)
                Front.Outcome.Rejected(problem) -> Referenced.Rejected(named_in(settings, problem, roots))
                Front.Outcome.Done(front) -> referenced(settings, asked, front, linked.skipped)
              end
          end
      end
  end
end

## Every reference to the declaration that `name` names in the modules linked from `paths` (`.` when there are none; as
## for `symbol`, `buffer` is searched first). A name that nothing declares is QUERY-NOT-FOUND and one that several
## declarations answer to is QUERY-AMBIGUOUS-NAME, with the place of each candidate in the help. A builtin is a name
## too. The program is checked as for `refs`, so an error of the program is the first problem.
def refs_named(
  cache: Cache.Cache,
  settings: Env.Settings,
  name: String,
  paths: List[String],
  buffer: String,
  usage: String,
) -> Referenced
  settings = for_query(settings, "")
  return Referenced.Rejected(QueryOptions.refusal("missing NAME or FILE:LINE:COL", usage)) if name == ""

  case SymbolPaths.expand(settings.workspace, paths, buffer, usage)
    SymbolPaths.Expanded.Refused(problem) -> Referenced.Rejected(problem)
    SymbolPaths.Expanded.Files(roots) ->
      linked = SymbolLink.link(roots, settings, cache.parses)
      case Symbol.search(name, roots, linked)
        Symbol.Outcome.Refused(problem) -> Referenced.Rejected(RefsName.not_found(name, problem))
        Symbol.Outcome.Found(found) ->
          case RefsName.pick(name, found.matches, settings)
            RefsName.Picked.Refused(problem) -> Referenced.Rejected(problem)
            RefsName.Picked.One(match) -> referenced_by_name(settings, name, match, linked, roots)
          end
      end
  end
end

## Where `name` is declared in the modules linked from the files and folders of `paths` (`.` when there are none).
## `buffer` is the FILE that the Workspace of the `settings` holds as a buffer ("" for none); it is searched first. A
## missing name and a path that names no `*.agc` file are QUERY-USAGE with `usage` as the help ("" for none), a name
## that nothing declares is QUERY-NOT-FOUND, and when no file links the answer is the first problem of the first one.
def symbol(
  cache: Cache.Cache,
  settings: Env.Settings,
  name: String,
  paths: List[String],
  buffer: String,
  usage: String,
) -> Found
  settings = for_query(settings, "")
  return Found.Rejected(QueryOptions.refusal("missing NAME", usage)) if name == ""

  case SymbolPaths.expand(settings.workspace, paths, buffer, usage)
    SymbolPaths.Expanded.Refused(problem) -> Found.Rejected(problem)
    SymbolPaths.Expanded.Files(roots) ->
      case Symbol.answer(name, roots, settings, cache.parses)
        Symbol.Outcome.Refused(problem) -> Found.Rejected(problem)
        Symbol.Outcome.Found(found) ->
          named = found.with(matches: found.matches.map do |match: Symbol.Match| shown(settings, match) end)
          Found.Done(Convert.symbols(name, named))
      end
  end
end

## The problem with the root file named as the caller wrote it (`source`): the linker knows it by its canonical path. A
## problem in another file keeps its canonical path.
def named(settings: Env.Settings, problem: Problems.Problem, source: String) -> Problems.Problem
  return problem.with(file: source) if root?(problem.file, source, settings)

  problem
end

## Whether a file that a problem names is the root file typed as `typed`. The Workspace answers for the canonical path
## of the root, which is not a file of the disk when it is a buffer.
def root?(named: String, typed: String, settings: Env.Settings) -> Bool
  return true if named == typed

  real = settings.workspace.real_path.call(typed)
  real.ok? and real.unwrap! == named
end

## The QUERY-USAGE problem of a file that cannot be read, in that file.
def unreadable(path: String) -> Problems.Problem = QueryFiles.unreadable(path, "").with(file: path)

## The QUERY-USAGE problem of a question that is wrong in itself, such as a position below line 1, put in `path`.
def refused(message: String, path: String) -> Problems.Problem = QueryOptions.refusal(message, "").with(file: path)

private

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

# `skipping` is true for a question that reads only the root file's nodes (`type-at`), which may use the cache of
# checked modules (Front.query_checked); `refs` reads the other files too.
def position_front(cache: Cache.Cache, settings: Env.Settings, asked: QueryPosition.Asked, skipping: Bool) -> Fronted
  case Front.read_root(settings.workspace, asked.file)
    Front.Root.Unreadable(_) -> Fronted.Unreadable
    Front.Root.Invalid(problem) -> Fronted.Rejected(problem)
    Front.Root.Readable ->
      case asked_front(cache, settings, asked.file, skipping)
        Front.Outcome.Rejected(problem) -> Fronted.Rejected(problem)
        Front.Outcome.Done(front) -> Fronted.Done(front)
      end
  end
end

# The workspace of `settings` in which the std/ module `typed` is a root file whose key is `key` (`std/NAME.agc`): the
# loader then reads it as it reads an import of it, and it may do what only std/ may. The folder `std` has no project.
def std_root(settings: Env.Settings, typed: String, key: String) -> Workspace.Workspace
  workspace = settings.workspace
  workspace.with(
    read_text: ->(path) { std_text(settings, typed, key, path) },
    real_path: ->(path) { std_path(workspace.real_path, key, path) },
    resolve_path: ->(path) { std_path(workspace.resolve_path, key, path) },
    file_exists: ->(path) { !path.start_with?("std/") and workspace.file_exists.call(path) },
  )
end

def std_text(settings: Env.Settings, typed: String, key: String, path: String) -> SourceFile.Read
  return QueryFiles.read(settings, typed, false) if path == key

  settings.workspace.read_text.call(path)
end

def std_path(resolve: Fn[String, Result[String]], key: String, path: String) -> Result[String]
  return ok(key) if path == key

  resolve.call(path)
end

def asked_front(cache: Cache.Cache, settings: Env.Settings, file: String, skipping: Bool) -> Front.Outcome
  return Front.query_checked(cache, file, settings) if skipping

  Front.query_cached(cache, file, settings)
end

def partial_front(cache: Cache.Cache, settings: Env.Settings, asked: QueryPosition.Asked) -> Partly
  case Front.read_root(settings.workspace, asked.file)
    Front.Root.Unreadable(_) -> Partly.Unreadable
    Front.Root.Invalid(problem) -> Partly.Rejected(problem)
    Front.Root.Readable ->
      case Partial.query_file(cache, asked.file, settings)
        Partial.Outcome.Rejected(problem) -> Partly.Rejected(problem)
        Partial.Outcome.Done(found) -> Partly.Done(found)
      end
  end
end

# Why a program with failed functions has no answer for a position: its first problem when the position is in a failed
# function and could name something there, else the position is on no expression.
def unanswered(found: Partial.Recovered, asked: QueryPosition.Asked, missed: Diag.Diagnostic) -> Problems.Problem
  return found.problems[0] if PartialAt.unclear?(found.front.linked, found.failed, asked)

  Front.stage_problem(asked.file, missed)
end

def located(settings: Env.Settings, asked: QueryPosition.Asked, front: Front.Checked) -> Typed
  case TypeAt.answer(front.linked, front.checked, asked)
    Diag.Outcome.Failed(problem) -> Typed.Rejected(Front.stage_problem(asked.file, problem))
    Diag.Outcome.Done(found) -> Typed.Done(typed_model(settings, asked, found))
  end
end

def typed_model(settings: Env.Settings, asked: QueryPosition.Asked, found: TypeAt.Answer) -> Model.TypeAt
  name = QueryFiles.display(settings, asked.file, true)
  home = QueryFiles.display(settings, TypeAt.definition_file(found), true)
  Convert.type_at(name, asked, found, home)
end

# The problems as the answer gives them: the file of the question as it was typed.
def diagnostics(
  settings: Env.Settings,
  problems: List[Problems.Problem],
  source: String,
) -> List[DiagnosticModel.Diagnostic]
  problems.map do |problem: Problems.Problem| DiagnosticModel.of_problem(named(settings, problem, source)) end
end

def referenced(
  settings: Env.Settings,
  asked: QueryPosition.Asked,
  front: Front.Checked,
  skipped: List[SymbolLink.Skipped],
) -> Referenced
  case Refs.answer(front.linked, front.checked, asked)
    Diag.Outcome.Failed(problem) -> Referenced.Rejected(Front.stage_problem(asked.file, problem))
    Diag.Outcome.Done(found) ->
      query = "#{asked.file}:#{asked.line}:#{asked.column}"
      Referenced.Done(Convert.refs(query, found, skipped, file_names(settings, found)))
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
    none -> Referenced.Rejected(linked.skipped[0].problem)
    some(program) ->
      case Front.query_linked(program, settings)
        Front.Outcome.Rejected(problem) -> Referenced.Rejected(named_in(settings, problem, roots))
        Front.Outcome.Done(front) ->
          found = Refs.of_match(front.linked, front.checked, match)
          Referenced.Done(Convert.refs(name, found, linked.skipped, file_names(settings, found)))
      end
  end
end

# The problem with a file of the roots named as it was typed: the checker knows a root by its canonical path, and a
# diagnostic keeps the name as typed (docs/grammar/06b-builtins.md), as `named` does for the one file of a
# check.
def named_in(settings: Env.Settings, problem: Problems.Problem, roots: List[SymbolPaths.Root]) -> Problems.Problem
  for root in roots
    return problem.with(file: root.typed) if root?(problem.file, root.typed, settings)
  end

  problem
end

# The name that the answer gives each file it mentions.
def file_names(settings: Env.Settings, found: Refs.Answer) -> Map[String, String]
  files: List[String] = found.references.map do |use: Refs.Reference| use.file end
  case found.definition
    some(declared) -> files = files.push(declared.file)
    none -> files = files
  end

  names: Map[String, String] = {}
  for file in files
    if !names.has_key?(file)
      names = names.put(file, QueryFiles.display(settings, file, true))
    end
  end

  names
end

# The match with the name its answer gives its file; a builtin has none.
def shown(settings: Env.Settings, match: Symbol.Match) -> Symbol.Match
  return match if match.file == ""

  match.with(file: QueryFiles.display(settings, match.file, true))
end

# The settings of a query about the file `root` ("" for a search over many files): an import or a variable that
# nothing uses yet is not an error in the file asked about, since an editor adds the name first. The files it imports
# keep the rule, and `check` keeps refusing it everywhere. A test file is read as `check` reads it, so it may import
# the test group of the manifest (modules/test_files.agc).
def for_query(settings: Env.Settings, root: String) -> Env.Settings
  TestFiles.for_root(settings, root).with(unused: false)
end
