## The command line of `agentica`: the entry point of the front end, `run`. It reads the options, then does what the
## first word asks: run a program, `check` it, `compile` it to a file, print `help`, print the API of a module with
## `doc`, format files with `fmt`, list the declarations of a file with `outline`, give the type
## at a position with `type-at`, list the references to a name with `refs`, write the packages of the lock to deps/
## with `install`, change the packages with `add` and `update`, or start the tests.
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
import Diag from "../diagnostics/diagnostic"
import DiagnosticJson from "../diagnostics/diagnostic_json"
import Plain from "../diagnostics/diagnostic_plain"
import Problems from "../diagnostics/problem"
import Format from "../format/format"
import BytecodeCache from "../io/bytecode_cache"
import CheckCache from "../io/check_cache"
import SaveFile from "../io/save_file"
import SourceReader from "../io/source_reader"
import StdinBuffer from "../io/stdin_buffer"
import LowerText from "../lower/lower_text"
import Lowering from "../lower/lowering"
import Env from "../modules/link_env"
import Failure from "../modules/link_failure"
import Resolve from "../modules/resolve_import"
import QueryFiles from "../query/query_files"
import QueryOptions from "../query/query_options"
import QueryPosition from "../query/query_position"
import SymbolPaths from "../query/symbol_paths"
import SourceFile from "../syntax/source_file"
import Add from "cli_add"
import CliCheck from "cli_check"
import CliDoc from "cli_doc"
import CliFmt from "cli_fmt"
import Help from "cli_help"
import Install from "cli_install"
import Launch from "cli_launch"
import Options from "cli_options"
import CliQuery from "cli_query"
import Reply from "cli_reply"
import Texts from "cli_text"
import Pipeline from "pipeline"

# The deadline of each call that writes the output of `compile` or a file of `fmt`, in milliseconds.
SAVE_TIMEOUT = 60_000
# The name of the standard input in the diagnostics of `fmt -`.
STDIN_NAME = "<stdin>"

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
  elsif first == "fmt"
    return fmt(session, words.drop(1))
  elsif first == "install"
    return install(session, words.drop(1))
  elsif first == "add"
    return answered(session, Add.add(session.settings, session.options.style, words.drop(1)), "")
  elsif first == "update"
    return answered(session, Add.update(session.settings, session.options.style, words.drop(1)), "")
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
  elsif first == "check"
    return check(session, rest)
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

# `doc PATH`: a complete answer, or the first problem of the module, shown as a problem of PATH.
def doc(session: Session, words: List[String]) -> Int
  return answered(session, CliDoc.run(words, session.options.style, session.settings), "")
end

# `install`: it takes no word; the project is the one of the working folder.
def install(session: Session, words: List[String]) -> Int
  if words.size != 0
    return emit(Reply.failed(2, Texts.usage_text()))
  end

  return answered(session, Install.run(session.settings, session.options.style), "")
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
        return answered(session, type_at(session, asked, options.partial), asked.file)
      end

      return with_buffer(session, asked.file) do |read: Session|
        answered(read, type_at(read, asked, options.partial), asked.file)
      end
  end
end

# The answer of `type-at`, with the cache of checked modules of the project of the file unless `--no-cache`.
def type_at(session: Session, asked: QueryPosition.Asked, partial: Bool) -> Reply.Answer
  settings = CheckCache.attach(session.settings, asked.file, !session.options.no_cache)
  return CliQuery.type_at(asked, session.options.style, partial, settings)
end

# `check [PATH...]`: one file, or every `.agc` file of the folders and files named (none: the working folder). One file
# answers as `check` always did; anything else checks every file and ends with a count (`check_all`). `--json` and
# `--ai` may stand among the paths, as for the query commands; `--stdin` after a path would check the disk while the
# caller means the buffer, so it is a usage error.
def check(session: Session, words: List[String]) -> Int
  if words.any? do |word: String| word == "--stdin" end
    return emit(Reply.failed(2, Texts.usage_text()))
  end

  case QueryOptions.parse(words, session.options.style, CliCheck.usage(), false)
    QueryOptions.Parsed.Refused(problem) -> return answered(session, Reply.Answer.Rejected(problem), "")
    QueryOptions.Parsed.Ready(asked) ->
      styled = session.with(options: session.options.with(style: asked.style))
      if asked.words.size == 1 and !styled.settings.workspace.directory_exists.call(asked.words[0])
        return program(styled, "check", asked.words)
      end

      return check_all(styled, asked.words)
  end
end

