## The command line of `agentica`: the entry point of the front end, `run`. It reads the options, then does what the
## first word asks: run a program, `check` it, `compile` it to a file, print `help`, print the API of a module with
## `doc`, list the declarations of a file with `outline`, give the type at a position with `type-at`, list the
## references to a name with `refs`, or start the tests.
##
## `run` takes everything it cannot know from outside (docs/future/35-self-hosting.md, 35.3, "Front-end inputs"): the
## settings (the Agentica version, the provider of the `std/` sources, the path of the binary that `agentica test`
## starts again), the words the user typed and `hand_off`, the function that runs a compiled program and gives back its
## exit status (front_end_cli.agc hands the bytes to C).
##
## `agentica check --stdin FILE` checks the text on standard input as if FILE held it (io/stdin_buffer.agc); a query
## command (`outline`) takes `--stdin FILE` the same way, and `type-at` and `refs` with `--stdin FILE:LINE:COL` read
## FILE from it.
##
## `agentica run [OPTIONS] -- FILE.agcb [ARGS...]`, which runs a compiled program, is not here: C answers it before it
## starts this front end.
##
## The exit status is 0 on success, 1 for a diagnostic (printed on stderr in the
## style `--ai` or `--json` asks), 2 for a usage error or a file it cannot read or write; a program that runs gives
## its own status.

import Core from "../analysis/analysis"
import Cache from "../analysis/cache"
import Front from "../analysis/front"
import Driver from "../bdd/bdd_driver"
import Opts from "../bdd/bdd_options"
import Report from "../bdd/bdd_report"
import SourceRoot from "../bdd/bdd_source_root"
import CheckText from "../check/check_text"
import Ai from "../diagnostics/diagnostic_ai"
import DiagnosticJson from "../diagnostics/diagnostic_json"
import Plain from "../diagnostics/diagnostic_plain"
import Problems from "../diagnostics/problem"
import SaveFile from "../io/save_file"
import SourceReader from "../io/source_reader"
import StdinBuffer from "../io/stdin_buffer"
import LowerText from "../lower/lower_text"
import Lowering from "../lower/lowering"
import Env from "../modules/link_env"
import Resolve from "../modules/resolve_import"
import QueryFiles from "../query/query_files"
import QueryOptions from "../query/query_options"
import QueryPosition from "../query/query_position"
import SourceFile from "../syntax/source_file"
import CliDoc from "cli_doc"
import Help from "cli_help"
import Launch from "cli_launch"
import Options from "cli_options"
import CliQuery from "cli_query"
import Reply from "cli_reply"
import Texts from "cli_text"
import Pipeline from "pipeline"

# The deadline of each call that writes the output of `compile`, in milliseconds.
SAVE_TIMEOUT = 60_000

# What one run is given besides the words of the user: the options read in front of them, the settings and the
# hand-off. `buffer_file` is the file whose text came from standard input ("" for none), and `buffer_shown` that text
# for the lines of a message.
struct Session
  options: Options.Options
  settings: Env.Settings
  hand_off: Fn[Launch.Launch, Int]
  buffer_file: String
  buffer_shown: String
end

## Runs the command line `args` (the words after the program name) and gives the exit status. Everything it writes goes
## to the standard streams of this process.
export def run(settings: Env.Settings, args: List[String], hand_off: Fn[Launch.Launch, Int]) -> Int
  case Options.parse(args, settings.version)
    Options.Parsed.Answer(reply) -> return emit(reply)
    Options.Parsed.Ready(options) ->
      return dispatch(
        Session(options: options, settings: settings, hand_off: hand_off, buffer_file: "", buffer_shown: ""),
      )
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
  elsif first == "doc"
    return doc(session, words)
  elsif first == "outline" or first == "type-at"
    return query(session, first, words.drop(1))
  elsif first == "symbol"
    return symbol(session, words.drop(1))
  elsif first == "refs"
    return refs(session, words.drop(1))
  elsif first == "run"
    return emit(Reply.failed(2, Texts.run_first_text()))
  end
  rest = words
  if first == "check" or first == "compile"
    rest = words.drop(1)
  end
  if first == "check" and rest.size > 0 and rest[0] == "--stdin"
    return check_stdin(session, rest.drop(1))
  end
  usable = rest.size >= 1
  if first == "check"
    # `check FILE --stdin` would check the disk while the caller means the buffer.
    usable = usable and !rest.drop(1).any? do |word: String| word == "--stdin" end
  end
  if first == "compile"
    usable = rest.size == 3 and rest[1] == "-o" and !session.options.dump and !session.options.dump_ir
  end
  if !usable
    return emit(Reply.failed(2, Texts.usage_text()))
  end
  return program(session, first, rest)
