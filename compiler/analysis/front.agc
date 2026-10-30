## The first stages of every command that reads a program: read the root file, link it and check it, each giving the
## data of the next stage or the first problem. The command line (app/), the BDD driver and the queries (analysis.agc)
## all run it, so what one of them accepts, the others accept.

import Checker from "../check/checker"
import Style from "../check/check_style"
import Diag from "../diagnostics/diagnostic"
import Problems from "../diagnostics/problem"
import Env from "../modules/link_env"
import Failure from "../modules/link_failure"
import Linker from "../modules/linker"
import CheckCache from "../modules/check_cache"
import Modules from "../modules/modules"
import TypeCode from "../modules/type_code"
import Workspace from "../modules/workspace"
import Ast from "../syntax/ast"
import SourceFile from "../syntax/source_file"
import T from "../syntax/types"
import Cache from "cache"

# No file is known to follow the style rule: every file of a project that asks for it is looked at.
NO_STYLED: Set[String] = Set.new([])

## What the root file is: it can be read as UTF-8, it cannot be read (the system's message), or it is not UTF-8
## (LEX-INVALID-UTF8, in that file).
export enum Root
  Readable
  Unreadable(String)
  Invalid(Problems.Problem)
end

## A program that linked and checked: what lowering, `--dump` and the diagnostics' source text read.
export struct Checked
  linked: Linker.Linked
  checked: Checker.Checked
end

## The result of linking and checking: the program, or the first problem.
export enum Outcome
  Done(Checked)
  Rejected(Problems.Problem)
end

## Reads the root file once through `workspace`, so a file that cannot be read or decoded is told apart from a problem
## of the program. The linker reads it again; every problem names `path` as it was given.
export def read_root(workspace: Workspace.Workspace, path: String) -> Root
  case workspace.read_text.call(path)
    SourceFile.Read.Unreadable(message) -> return Root.Unreadable(message)
    SourceFile.Read.Invalid(at) -> return Root.Invalid(stage_problem(path, SourceFile.invalid_utf8(at)))
    SourceFile.Read.Text(_) -> return Root.Readable
  end
end

## The problem of a stage that has no file of its own (the lexer and the parser), put in `file`.
export def stage_problem(file: String, problem: Diag.Diagnostic) -> Problems.Problem
  return Problems.problem(file, "", problem.code, problem.message, problem.span, problem.help)
end

## The problem of a linker failure: the diagnostic in its file, or at a key of agentica.toml or agentica.lock.
export def link_problem(failure: Failure.Failure) -> Problems.Problem
  return stage_problem(failure.file, failure.diagnostic).with(key_path: failure.key_path)
end

## Links the file at `path` and checks it.
export def check_file(path: String, settings: Env.Settings) -> Outcome
  return front(path, settings, true)
end

## Links the file at `path` and checks it as `agentica check` and `agentica type-at` do: every rule of `check_file`
## except that the program declares a `main`, so a library file passes. A `main` that is declared keeps its signature.
export def query_file(path: String, settings: Env.Settings) -> Outcome
  return query_cached(Cache.empty(), path, settings)
end

## Like `query_file`, using the program that `cache` holds for the file when the modules it reads are the ones the
## program was made from. The modules are read and walked again either way, so the answer is the one `query_file`
## gives; `cache` only saves parsing the files that did not change and linking and checking a program that did not
## change.
export def query_cached(cache: Cache.Cache, path: String, settings: Env.Settings) -> Outcome
  walked = Modules.load_with(path, settings, cache.parses)
  if !walked.ok?
    return Outcome.Rejected(link_problem(Failure.unpack_failure(walked.message)))
  end

  case Cache.find(cache, walked.unwrap!)
    Cache.Found.Hit(root) -> return stored_outcome(root)
    Cache.Found.Miss -> return link_reusing(cache, walked.unwrap!, settings)
  end
end

## Like `query_cached` for a question that only reads the types of the root file (`check`, `type-at`), using the cache
## of checked modules of the workspace (modules/check_cache.agc) when it is on and `cache` holds nothing. The modules
## whose tree the cache vouches for are loaded from their stubs and their function bodies are not checked, so the types
## of their nodes are Unknown; nothing but the root file's nodes may be read from the result. The answer, the first
## problem included, is the one `query_cached` gives: a problem is only given when it is in a file that was read in
## full, and a walk in which a stub is not vouched for is made again without stubs. After a program that checks, the
## modules that were checked in full are entered in the cache.
export def query_checked(cache: Cache.Cache, path: String, settings: Env.Settings) -> Outcome
  if !settings.workspace.check_cache.on or cache.roots.size > 0 or cache.parses.kept.size > 0
    return query_cached(cache, path, settings)
  end

  first = Modules.load_checked(path, settings, true)
  if !first.ok?
    return query_cached(cache, path, settings)
  end

  loaded = first.unwrap!
  if unvouched?(loaded)
    second = Modules.load_checked(path, settings, false)
    if !second.ok?
      return query_cached(cache, path, settings)
    end

    loaded = second.unwrap!
  end

  case Linker.link_loaded(loaded, settings)
    Linker.Linking.Failed(failure) ->
      if stand_in?(loaded, failure.file)
        return query_cached(cache, path, settings)
      end

      return Outcome.Rejected(link_problem(failure))
    Linker.Linking.Done(program) -> return skipped(cache, path, settings, loaded, program)
  end