# `fmt [PATH...]`, `fmt --check [PATH...]`, `fmt -` and `fmt --tree FILE` (cli_fmt.agc). Any other form, an option
# among the paths and a path that names no `.agc` file are FMT-USAGE, status 2.
def fmt(session: Session, words: List[String]) -> Int
  if words.size > 0 and words[0] == "--tree"
    if words.size != 2
      return fmt_usage(session, "--tree takes one FILE")
    end

    return fmt_tree(session, words[1])
  elsif words.size > 0 and words[0] == "-"
    if words.size != 1
      return fmt_usage(session, "- reads one file from standard input and takes no PATH")
    end

    return fmt_stdin(session)
  end

  checking = words.size > 0 and words[0] == "--check"
  paths = words
  if checking
    paths = words.drop(1)
  end

  for path in paths
    if path.starts_with?("-")
      return fmt_usage(session, "unknown option #{path}")
    end
  end

  case SymbolPaths.expand(session.settings.workspace, paths, "", CliFmt.usage())
    SymbolPaths.Expanded.Refused(problem) -> return reject(session, problem.with(code: "FMT-USAGE"), problem.file, 2)
    SymbolPaths.Expanded.Files(roots) ->
      status = 0
      settings: Map[String, Result[Format.Settings]] = {}
      for root in roots
        file = root.typed
        found = CliFmt.manifest_dir(session.settings.workspace, file)
        if !settings.has_key?(found)
          settings = settings.put(found, CliFmt.settings_of(session.settings.workspace, found))
        end

        done = fmt_file(session, file, settings[found], checking)
        if done > status
          status = done
        end
      end

      return status
  end
end

def fmt_usage(session: Session, message: String) -> Int
  problem = QueryOptions.at_arguments("FMT-USAGE", message, Diag.Help.Hint(CliFmt.usage()))
  return reject(session, problem, problem.file, 2)
end

# `fmt --tree FILE`: the normal form of the file.
def fmt_tree(session: Session, file: String) -> Int
  case SourceReader.read(file)
    SourceFile.Read.Unreadable(_) -> return fmt_usage(session, "cannot read #{file}")
    SourceFile.Read.Invalid(at) ->
      return reject(session, Front.stage_problem(file, SourceFile.invalid_utf8(at)), file, 1)
    SourceFile.Read.Text(text) ->
      case CliFmt.tree(text)
        Diag.Outcome.Done(tree) -> return emit(Reply.printed(tree + "\n"))
        Diag.Outcome.Failed(problem) -> return reject(session, Front.stage_problem(file, problem), file, 1)
      end
  end
end

# `fmt -`: the standard input formatted to the standard output, with the settings of the working folder. A text that
# does not parse prints its diagnostic, and nothing goes to the standard output.
def fmt_stdin(session: Session) -> Int
  case StdinBuffer.take()
    StdinBuffer.Taken.Failed(message) -> return emit(Reply.failed(2, "agentica: #{message}\n"))
    StdinBuffer.Taken.Got(buffer) ->
      buffered = session.with(buffer_file: STDIN_NAME, buffer_shown: buffer.shown)
      case buffer.read
        SourceFile.Read.Unreadable(message) -> return emit(Reply.failed(2, "agentica: #{message}\n"))
        SourceFile.Read.Invalid(at) ->
          return reject(buffered, Front.stage_problem(STDIN_NAME, SourceFile.invalid_utf8(at)), STDIN_NAME, 1)
        SourceFile.Read.Text(text) ->
          workspace = session.settings.workspace
          settings = CliFmt.settings_of(workspace, CliFmt.manifest_dir(workspace, "."))
          if !settings.ok?
            return reject(buffered, Front.link_problem(Failure.unpack_failure(settings.message)), STDIN_NAME, 1)
          end

          case CliFmt.verdict(text, settings.unwrap!)
            CliFmt.Verdict.Same -> print(text)
            CliFmt.Verdict.Changed(output) -> print(output)
            CliFmt.Verdict.Refused(problem) ->
              return reject(buffered, Front.stage_problem(STDIN_NAME, problem), STDIN_NAME, 1)
          end

          return 0
      end
  end
end

