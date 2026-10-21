## Linking and checking for the answers of a program that does not check (docs/future/39-semantic-cli.md, 39.6, the
## option `--partial`). A function whose body fails to check does not stop the run (`Checker.check_recovering`), so
## what the other functions have, the queries can still use. A program that does not link, or whose declarations do
## not register, has nothing to answer from beyond the first problem.

import Checker from "../check/checker"
import Env from "../modules/link_env"
import Front from "front"
import Linker from "../modules/linker"
import Problems from "../diagnostics/problem"

## The program and the problems of its functions: none when it checks, so the answers are complete.
export struct Recovered
  front: Front.Checked
  problems: List[Problems.Problem]
end

## The program linked and checked as far as it goes, or the first problem of a program that does not link.
export enum Outcome
  Done(Recovered)
  Rejected(Problems.Problem)
end

## Links the file at `path` and checks it as `Front.query_file` does, except that a failed function body is kept as a
## problem. `problems` is empty exactly when `Front.query_file` gives Done.
export def query_file(path: String, settings: Env.Settings) -> Outcome
  case Linker.link_file(path, settings)
    Linker.Linking.Failed(failure) -> return Outcome.Rejected(Front.link_problem(failure))
    Linker.Linking.Done(linked) ->
      found = Checker.check_recovering(linked, settings)
      return Outcome.Done(
        Recovered(front: Front.Checked(linked: linked, checked: found.checked), problems: found.problems),
      )
  end
end
