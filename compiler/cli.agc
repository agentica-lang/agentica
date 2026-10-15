## The command line of `agentica` (src/main.rkt): the entry point of the front end, `run`. It reads the options, then
## does what the first word asks: run a program, `check` it, `compile` it to a file, print `help`, or start the tests.
##
## `run` takes everything it cannot know from outside (docs/future/35-self-hosting.md, 35.3, "Front-end inputs"): the
## arguments the user typed, the Agentica version, the `Host` (where the `std/` sources are, and the VM and command for
## `agentica test`) and `hand_off`, the function that runs a compiled program and gives back its exit status. In an
## ordinary run (cli_main.agc) `hand_off` starts `agentica-vm` on a file; the single binary will hand the bytes to C.
##
## The exit status is the one of the Racket command line: 0 on success, 1 for a diagnostic (printed on stderr in the
## style `--ai` or `--json` asks), 2 for a usage error or a file it cannot read or write; a program that runs gives
## its own status.

import {IO_TIMEOUT, write_bytes} from "bdd_files"
import Driver from "bdd_driver"
import Opts from "bdd_options"
import Report from "bdd_report"
import SourceRoot from "bdd_source_root"
import Problems from "check_failure"
import CheckText from "check_text"
import Options from "cli_options"
import Host from "cli_host"
import Help from "cli_help"
import Reply from "cli_reply"
import Texts from "cli_text"
import Diagnostic from "diagnostic_text"
import DiagnosticJson from "diagnostic_json"
import Env from "link_env"
import Lowering from "lowering"
import LowerText from "lower_text"
import Pipeline from "pipeline"
import SourceFile from "source_file"
import Spawn from "cli_spawn"

# What one run is given besides the words of the user: the options read in front of them, the version, the host and the
# hand-off.
struct Session
  options: Options.Options
  version: String
  host: Host.Host
  hand_off: Fn[Host.Host, Host.Launch, Int]
end

## Runs the command line `args` (the words after the program name) and gives the exit status. Everything it writes goes
## to the standard streams of this process.
export def run(args: List[String], version: String, host: Host.Host, hand_off: Fn[Host.Host, Host.Launch, Int]) -> Int
  case Options.parse(args, version)
    Options.Parsed.Answer(reply) -> return emit(reply)
    Options.Parsed.Ready(options) ->
      return dispatch(Session(options: options, version: version, host: host, hand_off: hand_off))
  end
end

# The first word picks the command; a word that is not a command is the source file of a run.
def dispatch(session: Session) -> Int
  words = session.options.words
  first = ""
  if words.size > 0
    first = words[0]
  end
  if first == "test"
    return test(session, words.drop(1))
  elsif first == "help"
    return emit(Help.help(words, session.options.style))
  end
  rest = words
  if first == "check" or first == "compile"
    rest = words.drop(1)
  end
  usable = rest.size >= 1
  if first == "compile"
    usable = rest.size == 3 and rest[1] == "-o" and !session.options.dump and !session.options.dump_ir
  end
  if !usable
    return emit(Reply.failed(2, Texts.usage_text()))
  end
  return program(session, first, rest)
end

# A source file: read, link, check, and then do what the command and the options say.
def program(session: Session, verb: String, rest: List[String]) -> Int
  source = rest[0]
  case Pipeline.read_root(source)
    Pipeline.Root.Unreadable(_) -> return emit(Reply.failed(2, "agentica: cannot read #{source}\n"))
    Pipeline.Root.Invalid(problem) -> return reject(session, problem, source)
    Pipeline.Root.Readable -> return linked(session, verb, rest)
  end
end

def linked(session: Session, verb: String, rest: List[String]) -> Int
  source = rest[0]
  settings = Env.settings(session.host.stdlib, Env.process_env())
  case Pipeline.check_file(source, settings)
    Pipeline.Front.Rejected(problem) -> return reject(session, problem, source)
    Pipeline.Front.Done(front) -> return checked(session, verb, rest, front, settings)
  end
end

# What is done with a program that checked, in the order of src/main.rkt.
def checked(
  session: Session, verb: String, rest: List[String], front: Pipeline.Checked, settings: Env.Settings
) -> Int
  source = rest[0]
  if verb == "check"
    if session.options.style == "json"
      return emit(Reply.printed("{\"ok\":true}\n"))
    end
    return emit(Reply.printed("check ok\n"))
  elsif session.options.dump
    return emit(Reply.printed("#{CheckText.program_text(front.linked, front.checked)}\n"))
  elsif session.options.dump_ir
    return dump_ir(session, source, front, settings)
  end
  case Pipeline.build(session.version, front, settings)
    Pipeline.Compiled.Rejected(problem) -> return reject(session, problem, source)
    Pipeline.Compiled.Bytes(bytes) ->
      if verb == "compile"
        return save(rest[2], bytes)
      end
      launch = Host.Launch(bytes: bytes, flags: vm_flags(session.options, source), arguments: rest.drop(1))
      return session.hand_off.call(session.host, launch)
  end
end