end

## `cache` with the program of the file at `path` linked and checked as `query_file` does, so the questions that follow
## find it. When the file cannot be loaded or linked, `cache` is returned as it was: the question will say why. A
## program that does not check is kept with its first problem. The cache is the one of the session that the caller
## refreshes; two refreshes of one cache give two caches, and the caller keeps one (stdlib/analysis.agc).
export def refresh(cache: Cache.Cache, path: String, settings: Env.Settings) -> Cache.Cache
  walked = Modules.load_with(path, settings, cache.parses)
  if !walked.ok?
    return cache
  end

  loaded = walked.unwrap!
  reaching = Cache.reaching(cache, loaded)
  if Cache.crowded?(reaching)
    again = Modules.load_with(path, settings, Modules.no_parses())
    if !again.ok?
      return cache
    end

    loaded = again.unwrap!
    reaching = Cache.restart(cache, loaded)
  end

  case Cache.find(cache, loaded)
    Cache.Found.Hit(root) -> return Cache.remember(reaching, root, loaded, false, 0)
    Cache.Found.Miss -> return solve(cache, reaching, loaded, settings)
  end
end

## Checks `linked`, a program that `Linker.link_programs` made from several files, as `query_file` does.
export def query_linked(linked: Linker.Linked, settings: Env.Settings) -> Outcome
  return check(linked, settings, false)
end

## The first style problem of a linked program: the files whose project asks for a rule that they break. Absent when
## none does. The style rules come after the type check, so a program that does not check reports that first.
export def style_problem(linked: Linker.Linked) -> Ast.Maybe[Problems.Problem]
  return Style.blank_line_after_end(linked, NO_STYLED)
end

def front(path: String, settings: Env.Settings, main_required: Bool) -> Outcome
  case Linker.link_file(path, settings)
    Linker.Linking.Failed(failure) -> return Outcome.Rejected(link_problem(failure))
    Linker.Linking.Done(linked) -> return check(linked, settings, main_required)
  end
end

# Links the modules of a walk and checks them as query_file does, taking from the last good program of the root in
# `cache` what its unchanged modules left (Cache.reusing).
def link_reusing(cache: Cache.Cache, loaded: Modules.Loaded, settings: Env.Settings) -> Outcome
  case Linker.link_loaded(loaded, settings)
    Linker.Linking.Failed(failure) -> return Outcome.Rejected(link_problem(failure))
    Linker.Linking.Done(program) ->
      rechecked = check_reusing(Cache.reusing(cache, loaded), program, settings)
      return checked_outcome(program, rechecked.checking, NO_STYLED)
  end
end

# The result of checking `program` as query_file does, taking what `reusing` says is unchanged from an earlier check,
# and the number of modules it took.
def check_reusing(
  reusing: Ast.Maybe[Checker.Reusing],
  program: Linker.Linked,
  settings: Env.Settings,
) -> Checker.Rechecked
  case reusing
    Ast.Maybe.Present(found) -> return Checker.check_query_reusing(program, settings, found)
    Ast.Maybe.Absent -> return Checker.Rechecked(checking: Checker.check_query(program, settings), taken: 0)
  end
end

# Links and checks the modules of a refresh, as query_file does, and keeps the result in `reaching`, which is `cache`
# with the parsed files of this walk. A program that does not link leaves `cache` as it was.
def solve(cache: Cache.Cache, reaching: Cache.Cache, loaded: Modules.Loaded, settings: Env.Settings) -> Cache.Cache
  case Linker.link_loaded(loaded, settings)
    Linker.Linking.Failed(_) -> return cache
    Linker.Linking.Done(program) ->
      reusing = Cache.reusing(cache, loaded)
      rechecked = check_reusing(reusing, program, settings)
      style = style_after(rechecked.checking, program, NO_STYLED)
      root = Cache.solved(loaded, program, rechecked.checking, style, Cache.held(cache, loaded))
      return Cache.remember(reaching, root, loaded, true, rechecked.taken)
  end
end

# Checks a program that was linked from a walk of the check cache, and enters its modules in the cache when it checks.
def skipped(
  cache: Cache.Cache,
  path: String,
  settings: Env.Settings,
  loaded: Modules.Loaded,
  program: Linker.Linked,
) -> Outcome
  clean: List[String] = []
  constants: Map[String, T.Type] = {}
  for key in loaded.order
    module = loaded.modules[key]
    if module.clean
      clean = clean.push(key)
      for name in module.constants.keys
        constants = constants.put(name, module.constants[name])
      end
    end
  end

  checking = Checker.check_query_taking(program, settings, Set.new(clean), constants)
  case checking
    Checker.Checking.Failed(problem) ->
      if stand_in?(loaded, problem.file)
        return query_cached(cache, path, settings)
      end

      return Outcome.Rejected(problem)
    Checker.Checking.Done(checked) ->
      # A module read from its stub keeps its text, so the style rules see every file; one whose entry says its text
      # follows the rule is not lexed again.
      styled = styled_files(loaded)
      enter_checked(loaded, checked, settings, styled)
      return checked_outcome(program, checking, styled)
  end
