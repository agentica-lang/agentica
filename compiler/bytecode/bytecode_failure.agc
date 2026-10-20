## The BYTECODE- problems of the writer. A failing step returns `error(...)` of a packed problem (check_failure.agc
## pack), as the lowering does, and `try` carries it to the writer, which unpacks it.

import Failure from "../check/check_failure"
import Diag from "../diagnostics/diagnostic"
import Ir from "../lower/ir"
import Source from "../syntax/source"

## BYTECODE-LIMIT: the program has too many of something for the format. file is the index of the source that the span
## is in.
export def limit(program: Ir.Program, file: Int, what: String, span: Source.Span) -> String
  message = "the program has too many #{what} for the VM"
  found = Failure.problem(program.sources[file].file, "", "BYTECODE-LIMIT", message, span, Diag.Help.NoHelp)
  return Failure.pack(found)
end

## BYTECODE-INTERNAL: the IR holds something the writer cannot write. Lowering never gives such an IR; the failure is
## reported at the span of the program, with a message of the writer's own.
export def internal(program: Ir.Program, message: String) -> String
  found = Failure.problem(program.sources[0].file, "", "BYTECODE-INTERNAL", message, program.span, Diag.Help.NoHelp)
  return Failure.pack(found)
end