end

# `doc PATH`: a complete answer, or the first problem of the module, shown as a problem of PATH.
def doc(session: Session, words: List[String]) -> Int
  return answered(session, CliDoc.run(words, session.options.style, session.settings), "")
end

# What a command gave: print the answer, or reject the first problem of the program. A QUERY- problem is a mistake in
# the question, exit status 2; any other is a mistake in the program, exit status 1. `source` is the file as the user
# typed it ("" for the file of the problem).
def answered(session: Session, answer: Reply.Answer, source: String) -> Int
  case answer
    Reply.Answer.Printed(reply) -> return emit(reply)
    Reply.Answer.Rejected(problem) ->
      status = 1
      if problem.code.starts_with?("QUERY-")
        status = 2
      end
      if source == ""
        return reject(session, problem, problem.file, status)
      end
      return reject(session, problem, source, status)
  end
end

# A query command: the words after its name give the options and the one file, or for `type-at` the one position. The
# style may come from them as well as from the options in front of the command.
def query(session: Session, verb: String, words: List[String]) -> Int
  usage = CliQuery.outline_usage()
  if verb == "type-at"
    usage = CliQuery.type_at_usage()
  end
  case QueryOptions.parse(words, session.options.style, usage, true)
    QueryOptions.Parsed.Refused(problem) -> return answered(session, Reply.Answer.Rejected(problem), "")
    QueryOptions.Parsed.Ready(asked) ->
      styled = session.with(options: session.options.with(style: asked.style))
      case QueryFiles.pick(asked, usage)
        QueryFiles.Picked.Refused(problem) -> return answered(styled, Reply.Answer.Rejected(problem), "")
        QueryFiles.Picked.File(file) ->
          if verb != "outline"
            return position(styled, file, asked, usage)
          end
          if asked.stdin == ""
            return answered(styled, CliQuery.outline(file, asked.style, false, styled.settings), file)
          end
          return with_buffer(styled, file) do |buffered: Session|
            answered(buffered, CliQuery.outline(file, asked.style, true, buffered.settings), file)
          end
      end
  end
end

# `symbol NAME [PATH...]`. With `--stdin FILE` the text of FILE is the standard input and FILE is searched as well; a
# problem in FILE is shown against the buffer.
def symbol(session: Session, words: List[String]) -> Int
  case QueryOptions.parse(words, session.options.style, CliQuery.symbol_usage(), false)
    QueryOptions.Parsed.Refused(problem) -> return answered(session, Reply.Answer.Rejected(problem), "")
    QueryOptions.Parsed.Ready(asked) ->
      styled = session.with(options: session.options.with(style: asked.style))
      if asked.stdin == ""
        return answered(styled, CliQuery.symbol(asked, styled.settings), "")
      end
      return with_buffer(styled, asked.stdin) do |buffered: Session|
        answered(buffered, CliQuery.symbol(asked, buffered.settings), asked.stdin)
      end
  end
end

