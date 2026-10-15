## The stages of the front end from a file to the bytes of its .agcb: link, check, lower and write, each giving the
## data of the next stage or the first problem. The BDD driver and the command line (cli.agc) both run it.

import Writer from "bytecode_writer"
import Problems from "check_failure"
import Checker from "checker"
import Diag from "diagnostic"
import Linker from "linker"
import Env from "link_env"
import Lowering from "lowering"
import SourceFile from "source_file"

# The deadline, in milliseconds, of the read of the root file.
READ_TIMEOUT = 10000

## What the root file is: it can be read as UTF-8, it cannot be read (the system's message), or it is not UTF-8
## (LEX-INVALID-UTF8, in that file).
export enum Root
  Readable
  Unreadable(String)
  Invalid(Problems.Problem)
end

## A program that linked and checked: what lowering, `--dump` and the diagnostics' source text read.
export struct Checked
  linked: Linker.Linked
  checked: Checker.Checked
end

## The result of linking and checking: the program, or the first problem.
export enum Front
  Done(Checked)
  Rejected(Problems.Problem)
end

## The result of compiling: the bytes of the program, or the first problem.
export enum Compiled
  Bytes(List[Int])
  Rejected(Problems.Problem)
end

## Reads the root file once, so a file that cannot be read or decoded is told apart from a problem of the program. The
## linker reads it again; every problem names `path` as it was given.
export def read_root(path: String) -> Root
  case SourceFile.read(path, READ_TIMEOUT)
    SourceFile.Read.Unreadable(message) -> return Root.Unreadable(message)
    SourceFile.Read.Invalid(at) -> return Root.Invalid(stage_problem(path, SourceFile.invalid_utf8(at)))
    SourceFile.Read.Text(_) -> return Root.Readable
  end
end

## The problem of a stage that has no file of its own (the lexer and the parser), put in `file`.
export def stage_problem(file: String, problem: Diag.Diagnostic) -> Problems.Problem
  return Problems.problem(file, "", problem.code, problem.message, problem.span, problem.help)
end

## Links the file at `path` and checks it.
export def check_file(path: String, settings: Env.Settings) -> Front
  case Linker.link_file(path, settings)
    Linker.Linking.Failed(failure) -> return Front.Rejected(stage_problem(failure.file, failure.diagnostic))
    Linker.Linking.Done(linked) -> return check(linked, settings)
  end
end

## Lowers a checked program and writes its bytes. `version` is the Agentica version of the header.
export def build(version: String, front: Checked, settings: Env.Settings) -> Compiled
  case Lowering.lower(front.linked, front.checked, settings.catalog)
    Lowering.Lowered.Failed(problem) -> return Compiled.Rejected(problem)
    Lowering.Lowered.Done(program) -> return write(Writer.write(version, front.linked.root_dir, program))
  end
end

## Compiles the file at `path` to the bytes of its .agcb.
export def compile(version: String, path: String, settings: Env.Settings) -> Compiled
  case check_file(path, settings)
    Front.Rejected(problem) -> return Compiled.Rejected(problem)
    Front.Done(front) -> return build(version, front, settings)
  end
end

def check(linked: Linker.Linked, settings: Env.Settings) -> Front
  case Checker.check(linked, settings.catalog)
    Checker.Checking.Failed(problem) -> return Front.Rejected(problem)
    Checker.Checking.Done(checked) -> return Front.Done(Checked(linked: linked, checked: checked))
  end
end

def write(written: Writer.Written) -> Compiled
  case written
    Writer.Written.Failed(problem) -> return Compiled.Rejected(problem)
    Writer.Written.Done(bytes) -> return Compiled.Bytes(bytes)
  end
end
