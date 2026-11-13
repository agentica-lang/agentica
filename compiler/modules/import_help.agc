## The help of an unknown import name: the "did you mean" of the linker.

import Diag from "../diagnostics/diagnostic"
import Suggest from "../syntax/suggest"
import Declarations from "declarations"

## The help of CHECK-IMPORT-NAME for member, which the module key does not export: the fixed text for the std/logger
## error, or the did-you-mean over the exports (a private name is never suggested).
def unknown_import_help(key: String, exports: Map[String, Declarations.Kind], member: String) -> Diag.Help
  if key == "std/logger.agc" and member == "error"
    return Diag.Help.Hint("the function for the error level is Logger.err; error is a reserved name")
  end

  case Suggest.closest_among(member, exports.keys, [])
    some(name) -> Diag.Help.Hint("did you mean \"#{name}\"?")
    none -> Diag.Help.NoHelp
  end
end
