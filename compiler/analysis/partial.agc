## Linking and checking for the answers of a program that does not check (docs/future/39-semantic-cli.md, 39.6, the
## option `--partial`). A function whose body fails to check does not stop the run (`Checker.check_recovering`), so
## what the other functions have, the queries can still use. A program that does not link, or whose declarations do
## not check (their types, `main`, the constants), has nothing to answer from beyond the first problem.

import Cache from "cache"
import Checker from "../check/checker"
import Env from "../modules/link_env"
import Failure from "../modules/link_failure"
import Front from "front"
import Linker from "../modules/linker"
import Modules from "../modules/modules"
import Problems from "../diagnostics/problem"

## The program, the problems of its functions that did not check and the linked names of those functions: none when
## the program checks, so the answers are complete.
export struct Recovered
  front: Front.Checked
  problems: List[Problems.Problem]
  failed: List[String]
end

## The program linked and checked as far as it goes, or the first problem of a program that does not link or whose
## declarations (their types, `main`, the constants) do not check.
export enum Outcome
  Done(Recovered)
  Rejected(Problems.Problem)
end

## Links the file at `path` and checks it as `Front.query_file` does, except that a failed function body is kept as a
## problem. `problems` is empty exactly when `Front.query_file` gives Done. A program that `cache` holds as checked
## (same modules and texts, see Front.query_cached) is not checked again; one it holds as failed is, since the cache
## keeps only the first problem.
export def query_file(cache: Cache.Cache, path: String, settings: Env.Settings) -> Outcome
  walked = Modules.load_with(path, settings, cache.parses)
  if !walked.ok?
    return Outcome.Rejected(Front.link_problem(Failure.unpack_failure(walked.message)))
  end
  case Cache.find(cache, walked.unwrap!)
    Cache.Found.Hit(root) -> return reused(root, settings)
    Cache.Found.Miss -> return linked(walked.unwrap!, settings)
  end
end

def reused(root: Cache.Root, settings: Env.Settings) -> Outcome
  case root.checking
    Checker.Checking.Done(checked) ->
      front = Front.Checked(linked: root.linked, checked: checked)
      return Outcome.Done(Recovered(front: front, problems: [], failed: []))
    Checker.Checking.Failed(_) -> return recovered(root.linked, settings)
  end
end

def linked(loaded: Modules.Loaded, settings: Env.Settings) -> Outcome
  case Linker.link_loaded(loaded, settings)
    Linker.Linking.Failed(failure) -> return Outcome.Rejected(Front.link_problem(failure))
    Linker.Linking.Done(program) -> return recovered(program, settings)
  end
end

def recovered(program: Linker.Linked, settings: Env.Settings) -> Outcome
  case Checker.check_recovering(program, settings)
    Checker.Recovering.Failed(problem) -> return Outcome.Rejected(problem)
    Checker.Recovering.Done(found) ->
      front = Front.Checked(linked: program, checked: found.checked)
      return Outcome.Done(Recovered(front: front, problems: found.problems, failed: found.failed))
  end
end