# `refs NAME|FILE:LINE:COL [PATH...]`. With `--stdin FILE:LINE:COL` the text of FILE is the standard input and stands
# in for the first word; with `--stdin FILE` and a NAME it is searched as one more file, as for `symbol`. `--partial`
# goes with a position alone (`CliQuery.refs_ask`).
def refs(session: Session, words: List[String]) -> Int
  case QueryOptions.parse(words, session.options.style, CliQuery.refs_usage(), true)
    QueryOptions.Parsed.Refused(problem) -> return answered(session, Reply.Answer.Rejected(problem), "")
    QueryOptions.Parsed.Ready(asked) ->
      styled = session.with(options: session.options.with(style: asked.style))
      case CliQuery.refs_ask(asked)
        CliQuery.RefsAsk.Refused(problem) -> return answered(styled, Reply.Answer.Rejected(problem), "")
        CliQuery.RefsAsk.At(position, paths) ->
          if asked.stdin == ""
            found = CliQuery.refs_at(position, paths, asked.style, asked.partial, styled.settings)
            return answered(styled, found, position.file)
          end
          return with_buffer(styled, position.file) do |read: Session|
            answered(read, CliQuery.refs_at(position, paths, asked.style, asked.partial, read.settings), position.file)
          end
        CliQuery.RefsAsk.Named(name, paths) ->
          if asked.stdin == ""
            return answered(styled, CliQuery.refs_named(name, paths, "", asked.style, styled.settings), "")
          end
          return with_buffer(styled, asked.stdin) do |read: Session|
            answered(read, CliQuery.refs_named(name, paths, asked.stdin, asked.style, read.settings), asked.stdin)
          end
      end
  end
end

# `type-at FILE:LINE:COL`, or the same with `--stdin`, where the text of FILE is the standard input. `options` are the
# words of the command: the style, `--stdin` and `--partial`.
def position(session: Session, word: String, options: QueryOptions.Query, usage: String) -> Int
  case QueryPosition.parse(word, usage)
    QueryPosition.Parsed.Refused(problem) -> return answered(session, Reply.Answer.Rejected(problem), "")
    QueryPosition.Parsed.Ready(asked) ->
      if options.stdin == ""
        return answered(
          session,
          CliQuery.type_at(asked, session.options.style, options.partial, session.settings),
          asked.file,
        )
      end
      return with_buffer(session, asked.file) do |read: Session|
        answered(read, CliQuery.type_at(asked, read.options.style, options.partial, read.settings), asked.file)
      end
  end
end

# `check --stdin FILE`: the text of FILE is the standard input. FILE need not exist, but its folder does: imports and
# agentica.toml resolve from there. Anything but one file name is a usage error, before the input is read; an option
# (`check --stdin --json`) is not a file name.
def check_stdin(session: Session, files: List[String]) -> Int
  if files.size != 1 or !QueryOptions.file_name?(files[0])
    return emit(Reply.failed(2, Texts.usage_text()))
  end
  return with_buffer(session, files[0]) do |buffered: Session| program(buffered, "check", files) end
end

# Takes the standard input as the text of `file` and gives `then` a session whose workspace answers it. A standard
# input that cannot be taken is status 2 and `then` never runs.
def with_buffer(session: Session, file: String, then: Fn[Session, Int]) -> Int
  case StdinBuffer.take()
    StdinBuffer.Taken.Failed(message) -> return emit(Reply.failed(2, "agentica: #{message}\n"))
    StdinBuffer.Taken.Got(buffer) ->
      workspace = StdinBuffer.over(session.settings.workspace, session.settings.env.windows, file, buffer)
      return then.call(
        Session(
          options: session.options,
          settings: session.settings.with(workspace: workspace),
          hand_off: session.hand_off,
          buffer_file: file,
          buffer_shown: buffer.shown,
        ),
      )
  end
end

# A source file: read, link, check, and then do what the command and the options say.
def program(session: Session, verb: String, rest: List[String]) -> Int
  source = rest[0]
  if verb == "check"
    return verdict(session, source, Core.check(Cache.empty(), session.settings, source))
  end
  case Front.read_root(session.settings.workspace, source)
    Front.Root.Unreadable(_) -> return emit(Reply.failed(2, "agentica: cannot read #{source}\n"))
    Front.Root.Invalid(problem) -> return reject(session, problem, source, 1)
    Front.Root.Readable -> return linked(session, verb, rest)
  end
end

# `check`: say that the program checks, or reject its first problem. `check` accepts a library file: only what is built
# to run (a run, `compile`) needs a main.
def verdict(session: Session, source: String, found: Core.Verdict) -> Int
  case found
    Core.Verdict.Unreadable -> return emit(Reply.failed(2, "agentica: cannot read #{source}\n"))
    Core.Verdict.Rejected(problem) -> return reject(session, problem, source, 1)
    Core.Verdict.Passed ->
      if session.options.style == "json"
        return emit(Reply.printed("{\"ok\":true}\n"))
      end
      return emit(Reply.printed("check ok\n"))
  end