# Formats one file with `settings` (or the failure of its manifest): with `checking` it prints the path of a file that
# formatting would change, else it writes the new text in place. Gives the status of the file: 0 when it is formatted,
# 1 for a change found by `--check`, a file that does not parse or a bad manifest, 2 for a file that cannot be read or
# written.
def fmt_file(session: Session, file: String, settings: Result[Format.Settings], checking: Bool) -> Int
  if !settings.ok?
    return reject(session, Front.link_problem(Failure.unpack_failure(settings.message)), file, 1)
  end

  case SourceReader.read(file)
    SourceFile.Read.Unreadable(_) ->
      IO.warn("agentica: cannot read #{file}")
      return 2
    SourceFile.Read.Invalid(at) ->
      return reject(session, Front.stage_problem(file, SourceFile.invalid_utf8(at)), file, 1)
    SourceFile.Read.Text(text) ->
      case CliFmt.verdict(text, settings.unwrap!)
        CliFmt.Verdict.Same -> return 0
        CliFmt.Verdict.Changed(output) ->
          if checking
            puts(file)
            return 1
          end

          written = SaveFile.replace(file, output.bytes, true, SAVE_TIMEOUT)
          if !written.ok?
            IO.warn("agentica: cannot write #{file}: #{written.message}")
            return 2
          end

          return 0
        CliFmt.Verdict.Refused(problem) -> return reject(session, Front.stage_problem(file, problem), file, 1)
      end
  end
end

# Checks every file of `paths`, prints the problem of each file that fails (the first one of each, as for one file) and
# the count, and gives 1 when any failed. A path that names no file or folder, or a folder with no `.agc` file, is a
# usage error before any file is checked.
def check_all(session: Session, paths: List[String]) -> Int
  case SymbolPaths.expand(session.settings.workspace, paths, "", CliCheck.usage())
    SymbolPaths.Expanded.Refused(problem) -> return answered(session, Reply.Answer.Rejected(problem), "")
    SymbolPaths.Expanded.Files(roots) ->
      entries = roots.map do |root: SymbolPaths.Root| check_entry(session, root.typed) end
      return report(session, entries)
  end
end

def check_entry(session: Session, file: String) -> CliCheck.Entry
  settings = CheckCache.attach(session.settings, file, !session.options.no_cache)
  case Core.check(Cache.empty(), settings, file)
    Core.Verdict.Passed -> return CliCheck.Entry.Passed(file)
    Core.Verdict.Unreadable -> return CliCheck.Entry.Unreadable(file)
    Core.Verdict.Rejected(problem) -> return CliCheck.Entry.Failed(file, Core.named(session.settings, problem, file))
  end
end

# The answer of a run over several files. The JSON form is one document on stdout; the others print each problem on
# stderr, in the order of the files, then the count. The status is 2 when a file could not be read (QUERY- problems
# are status 2), else 1 when a file failed.
def report(session: Session, entries: List[CliCheck.Entry]) -> Int
  failed = CliCheck.failures(entries)
  if session.options.style == "json"
    print(CliCheck.json_text(entries))
    return CliCheck.status(entries)
  end

  for entry in entries
    show_entry(session, entry)
  end

  if failed == 0
    return emit(Reply.printed(CliCheck.ok_text(entries.size)))
  end

  return emit(Reply.failed(CliCheck.status(entries), CliCheck.failed_text(failed, entries.size)))
end

def show_entry(session: Session, entry: CliCheck.Entry) -> Void
  case entry
    CliCheck.Entry.Passed(_) -> return
    CliCheck.Entry.Unreadable(file) -> IO.warn("agentica: cannot read #{file}")
    CliCheck.Entry.Failed(file, problem) ->
      text = render(session, problem, file)
      if session.options.style == "ai"
        text = CliCheck.headed(file, text)
      end

      IO.warn(text)
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
    settings = CheckCache.attach(session.settings, source, !session.options.no_cache)
    return verdict(session, source, Core.check(Cache.empty(), settings, source))
  end

  plan = cache_plan(session, verb, source)
  case BytecodeCache.lookup(plan, session.settings)
    BytecodeCache.Lookup.Hit(bytes) -> return start(session, rest, bytes)
    BytecodeCache.Lookup.Miss -> return read(session, verb, rest, plan)
  end
end

# The bytecode cache (io/bytecode_cache.agc) serves a run: not `compile`, which is the explicit way to build a file,
# nor a listing of the tree or the IR, and not `--no-cache`. `check` never gets here.
def cache_plan(session: Session, verb: String, source: String) -> BytecodeCache.Plan
  options = session.options
  wanted = verb != "compile" and !options.no_cache and !options.dump and !options.dump_ir
  return BytecodeCache.plan(session.settings, source, wanted)
end

def read(session: Session, verb: String, rest: List[String], plan: BytecodeCache.Plan) -> Int
  source = rest[0]
  case Front.read_root(session.settings.workspace, source)
    Front.Root.Unreadable(_) -> return emit(Reply.failed(2, "agentica: cannot read #{source}\n"))
    Front.Root.Invalid(problem) -> return reject(session, problem, source, 1)
    Front.Root.Readable -> return linked(session, verb, rest, plan)
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

