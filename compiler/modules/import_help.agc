## The help of an unknown import name: the "did you mean" of the linker.

import Ast from "../syntax/ast"
import Declarations from "declarations"
import Diag from "../diagnostics/diagnostic"
import Suggest from "../syntax/suggest"

## The help of CHECK-IMPORT-NAME for member, which the module key does not export: the fixed texts for the removed
## std/http functions and std/logger error, or the did-you-mean over the exports (a private name is never suggested).
## Through an alias (Mod.nme) a constant is suggested as the import that reads it.
export def unknown_import_help(
  key: String,
  exports: Map[String, Declarations.Kind],
  member: String,
  via_alias: Bool,
) -> Diag.Help
  removed = ["respond", "begin", "write", "write_bytes", "finish"].any? do |name| name == member end
  if key == "std/http.agc" and removed
    return Diag.Help.Hint(
      "a handler returns its whole response: return ok(HttpResponse(status: 200, headers: [], body: text))",
    )
  elsif key == "std/logger.agc" and member == "error"
    return Diag.Help.Hint("the function for the error level is Logger.err; error is a reserved name")
  end
  case Suggest.closest_among(member, exports.keys, [])
    Ast.Optional.Present(name) ->
      if via_alias and Declarations.constant?(exports[name])
        return Diag.Help.Hint("did you mean \"import {#{name}}\"?")
      end
      return Diag.Help.Hint("did you mean \"#{name}\"?")
    Ast.Optional.Absent -> return Diag.Help.NoHelp
  end
end