end

def linked(session: Session, verb: String, rest: List[String]) -> Int
  source = rest[0]
  case Front.check_file(source, session.settings)
    Front.Outcome.Rejected(problem) -> return reject(session, problem, source, 1)
    Front.Outcome.Done(front) -> return checked(session, verb, rest, front)
  end
end

# What is done with a program that checked, in a fixed order.
def checked(session: Session, verb: String, rest: List[String], front: Front.Checked) -> Int
  source = rest[0]
  if session.options.dump
    return emit(Reply.printed("#{CheckText.program_text(front.linked, front.checked)}\n"))
  elsif session.options.dump_ir
    return dump_ir(session, source, front)
  end
  case Pipeline.build(front, session.settings)
    Pipeline.Compiled.Rejected(problem) -> return reject(session, problem, source, 1)
    Pipeline.Compiled.Bytes(bytes) ->
      if verb == "compile"
        return save(rest[2], bytes)
      end
      launch = Launch.Launch(bytes: bytes, flags: vm_flags(session.options, source), arguments: rest.drop(1))
      return session.hand_off.call(launch)
  end
end

# `--dump-ir`: the lowered program in the text form of lower_text.agc. It is not the `format-ir` of the former front
# end, which dropped what the bytecode needs (the status note of step 8a in docs/future/35-self-hosting.md says why).
def dump_ir(session: Session, source: String, front: Front.Checked) -> Int
  case Lowering.lower(front.linked, front.checked)
    Lowering.Lowered.Failed(problem) -> return reject(session, problem, source, 1)
    Lowering.Lowered.Done(program) ->
      text = LowerText.program_text(program)
      return emit(Reply.printed("#{text}\n"))
  end
end

# The options the VM gets, in a fixed order.
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
  if options.schedulers != ""
    flags = flags.concat(["--schedulers", options.schedulers])
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

# The first problem of a stage, in the form the options ask for, on stderr, with exit status `status`. A problem in the
# root file names it as it was typed (the linker knows it by its absolute path), and one in an imported file by its
# canonical path. A problem of the arguments (`<arguments>`) has no source lines to show.
def reject(session: Session, problem: Problems.Problem, source: String, status: Int) -> Int
  style = session.options.style
  root = Core.root?(problem.file, source, session.settings)
  shown = Core.named(session.settings, problem, source)
  if style == "json"
    IO.warn(JSON.encode(DiagnosticJson.json(shown)))
  else
    text = ""
    if Problems.at_source?(problem) and !QueryOptions.arguments?(problem)
      text = source_text(session, problem.file, root)
    end
    if style == "ai" and QueryOptions.arguments?(problem)
      IO.warn(Ai.ai(QueryOptions.unplaced(shown), text))
    elsif style == "ai"
      IO.warn(Ai.ai(shown, text))
    elsif QueryOptions.arguments?(problem)
      IO.warn(Plain.without_source(shown))
    else
      IO.warn(Plain.format(shown, text))
    end
  end
  return status
end

# The text that the lines of a message come from. A std/ module is not a file of the working folder: it goes straight
# to the provider of the settings (the stdlib/ folder or the binary), even when the folder has a std/ of its own. A
# file with bytes that are not UTF-8 shows them as U+FFFD. The root file of `check --stdin` is the text of the input.
def source_text(session: Session, file: String, root: Bool) -> String
  settings = session.settings
  if root and session.buffer_file != ""
    return session.buffer_shown
  elsif !root and file.starts_with?("std/")
    return text_of(Resolve.read_source(settings, file))
  end
  return text_of(SourceReader.read_shown(file))
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
  # The test files run in VMs that the driver starts, which do not get the flag, so it is refused instead of being
  # dropped without a word. Those VMs inherit AGENTICA_SCHEDULERS, which sets the count for all of them.
  if options.schedulers != ""
    return emit(Reply.failed(2, "agentica: test does not take --schedulers; set AGENTICA_SCHEDULERS instead\n"))
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
