## The stages of the front end from a file to the bytes of its .agcb: link, check (analysis/front.agc), lower and
## write, each giving the data of the next stage or the first problem. The BDD driver and the command line (cli.agc)
## both run it.

import Writer from "../bytecode/bytecode_writer"
import Problems from "../diagnostics/problem"
import Front from "../analysis/front"
import Env from "../modules/link_env"
import Lowering from "../lower/lowering"

## The result of compiling: the bytes of the program, or the first problem.
export enum Compiled
  Bytes(List[Int])
  Rejected(Problems.Problem)
end

## Lowers a checked program and writes its bytes. The header names `settings.version`.
export def build(front: Front.Checked, settings: Env.Settings) -> Compiled
  case Lowering.lower(front.linked, front.checked)
    Lowering.Lowered.Failed(problem) -> return Compiled.Rejected(problem)
    Lowering.Lowered.Done(program) ->
      return write(Writer.write(program, settings.version))
  end
end

## Compiles the file at `path` to the bytes of its .agcb.
export def compile(path: String, settings: Env.Settings) -> Compiled
  case Front.check_file(path, settings)
    Front.Outcome.Rejected(problem) -> return Compiled.Rejected(problem)
    Front.Outcome.Done(front) -> return build(front, settings)
  end
end

def write(written: Writer.Written) -> Compiled
  case written
    Writer.Written.Failed(problem) -> return Compiled.Rejected(problem)
    Writer.Written.Done(bytes) -> return Compiled.Bytes(bytes)
  end
end