def linked(session: Session, verb: String, rest: List[String], plan: BytecodeCache.Plan) -> Int
  source = rest[0]
  case Front.check_file(source, session.settings)
    Front.Outcome.Rejected(problem) -> return reject(session, problem, source, 1)
    Front.Outcome.Done(front) -> return checked(session, verb, rest, front, plan)
  end
end

# What is done with a program that checked, in a fixed order.
def checked(session: Session, verb: String, rest: List[String], front: Front.Checked, plan: BytecodeCache.Plan) -> Int
  source = rest[0]
  if session.options.dump
    return emit(Reply.printed("#{CheckText.program_text(front.linked, front.checked)}\n"))
  elsif session.options.dump_ir
    return dump_ir(session, source, front)
  end

  case Pipeline.build_cached(front, session.settings, plan)
    Pipeline.Compiled.Rejected(problem) -> return reject(session, problem, source, 1)
    Pipeline.Compiled.Bytes(bytes) ->
      if verb == "compile"
        return save(rest[2], bytes)
      end

      return start(session, rest, bytes)
  end
end

# Runs the program `bytes`: the VM gets the options in a fixed order, and the program its arguments.
def start(session: Session, rest: List[String], bytes: Bytes) -> Int
  launch = Launch.Launch(bytes: bytes, flags: vm_flags(session.options, rest[0]), arguments: rest.drop(1))
  return session.hand_off.call(launch)
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

  if options.jit != ""
    flags = flags.concat(["--jit", options.jit])
  end

  flags = flags.concat(options.deny)
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
def save(output: String, bytes: Bytes) -> Int
  if !SaveFile.bytes(output, bytes, SAVE_TIMEOUT).ok?
    return emit(Reply.failed(2, "agentica: cannot write #{output}\n"))
  end

  return 0
end

# The first problem of a stage, in the form the options ask for, on stderr, with exit status `status`. A problem in the
# root file names it as it was typed (the linker knows it by its absolute path), and one in an imported file by its
# canonical path. A problem of the arguments (`<arguments>`) has no source lines to show.
def reject(session: Session, problem: Problems.Problem, source: String, status: Int) -> Int
  show(session, problem, source)
  return status
end

# Prints the problem as `reject` says, and leaves the status to the caller.
def show(session: Session, problem: Problems.Problem, source: String) -> Void
  IO.warn(render(session, problem, source))
end

# The problem in the form the style asks for, without the line feed that IO.warn adds.
def render(session: Session, problem: Problems.Problem, source: String) -> String
  style = session.options.style
  root = Core.root?(problem.file, source, session.settings)
  shown = Core.named(session.settings, problem, source)
  if style == "json"
    return JSON.encode(DiagnosticJson.json(shown))
  end

  text = ""
  if Problems.at_source?(problem) and !QueryOptions.arguments?(problem)
    text = source_text(session, problem.file, root)
  end

  if style == "ai" and QueryOptions.arguments?(problem)
    return Ai.ai(QueryOptions.unplaced(shown), text)
  elsif style == "ai"
    return Ai.ai(shown, text)
  elsif QueryOptions.arguments?(problem)
    return Plain.without_source(shown)
  end

  return Plain.format(shown, text)
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

  # The test files run in VMs that the driver starts, which do not get the flags, so they are refused instead of being
  # dropped without a word. Those VMs inherit AGENTICA_SCHEDULERS and AGENTICA_JIT, which set them for all of them.
  if options.schedulers != ""
    return emit(Reply.failed(2, "agentica: test does not take --schedulers; set AGENTICA_SCHEDULERS instead\n"))
  end

  if options.jit != ""
    return emit(Reply.failed(2, "agentica: test does not take --jit; set AGENTICA_JIT instead\n"))
  end

  driver: List[String] = [
    "--vm",
    binary,
    "--version",
    session.settings.version,
    "--style",
    options.style,
    "--test-timeout-ms",
    "30000",
  ]
  if options.seed != ""
    driver = driver.concat(["--seed", options.seed])
  end

  driver = driver.concat(["--agentica", binary, "--"])
  for steps in options.steps
    driver = driver.concat(["--steps", steps])
  end

  # The --deny-* flags and --sandbox in front of `test` mean the same as after it, where the driver reads them.
  driver = driver.concat(options.deny)
  if options.no_cache
    driver = driver.push("--no-cache")
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
