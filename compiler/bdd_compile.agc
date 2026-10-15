## Compiling a program for the BDD driver: the Agentica front end from a file to the bytes of its .agcb (link, check,
## lower, write), with the first problem of any stage as one Problem.

import {IO_TIMEOUT} from "bdd_files"
import Report from "bdd_report"
import Writer from "bytecode_writer"
import Problems from "check_failure"
import Checker from "checker"
import Diag from "diagnostic"
import Env from "link_env"
import Linker from "linker"
import Lowering from "lowering"
import SourceFile from "source_file"

## The result of compiling: the bytes of the program, or the first problem.
export enum Compiled
  Bytes(List[Int])
  Rejected(Problems.Problem)
end

## Compiles the file at `path`. A file that cannot be read is RUNTIME-BDD-INFRA with the message `unreadable`; a file
## that is not UTF-8 is LEX-INVALID-UTF8, in that file. Every problem names `path` as it was given for the root file,
## and the canonical path for the files it imports.
export def file(path: String, settings: Env.Settings, unreadable: String) -> Compiled
  case SourceFile.read(path, IO_TIMEOUT)
    SourceFile.Read.Unreadable(_) -> return Compiled.Rejected(Report.located(path, "RUNTIME-BDD-INFRA", unreadable))
    SourceFile.Read.Invalid(at) -> return Compiled.Rejected(stage_problem(path, SourceFile.invalid_utf8(at)))
    SourceFile.Read.Text(_) -> return link(path, settings)
  end
end

## The problem of a stage that has no file of its own (the lexer and the parser), put in `file`.
export def stage_problem(file: String, problem: Diag.Diagnostic) -> Problems.Problem
  return Problems.problem(file, "", problem.code, problem.message, problem.span, problem.help)
end

def link(path: String, settings: Env.Settings) -> Compiled
  case Linker.link_file(path, settings)
    Linker.Linking.Failed(failure) -> return Compiled.Rejected(stage_problem(failure.file, failure.diagnostic))
    Linker.Linking.Done(linked) -> return check(linked, settings)
  end
end

def check(linked: Linker.Linked, settings: Env.Settings) -> Compiled
  case Checker.check(linked, settings.catalog)
    Checker.Checking.Failed(problem) -> return Compiled.Rejected(problem)
    Checker.Checking.Done(checked) -> return lower(linked, Lowering.lower(linked, checked, settings.catalog))
  end
end

def lower(linked: Linker.Linked, lowered: Lowering.Lowered) -> Compiled
  case lowered
    Lowering.Lowered.Failed(problem) -> return Compiled.Rejected(problem)
    Lowering.Lowered.Done(program) -> return write(Writer.write(linked.root_dir, program))
  end
end

def write(written: Writer.Written) -> Compiled
  case written
    Writer.Written.Failed(problem) -> return Compiled.Rejected(problem)
    Writer.Written.Done(bytes) -> return Compiled.Bytes(bytes)
  end
end
