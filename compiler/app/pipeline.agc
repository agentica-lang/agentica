## The stages of the front end from a file to the bytes of its .agcb: link, check (analysis/front.agc), lower and
## write, each giving the data of the next stage or the first problem. The BDD driver and the command line (cli.agc)
## both run it.

import Front from "../analysis/front"
import BytecodeCache from "../io/bytecode_cache"
import Writer from "../bytecode/bytecode_writer"
import Problems from "../diagnostics/problem"
import Lowering from "../lower/lowering"
import Env from "../modules/link_env"

## The result of compiling: the bytes of the program, or the first problem.
enum Compiled
  Bytes(Bytes)
  Rejected(Problems.Problem)
end

## Lowers a checked program and writes its bytes. The header names `settings.version`.
def build(front: Front.Checked, settings: Env.Settings) -> Compiled
  case Lowering.lower(front.linked, front.checked)
    Lowering.Lowered.Failed(problem) -> Compiled.Rejected(problem)
    Lowering.Lowered.Done(program) -> written(Writer.write(program, settings.version))
  end
end

## Like `build`, and keeps the bytes in the bytecode cache of `plan` (io/bytecode_cache.agc). The cache never fails a
## compile: a plan that is off, or an entry that cannot be written, changes nothing.
def build_cached(front: Front.Checked, settings: Env.Settings, plan: BytecodeCache.Plan) -> Compiled
  built = build(front, settings)
  case built
    Compiled.Rejected(_) -> built
    Compiled.Bytes(bytes) ->
      BytecodeCache.store(plan, settings, front.linked.modules, bytes)
      built
  end
end

## Compiles the file at `path` to the bytes of its .agcb.
def compile(path: String, settings: Env.Settings) -> Compiled
  case Front.check_file(path, settings)
    Front.Outcome.Rejected(problem) -> Compiled.Rejected(problem)
    Front.Outcome.Done(front) -> build(front, settings)
  end
end

private

def written(result: Writer.Written) -> Compiled
  case result
    Writer.Written.Failed(problem) -> Compiled.Rejected(problem)
    Writer.Written.Done(bytes) -> Compiled.Bytes(bytes)
  end
end
