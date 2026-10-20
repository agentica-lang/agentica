## Compiling a program for the BDD driver: the Agentica front end from a file to the bytes of its .agcb (pipeline.agc),
## with the first problem of any stage as one Problem.

import Report from "bdd_report"
import Pipeline from "../app/pipeline"
import Env from "../modules/link_env"

## Compiles the file at `path`, with `settings.version` in the header. A file that cannot be read is RUNTIME-BDD-INFRA
## with the message `unreadable`; a file that is not UTF-8 is LEX-INVALID-UTF8, in that file. Every problem names
## `path` as it was given for the root file, and the canonical path for the files it imports.
export def file(path: String, settings: Env.Settings, unreadable: String) -> Pipeline.Compiled
  case Pipeline.read_root(path)
    Pipeline.Root.Unreadable(_) ->
      return Pipeline.Compiled.Rejected(Report.located(path, "RUNTIME-BDD-INFRA", unreadable))
    Pipeline.Root.Invalid(problem) -> return Pipeline.Compiled.Rejected(problem)
    Pipeline.Root.Readable -> return Pipeline.compile(path, settings)
  end
end
