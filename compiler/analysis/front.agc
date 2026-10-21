## The first stages of every command that reads a program: read the root file, link it and check it, each giving the
## data of the next stage or the first problem. The command line (app/), the BDD driver and the queries (analysis.agc)
## all run it, so what one of them accepts, the others accept.

import Cache from "cache"
import Checker from "../check/checker"
import Diag from "../diagnostics/diagnostic"
import Env from "../modules/link_env"
import Failure from "../modules/link_failure"
import Linker from "../modules/linker"
import Modules from "../modules/modules"
import Problems from "../diagnostics/problem"
import SourceFile from "../syntax/source_file"
import Workspace from "../modules/workspace"

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
    Cache.Found.Hit(root) -> return checked_outcome(root.linked, root.checking)
    Cache.Found.Miss -> return link_loaded(walked.unwrap!, settings, false)
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
    Cache.Found.Hit(root) -> return Cache.remember(reaching, root, loaded, false)
    Cache.Found.Miss -> return solve(cache, reaching, loaded, settings)
  end
end

def front(path: String, settings: Env.Settings, main_required: Bool) -> Outcome
  case Linker.link_file(path, settings)
    Linker.Linking.Failed(failure) -> return Outcome.Rejected(link_problem(failure))
    Linker.Linking.Done(linked) -> return check(linked, settings, main_required)
  end
end

def link_loaded(loaded: Modules.Loaded, settings: Env.Settings, main_required: Bool) -> Outcome
  case Linker.link_loaded(loaded, settings)
    Linker.Linking.Failed(failure) -> return Outcome.Rejected(link_problem(failure))
    Linker.Linking.Done(program) -> return check(program, settings, main_required)
  end
end

# Links and checks the modules of a refresh, as query_file does, and keeps the result in `reaching`, which is `cache`
# with the parsed files of this walk. A program that does not link leaves `cache` as it was.
def solve(cache: Cache.Cache, reaching: Cache.Cache, loaded: Modules.Loaded, settings: Env.Settings) -> Cache.Cache
  case Linker.link_loaded(loaded, settings)
    Linker.Linking.Failed(_) -> return cache
    Linker.Linking.Done(program) ->
      root = Cache.solved(loaded, program, Checker.check_query(program, settings))
      return Cache.remember(reaching, root, loaded, true)
  end
end

def check(linked: Linker.Linked, settings: Env.Settings, main_required: Bool) -> Outcome
  if main_required
    return checked_outcome(linked, Checker.check(linked, settings))
  end
  return checked_outcome(linked, Checker.check_query(linked, settings))
end

def checked_outcome(linked: Linker.Linked, checking: Checker.Checking) -> Outcome
  case checking
    Checker.Checking.Failed(problem) -> return Outcome.Rejected(problem)
    Checker.Checking.Done(checked) -> return Outcome.Done(Checked(linked: linked, checked: checked))
  end
end