end

# The files of the walk whose text follows the style rule blank_line_after_end: those whose entry says so, and those of
# a project that asks for the rule which are looked at now.
def styled_files(loaded: Modules.Loaded) -> Set[String]
  files: List[String] = []
  for key in loaded.order
    module = loaded.modules[key]
    if module.styled or (module.origin.blank_line_after_end and Style.follows_rule?(module.file, module.text))
      files = files.push(module.file)
    end
  end

  return Set.new(files)
end

# Whether some stub of the walk is not vouched for: its module is parsed from a stub but its bodies are not known to be
# fine for this tree.
def unvouched?(loaded: Modules.Loaded) -> Bool
  return loaded.modules.values.any? do |module: Modules.Module| module.stubbed and !module.clean end
end

# Whether `file` is one that the walk parsed from a stub: a problem there could come from the stub, so it is not given.
def stand_in?(loaded: Modules.Loaded, file: String) -> Bool
  return loaded.stubs > 0 and loaded.modules.values.any? do |module: Modules.Module|
    module.stubbed and module.file == file
  end
end

# Enters in the cache every module of a program that checked, but the root, whose entry does not vouch for its tree
# yet. A module that is clean has its entry already.
def enter_checked(
  loaded: Modules.Loaded,
  checked: Checker.Checked,
  settings: Env.Settings,
  styled: Set[String],
) -> Void
  keys: Map[String, String] = {}
  for key in loaded.order
    keys = keys.put(loaded.modules[key].prefix, key)
  end

  for key in loaded.order.drop(1)
    module = loaded.modules[key]
    if module.digest == "" or module.clean
      next
    end

    stub = ""
    case CheckCache.stub_of(module.text, module.program)
      Ast.Maybe.Present(found) -> stub = found
      Ast.Maybe.Absent -> stub = stub
    end

    constants = coded_constants(module, checked, keys)
    # Without the types of all its constants a module is never clean, so its stub would not be used either.
    if constants.ok?
      CheckCache.store(
        settings.workspace.check_cache,
        key,
        module.digest,
        CheckCache.Entry(
          tree: module.tree,
          styled: styled.include?(module.file),
          stub: stub,
          constants: constants.unwrap!,
        ),
      )
    end
  end
end

# The type of each constant of `module` that `checked` recorded, as type_code.agc writes it, by the name the module
# declares it with.
def coded_constants(
  module: Modules.Module,
  checked: Checker.Checked,
  keys: Map[String, String],
) -> Result[Map[String, String]]
  found: Map[String, String] = {}
  for name in CheckCache.constant_names(module.program)
    linked = module.prefix + name
    if !checked.constant_types.has_key?(linked)
      return error("the check recorded no type for #{linked}")
    end

    found = found.put(name, try TypeCode.encode(checked.constant_types[linked], keys))
  end

  return ok(found)
end

def check(linked: Linker.Linked, settings: Env.Settings, main_required: Bool) -> Outcome
  if main_required
    return checked_outcome(linked, Checker.check(linked, settings), NO_STYLED)
  end

  return checked_outcome(linked, Checker.check_query(linked, settings), NO_STYLED)
end

# A program that checked still has to follow the style rules of its project (check_style.agc).
def checked_outcome(
  linked: Linker.Linked,
  checking: Checker.Checking,
  styled: Set[String],
) -> Outcome
  return finished(linked, checking, style_after(checking, linked, styled))
end

# The outcome for a root that the cache holds: its style problem was found when it was made, from the same texts and
# the same projects (Cache.find compares both), so the modules are not lexed again.
def stored_outcome(root: Cache.Root) -> Outcome
  return finished(root.linked, root.checking, root.style)
end

# The style problem of `linked`, looked for only when it checked: a type error is reported first.
def style_after(
  checking: Checker.Checking,
  linked: Linker.Linked,
  styled: Set[String],
) -> Ast.Maybe[Problems.Problem]
  case checking
    Checker.Checking.Failed(_) -> return Ast.Maybe.Absent
    Checker.Checking.Done(_) -> return Style.blank_line_after_end(linked, styled)
  end
end

def finished(linked: Linker.Linked, checking: Checker.Checking, style: Ast.Maybe[Problems.Problem]) -> Outcome
  case checking
    Checker.Checking.Failed(problem) -> return Outcome.Rejected(problem)
    Checker.Checking.Done(checked) ->
      case style
        Ast.Maybe.Present(problem) -> return Outcome.Rejected(problem)
        Ast.Maybe.Absent -> return Outcome.Done(Checked(linked: linked, checked: checked))
      end
  end
end
