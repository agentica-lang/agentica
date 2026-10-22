## Compiling a program for the BDD driver: the Agentica front end from a file to the bytes of its .agcb (pipeline.agc),
## with the first problem of any stage as one Problem.

import Front from "../analysis/front"
import Pipeline from "../app/pipeline"
import BytecodeCache from "../io/bytecode_cache"
import Env from "../modules/link_env"
import Report from "bdd_report"

## Compiles the file at `path`, with `settings.version` in the header. A file that cannot be read is RUNTIME-BDD-INFRA
## with the message `unreadable`; a file that is not UTF-8 is LEX-INVALID-UTF8, in that file. Every problem names
## `path` as it was given for the root file, and the canonical path for the files it imports. `cached` is false for a
## file of the driver's own (the runner and the default steps), true for the user's: the bytecode cache of
## io/bytecode_cache.agc then gives the bytes of a file that did not change, and keeps the bytes of one that did.
export def file(path: String, settings: Env.Settings, unreadable: String, cached: Bool) -> Pipeline.Compiled
  plan = BytecodeCache.plan(settings, path, cached)
  case BytecodeCache.lookup(plan, settings)
    BytecodeCache.Lookup.Hit(bytes) -> return Pipeline.Compiled.Bytes(bytes)
    BytecodeCache.Lookup.Miss -> return missed(path, settings, unreadable, plan)
  end
end

def missed(path: String, settings: Env.Settings, unreadable: String, plan: BytecodeCache.Plan) -> Pipeline.Compiled
  case Front.read_root(settings.workspace, path)
    Front.Root.Unreadable(_) ->
      return Pipeline.Compiled.Rejected(Report.located(path, "RUNTIME-BDD-INFRA", unreadable))
    Front.Root.Invalid(problem) -> return Pipeline.Compiled.Rejected(problem)
    Front.Root.Readable ->
      case Front.check_file(path, settings)
        Front.Outcome.Rejected(problem) -> return Pipeline.Compiled.Rejected(problem)
        Front.Outcome.Done(front) -> return Pipeline.build_cached(front, settings, plan)
      end
  end
end
