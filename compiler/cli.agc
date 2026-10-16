## The command line of `agentica` (src/main.rkt): the entry point of the front end, `run`. It reads the options, then
## does what the first word asks: run a program, `check` it, `compile` it to a file, print `help`, or start the tests.
##
## `run` takes everything it cannot know from outside (docs/future/35-self-hosting.md, 35.3, "Front-end inputs"): the
## settings (the Agentica version, the provider of the `std/` sources, the path of the binary that `agentica test`
## starts again), the words the user typed and `hand_off`, the function that runs a compiled program and gives back its
## exit status (front_end_cli.agc hands the bytes to C).
##
## `agentica run [OPTIONS] -- FILE.agcb [ARGS...]`, which runs a compiled program, is not here: C answers it before it
## starts this front end.
##
## The exit status is the one of the Racket command line: 0 on success, 1 for a diagnostic (printed on stderr in the
## style `--ai` or `--json` asks), 2 for a usage error or a file it cannot read or write; a program that runs gives
## its own status.

import Driver from "bdd_driver"
import Opts from "bdd_options"
import Report from "bdd_report"
import SourceRoot from "bdd_source_root"
import Problems from "check_failure"
import CheckText from "check_text"
import Options from "cli_options"
import Launch from "cli_launch"
import Help from "cli_help"
import Reply from "cli_reply"
import Texts from "cli_text"
import Ai from "diagnostic_ai"
import DiagnosticJson from "diagnostic_json"
import Plain from "diagnostic_plain"
import Env from "link_env"
import Lowering from "lowering"
import LowerText from "lower_text"
import Pipeline from "pipeline"
import Resolve from "resolve_import"
import SaveFile from "save_file"
import SourceFile from "source_file"

# The deadline of each call that writes the output of `compile`, in milliseconds.
SAVE_TIMEOUT = 60000

# What one run is given besides the words of the user: the options read in front of them, the settings and the
# hand-off.
struct Session
  options: Options.Options
  settings: Env.Settings
  hand_off: Fn[Launch.Launch, Int]
end

## Runs the command line `args` (the words after the program name) and gives the exit status. Everything it writes goes
## to the standard streams of this process.
export def run(settings: Env.Settings, args: List[String], hand_off: Fn[Launch.Launch, Int]) -> Int
  case Options.parse(args, settings.version)
    Options.Parsed.Answer(reply) -> return emit(reply)
    Options.Parsed.Ready(options) ->
      return dispatch(Session(options: options, settings: settings, hand_off: hand_off))
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
  elsif first == "run"
    return emit(Reply.failed(2, Texts.run_first_text()))
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
  case Pipeline.check_file(source, session.settings)
    Pipeline.Front.Rejected(problem) -> return reject(session, problem, source)
    Pipeline.Front.Done(front) -> return checked(session, verb, rest, front)
  end
end

# What is done with a program that checked, in the order of src/main.rkt.
def checked(session: Session, verb: String, rest: List[String], front: Pipeline.Checked) -> Int
  source = rest[0]
  if verb == "check"
    if session.options.style == "json"
      return emit(Reply.printed("{\"ok\":true}\n"))
    end
    return emit(Reply.printed("check ok\n"))
  elsif session.options.dump
    return emit(Reply.printed("#{CheckText.program_text(front.linked, front.checked)}\n"))
  elsif session.options.dump_ir
    return dump_ir(session, source, front)
  end
  case Pipeline.build(front, session.settings)
    Pipeline.Compiled.Rejected(problem) -> return reject(session, problem, source)
    Pipeline.Compiled.Bytes(bytes) ->
      if verb == "compile"
        return save(rest[2], bytes)
      end
      launch = Launch.Launch(bytes: bytes, flags: vm_flags(session.options, source), arguments: rest.drop(1))
      return session.hand_off.call(launch)
  end
end

# `--dump-ir`: the lowered program in the text form of lower_text.agc. It is not the `format-ir` of src/lower.rkt,
# which drops what the bytecode needs and prints Racket values (the status note of step 8a in
# docs/future/35-self-hosting.md says why).
def dump_ir(session: Session, source: String, front: Pipeline.Checked) -> Int
  case Lowering.lower(front.linked, front.checked, session.settings.catalog)
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
  if !SaveFile.bytes(output, bytes, SAVE_TIMEOUT).ok?
    return emit(Reply.failed(2, "agentica: cannot write #{output}\n"))
  end
  return 0
end

# The first problem of a stage, in the form the options ask for, on stderr: exit status 1. A problem in the root file
# names it as it was typed (the linker knows it by its absolute path), and one in an imported file by its canonical
# path.
def reject(session: Session, problem: Problems.Problem, source: String) -> Int
  style = session.options.style
  root = is_root?(problem.file, source)
  shown = problem
  if root
    shown = problem.with(file: source)
  end
  if style == "json"
    IO.warn(JSON.encode(DiagnosticJson.json(shown)))
  else
    text = source_text(problem.file, root, session.settings)
    if style == "ai"
      IO.warn(Ai.ai(shown, text))
    else
      IO.warn(Plain.format(shown, text))
    end
  end
  return 1
end

def is_root?(named: String, typed: String) -> Bool
  if named == typed
    return true
  end
  real = Path.real(typed)
  return real.ok? and real.unwrap! == named
end

# The text that the lines of a message come from. A std/ module is not a file of the working folder: it goes straight
# to the provider of the settings (the stdlib/ folder or the binary), even when the folder has a std/ of its own. A
# file with bytes that are not UTF-8 shows them as U+FFFD, as Racket does.
def source_text(file: String, root: Bool, settings: Env.Settings) -> String
  if !root and file.starts_with?("std/")
    return text_of(Resolve.read_source(settings, file))
  end
  return text_of(SourceFile.read_shown(file, Env.io_timeout()))
end

def text_of(read: SourceFile.Read) -> String
  case read
    SourceFile.Read.Text(text) -> return text
    SourceFile.Read.Invalid(_) -> return ""
    SourceFile.Read.Unreadable(_) -> return ""
  end
end

# `agentica test`: the BDD driver (bdd_driver.agc), in this process. The words after `test` go to it as they are,
# with the options in front of `test` and what only this process knows: the binary, which the driver starts again as
# `agentica run` for the runner and for the programs under test (and the programs under test start it for `agentica
# FILE`). A front end that was not told where the binary is (no --self) cannot do that: one line on stderr, status 2.
def test(session: Session, words: List[String]) -> Int
  options = session.options
  binary = session.settings.self_path
  if binary == ""
    return emit(Reply.failed(2, Texts.test_without_binary_text()))
  end
  driver: List[String] = [
    "--vm", binary, "--version", session.settings.version, "--style", options.style,
    "--test-timeout-ms", "30000",
  ]
  if options.allow_run
    driver = driver.push("--allow-run")
  end
  if options.seed != ""
    driver = driver.concat(["--seed", options.seed])
  end
  driver = driver.concat(["--agentica", binary, "--"])
  for steps in options.steps
    driver = driver.concat(["--steps", steps])
  end
  case Opts.parse(driver.concat(words))
    Opts.Parsed.Broken(message) ->
      return emit(Reply.failed(2, "agentica: the test driver was started wrongly: #{message}\n"))
    Opts.Parsed.Usage(message, shown) -> return finish(Report.usage(message, shown))
    Opts.Parsed.Ready(ready) -> return finish(Driver.run(ready, session.settings))
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