# `--dump-ir`: the lowered program in the text form of lower_text.agc. It is not the `format-ir` of src/lower.rkt,
# which drops what the bytecode needs and prints Racket values (the status note of step 8a in
# docs/future/35-self-hosting.md says why).
def dump_ir(session: Session, source: String, front: Pipeline.Checked, settings: Env.Settings) -> Int
  case Lowering.lower(front.linked, front.checked, settings.catalog)
    Lowering.Lowered.Failed(problem) -> return reject(session, problem, source)
    Lowering.Lowered.Done(program) ->
      return emit(Reply.printed("#{LowerText.program_text(front.linked.root_dir, program)}\n"))
  end
end

# The options the VM gets, in the order src/main.rkt gives them.
def vm_flags(options: Options.Options, source: String) -> List[String]
  flags: List[String] = []
  if options.max_steps != ""
    flags = flags.concat(["--max-steps", options.max_steps])
  end
  if options.seed != ""
    flags = flags.concat(["--seed", options.seed])
  end
  if options.flush_timeout != ""
    flags = flags.concat(["--flush-timeout", options.flush_timeout])
  end
  if options.allow_run
    flags = flags.push("--allow-run")
  end
  root = SourceRoot.option(source)
  if root != ""
    flags = flags.concat(["--source-root", root])
  end
  if options.style == "ai"
    flags = flags.push("--ai")
  elsif options.style == "json"
    flags = flags.push("--json")
  end
  return flags
end

# `compile`: the bytes to the file, which is created or emptied first.
def save(output: String, bytes: List[Int]) -> Int
  failure = Reply.failed(2, "agentica: cannot write #{output}\n")
  opened = File.open(output, "write", IO_TIMEOUT)
  if !opened.ok?
    return emit(failure)
  end
  rest = bytes
  written = ok()
  while rest.size > 0 and written.ok?
    written = File.write_bytes(opened.unwrap!, rest.take(1048576), IO_TIMEOUT)
    rest = rest.drop(1048576)
  end
  closed = File.close(opened.unwrap!, IO_TIMEOUT)
  if !written.ok? or !closed.ok?
    return emit(failure)
  end
  return 0
end

# The first problem of a stage, in the form the options ask for, on stderr: exit status 1. A problem in the root file
# names it as it was typed (the linker knows it by its absolute path), and one in an imported file by its canonical
# path.
def reject(session: Session, problem: Problems.Problem, source: String) -> Int
  style = session.options.style
  shown = problem
  if problem.file == Path.resolve(source).unwrap_or(source)
    shown = problem.with(file: source)
  end
  if style == "json"
    IO.warn(JSON.encode(DiagnosticJson.json(shown)))
  else
    text = SourceFile.display_text(source_path(shown.file, source, session.host), IO_TIMEOUT)
    if style == "ai"
      IO.warn(Diagnostic.ai(shown, text))
    else
      IO.warn(Diagnostic.plain(shown, text))
    end
  end
  return 1
end

# Where the text of the file of a problem is: the root file as it was typed, a `std/NAME.agc` module in the stdlib/
# folder, any other file by its path.
def source_path(file: String, source: String, host: Host.Host) -> String
  if file != source and file.starts_with?("std/")
    return "#{host.stdlib}/#{file.slice(4, file.length - 4)}"
  end
  return file
end

# `agentica test`: the BDD driver (bdd_driver.agc), in this process. The words after `test` go to it as they are,
# with the options in front of `test` and what only this process knows. Without a VM nothing can run: one line on
# stderr and status 2, as for a program.
def test(session: Session, words: List[String]) -> Int
  options = session.options
  host = session.host
  if !Spawn.runnable?(host.vm)
    return emit(Reply.failed(2, "#{Spawn.missing_text(host.vm)}\n"))
  end
  driver: List[String] = [
    "--vm", host.vm, "--version", session.version, "--stdlib", host.stdlib, "--style", options.style,
    "--test-timeout-ms", "30000",
  ]
  if options.allow_run
    driver = driver.push("--allow-run")
  end
  if options.seed != ""
    driver = driver.concat(["--seed", options.seed])
  end
  for word in host.command
    driver = driver.concat(["--agentica", word])
  end
  driver = driver.push("--")
  for steps in options.steps
    driver = driver.concat(["--steps", steps])
  end
  case Opts.parse(driver.concat(words))
    Opts.Parsed.Broken(message) ->
      return emit(Reply.failed(2, "agentica: the test driver was started wrongly: #{message}\n"))
    Opts.Parsed.Usage(message, shown) -> return finish(Report.usage(message, shown))
    Opts.Parsed.Ready(ready) -> return finish(Driver.run(ready))
  end
end

def finish(ending: Report.Ending) -> Int
  return emit(Reply.Reply(code: ending.code, out: ending.text, err: ""))
end

# Writes the answer to the standard streams and gives its status. stderr text ends with a line feed that IO.warn adds.
def emit(reply: Reply.Reply) -> Int
  if reply.out != ""
    print(reply.out)
  end
  if reply.err != ""
    IO.warn(reply.err.slice(0, reply.err.length - 1))
  end
  return reply.code
end
