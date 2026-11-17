## The command line of `agentica`: the entry point of the front end, `run`. It reads the options, then does what the
## first word asks: run a program, `check` it, `compile` it to a file, print `help`, print the API of a module with
## `doc`, format files with `fmt`, suggest style changes with `lint`, list the declarations of a file with `outline`,
## give the type at a position with `type-at`, list the references to a name with `refs`, write the packages of the
## lock to deps/ with `install`, change the packages with `add` and `update`, or start the tests.
##
## `run` takes everything it cannot know from outside (docs/vm/08-loader-and-cli.md §9): the
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
import CheckText from "../check/check_text"
import Ai from "../diagnostics/diagnostic_ai"
import Diag from "../diagnostics/diagnostic"
import DiagnosticJson from "../diagnostics/diagnostic_json"
import Plain from "../diagnostics/diagnostic_plain"
import Problems from "../diagnostics/problem"
import Format from "../format/format"
import BytecodeCache from "../io/bytecode_cache"
import CheckCache from "../io/check_cache"
import NativeBuild from "../io/native_build"
import SaveFile from "../io/save_file"
import SourceReader from "../io/source_reader"
import StdinBuffer from "../io/stdin_buffer"
import LowerText from "../lower/lower_text"
import Lowering from "../lower/lowering"
import Paths from "../modules/import_path"
import Env from "../modules/link_env"
import Failure from "../modules/link_failure"
import Resolve from "../modules/resolve_import"
import Workspace from "../modules/workspace"
import QueryFiles from "../query/query_files"
import QueryOptions from "../query/query_options"
import QueryPosition from "../query/query_position"
import SymbolPaths from "../query/symbol_paths"
import SourceFile from "../syntax/source_file"
import Add from "cli_add"
import CliCheck from "cli_check"
import CliDoc from "cli_doc"
import CliFmt from "cli_fmt"
import CliLint from "cli_lint"
import Help from "cli_help"
import HelpStd from "cli_help_std"
import Install from "cli_install"
import Launch from "cli_launch"
import Options from "cli_options"
import CliQuery from "cli_query"
import Repl from "cli_repl"
import Reply from "cli_reply"
import CliRun from "cli_run"
import Texts from "cli_text"
import Pipeline from "pipeline"

## Runs the command line `args` (the words after the program name) and gives the exit status. Everything it writes goes
## to the standard streams of this process. `cache_missed` says that the launcher (cli_hit.agc) looked for the cache
## entry of this run and found none it could use, so a run of a source file does not look again. `stderr_tty` says that
## stderr is a terminal: a run that compiles its program says so there.
def run(
  settings: Env.Settings,
  args: List[String],
  cache_missed: Bool,
  stderr_tty: Bool,
  hand_off: Fn[Launch.Launch, Int],
) -> Int
  case Options.parse(args, settings.version)
    Options.Parsed.Answer(reply) -> emit(reply)
    Options.Parsed.Ready(options) ->
      dispatch(
        Session(
          options: options,
          settings: settings,
          hand_off: hand_off,
          buffer_file: "",
          buffer_shown: "",
          cache_missed: cache_missed,
          stderr_tty: stderr_tty,
          compiling_since: -1,
        ),
      )
  end
end

private

# The deadline of each call that writes the output of `compile` or a file of `fmt`, in milliseconds.
SAVE_TIMEOUT = 60_000
# The name of the standard input in the diagnostics of `fmt -`.
STDIN_NAME = "<stdin>"
# The verb of `compile` with no -o, which fills the bytecode cache, and the file it looks for when no file is named.
AHEAD = "compile ahead"
MAIN_FILE = "main.agc"
SKIPPED_FOLDERS = ["tests", "fixtures"]

# The JSON line of one file of `compile` with no -o: `compiled` or `fresh`.
struct Ahead
  file: String
  state: String
end

# What one run is given besides the words of the user: the options read in front of them, the settings and the
# hand-off. `buffer_file` is the file whose text came from standard input ("" for none), and `buffer_shown` that text
# for the lines of a message. `compiling_since` is the monotonic time a run's notice started (-1 for none).
struct Session
  options: Options.Options
  settings: Env.Settings
  hand_off: Fn[Launch.Launch, Int]
  buffer_file: String
  buffer_shown: String
  cache_missed: Bool
  stderr_tty: Bool
  compiling_since: Int
end

# The first word picks the command; a word that is not a command is the source file of a run.
def dispatch(session: Session) -> Int
  words = session.options.words
  first = ""
  if words.size > 0
    first = words[0]
  end

  return program(building(session, first), first, words) if CliRun.file_run?(words)

  if first == "test"
    return test(session, words.drop(1))
  elsif first == "help"
    return help(session, words)
  elsif first == "doc"
    return doc(session, words)
  elsif first == "fmt"
    return fmt(session, words.drop(1))
  elsif first == "lint"
    return lint(session, words.drop(1))
  elsif first == "install"
    return install(building(session, "install"), words.drop(1))
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
  elsif first == "repl"
    return Repl.run(session.settings, session.options, words.drop(1), session.stderr_tty)
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
  if first == "compile" and !rest.include?("-o")
    return compile_ahead(session, rest)
  elsif first == "compile"
    usable = rest.size == 3 and rest[1] == "-o" and !session.options.dump and !session.options.dump_ir
  end

  return emit(Reply.failed(2, Texts.usage_text())) if !usable

  program(building(session, first), first, rest)
end

# The session whose workspace builds the native modules of the project and its packages from their C sources
# (io/native_build.agc): a run, `compile`, `test` and `install` do, so the program they run or write opens the library;
# `check`, the queries and the other commands never start a compiler.
def building(session: Session, verb: String) -> Session
  settings = builder_settings(session.settings, session.options.deny, session.options.style, verb)
  session.with(settings: settings)
end

# The settings with the builder of `verb`. Under any --deny-* flag or --sandbox the VM refuses native code, so nothing
# is built: `compile`, whose output may later run without the flag, refuses the module (PKG-NATIVE-BUILD); a run,
# `test` and `install` build nothing, and the program names the library by its bare name, which the VM refuses with
# the rest of the native code (RUNTIME-NATIVE-DENIED, on a bytecode cache hit as on a miss: the cache keeps such
# programs apart, Settings.native_denied). With `--json` or `--ai` the builder prints nothing, so stderr holds only
# the diagnostic and the warning of an optional module that was not built (PKG-NATIVE-UNBUILT), one line or block
# each.
def builder_settings(settings: Env.Settings, deny: List[String], style: String, verb: String) -> Env.Settings
  if deny.size == 0
    warned: Fn[String, Void] = &warn_plain
    if style == "json"
      warned = &warn_json
    elsif style == "ai"
      warned = &warn_ai
    end

    builder: Fn[Workspace.BuildRequest, Workspace.Built] = NativeBuild.builder(style == "plain", warned)
    return settings.with(workspace: settings.workspace.with(native_build: builder))
  end

  denied = CliRun.settings(settings, deny)
  if verb == "compile"
    refusing: Fn[Workspace.BuildRequest, Workspace.Built] = NativeBuild.refusing(deny[0])
    return denied.with(workspace: settings.workspace.with(native_build: refusing))
  end

  denied
end

# The warning that a packed failure holds, on stderr: `warning: MESSAGE` in plain text, the JSON object of the problem
# with `"warning": true`, or the compact form with `warning` as its first line.
def warn_plain(packed: String) -> Void
  IO.warn("warning: #{Failure.unpack_failure(packed).diagnostic.message}")
end

def warn_json(packed: String) -> Void
  IO.warn(JSON.encode(DiagnosticJson.warning(Front.link_problem(Failure.unpack_failure(packed)))))
end

def warn_ai(packed: String) -> Void
  IO.warn(Ai.warning(Front.link_problem(Failure.unpack_failure(packed))))
end

# `help`: the builtins from the catalog, or a module of `std/` as `doc` reads it.
def help(session: Session, words: List[String]) -> Int
  return answered(session, HelpStd.run(words, session.options.style, session.settings), "") if HelpStd.asks?(words)

  emit(Help.help(words, session.options.style))
end

# `doc PATH`: a complete answer, or the first problem of the module, shown as a problem of PATH.
def doc(session: Session, words: List[String]) -> Int
  answered(session, CliDoc.run(words, session.options.style, session.settings), "")
end

# `install`: it takes no word; the project is the one of the working folder.
def install(session: Session, words: List[String]) -> Int
  return emit(Reply.failed(2, Texts.usage_text())) if words.size != 0

  answered(session, Install.run(session.settings, session.options.style), "")
end

# What a command gave: print the answer, or reject the first problem of the program. A QUERY- problem is a mistake in
# the question, exit status 2; any other is a mistake in the program, exit status 1. `source` is the file as the user
# typed it ("" for the file of the problem).
def answered(session: Session, answer: Reply.Answer, source: String) -> Int
  case answer
    Reply.Answer.Printed(reply) -> emit(reply)
    Reply.Answer.Rejected(problem) ->
      status = 1
      if problem.code.start_with?("QUERY-")
        status = 2
      end

      return reject(session, problem, problem.file, status) if source == ""

      reject(session, problem, source, status)
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
    QueryOptions.Parsed.Refused(problem) -> answered(session, Reply.Answer.Rejected(problem), "")
    QueryOptions.Parsed.Ready(asked) ->
      styled = session.with(options: session.options.with(style: asked.style))
      case QueryFiles.pick(asked, usage)
        QueryFiles.Picked.Refused(problem) -> answered(styled, Reply.Answer.Rejected(problem), "")
        QueryFiles.Picked.File(file) ->
          return position(styled, file, asked, usage) if verb != "outline"

          if asked.stdin == ""
            return answered(styled, CliQuery.outline(file, asked.style, false, styled.settings), file)
          end

          with_buffer(styled, file) do |buffered: Session|
            answered(buffered, CliQuery.outline(file, asked.style, true, buffered.settings), file)
          end
      end
  end
end

# `symbol NAME [PATH...]`. With `--stdin FILE` the text of FILE is the standard input and FILE is searched as well; a
# problem in FILE is shown against the buffer.
def symbol(session: Session, words: List[String]) -> Int
  case QueryOptions.parse(words, session.options.style, CliQuery.symbol_usage(), false)
    QueryOptions.Parsed.Refused(problem) -> answered(session, Reply.Answer.Rejected(problem), "")
    QueryOptions.Parsed.Ready(asked) ->
      styled = session.with(options: session.options.with(style: asked.style))
      return answered(styled, CliQuery.symbol(asked, styled.settings), "") if asked.stdin == ""

      with_buffer(styled, asked.stdin) do |buffered: Session|
        answered(buffered, CliQuery.symbol(asked, buffered.settings), asked.stdin)
      end
  end
end

# `refs NAME|FILE:LINE:COL [PATH...]`. With `--stdin FILE:LINE:COL` the text of FILE is the standard input and stands
# in for the first word; with `--stdin FILE` and a NAME it is searched as one more file, as for `symbol`. `--partial`
# goes with a position alone (`CliQuery.refs_ask`).
def refs(session: Session, words: List[String]) -> Int
  case QueryOptions.parse(words, session.options.style, CliQuery.refs_usage(), true)
    QueryOptions.Parsed.Refused(problem) -> answered(session, Reply.Answer.Rejected(problem), "")
    QueryOptions.Parsed.Ready(asked) ->
      styled = session.with(options: session.options.with(style: asked.style))
      case CliQuery.refs_ask(asked)
        CliQuery.RefsAsk.Refused(problem) -> answered(styled, Reply.Answer.Rejected(problem), "")
        CliQuery.RefsAsk.At(position, paths) ->
          if asked.stdin == ""
            found = CliQuery.refs_at(position, paths, asked.style, asked.partial, styled.settings)
            return answered(styled, found, position.file)
          end

          with_buffer(styled, position.file) do |read: Session|
            answered(read, CliQuery.refs_at(position, paths, asked.style, asked.partial, read.settings), position.file)
          end

        CliQuery.RefsAsk.Named(name, paths) ->
          if asked.stdin == ""
            return answered(styled, CliQuery.refs_named(name, paths, "", asked.style, styled.settings), "")
          end

          with_buffer(styled, asked.stdin) do |read: Session|
            answered(read, CliQuery.refs_named(name, paths, asked.stdin, asked.style, read.settings), asked.stdin)
          end
      end
  end
end

# `type-at FILE:LINE:COL`, or the same with `--stdin`, where the text of FILE is the standard input. `options` are the
# words of the command: the style, `--stdin` and `--partial`.
def position(session: Session, word: String, options: QueryOptions.Query, usage: String) -> Int
  case QueryPosition.parse(word, usage)
    QueryPosition.Parsed.Refused(problem) -> answered(session, Reply.Answer.Rejected(problem), "")
    QueryPosition.Parsed.Ready(asked) ->
      return answered(session, type_at(session, asked, options.partial), asked.file) if options.stdin == ""

      with_buffer(session, asked.file) do |read: Session|
        answered(read, type_at(read, asked, options.partial), asked.file)
      end
  end
end

# The answer of `type-at`, with the cache of checked modules of the project of the file unless `--no-cache`.
def type_at(session: Session, asked: QueryPosition.Asked, partial: Bool) -> Reply.Answer
  settings = CheckCache.attach(session.settings, asked.file, !session.options.no_cache)
  CliQuery.type_at(asked, session.options.style, partial, settings)
end

# `check [PATH...]`: one file, or every `.agc` file of the folders and files named (none: the working folder). One file
# answers as `check` always did; anything else checks every file and ends with a count (`check_all`). `--json` and
# `--ai` may stand among the paths, as for the query commands; `--stdin` after a path would check the disk while the
# caller means the buffer, so it is a usage error.
def check(session: Session, words: List[String]) -> Int
  return emit(Reply.failed(2, Texts.usage_text())) if words.any? do |word: String| word == "--stdin" end

  case QueryOptions.parse(words, session.options.style, CliCheck.usage(), false)
    QueryOptions.Parsed.Refused(problem) -> answered(session, Reply.Answer.Rejected(problem), "")
    QueryOptions.Parsed.Ready(asked) ->
      styled = session.with(options: session.options.with(style: asked.style))
      if asked.words.size == 1 and !styled.settings.workspace.directory_exists.call(asked.words[0])
        return program(styled, "check", asked.words)
      end

      check_all(styled, asked.words)
  end
end

# `fmt [PATH...]`, `fmt --check [PATH...]`, `fmt -` and `fmt --tree FILE` (cli_fmt.agc). Any other form, an option
# among the paths (a file named -x.agc is written ./-x.agc), a missing path and a folder with no `.agc` file are
# FMT-USAGE, status 2.
def fmt(session: Session, words: List[String]) -> Int
  if words.size > 0 and words[0] == "--tree"
    return fmt_usage(session, "--tree takes one FILE") if words.size != 2

    return fmt_tree(session, words[1])
  elsif words.size > 0 and words[0] == "-"
    return fmt_usage(session, "- reads one file from standard input and takes no PATH") if words.size != 1

    return fmt_stdin(session)
  end

  checking = words.size > 0 and words[0] == "--check"
  paths = words
  if checking
    paths = words.drop(1)
  end

  for path in paths
    if path.start_with?("-")
      return fmt_usage(session, "unknown option #{path} (a file whose name starts with - is written ./#{path})")
    end
  end

  case SymbolPaths.expand(session.settings.workspace, paths, "", CliFmt.usage())
    SymbolPaths.Expanded.Refused(problem) -> reject(session, problem.with(code: "FMT-USAGE"), problem.file, 2)
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

      status
  end
end

# `lint [PATH...] [--strict]` (cli_lint.agc): the style suggestions of every `.agc` file of the paths, as `check` finds
# them (none: the working folder). Suggestions go to the standard output and exit 0; `--strict` makes any of them
# exit 1. A file that does not parse prints its diagnostic and exits 1, one that cannot be read exits 2. `--stdin` is a
# usage error, as for `check` with several files.
def lint(session: Session, words: List[String]) -> Int
  strict = words.include?("--strict")
  rest = words.select do |word: String| word != "--strict" end
  if rest.include?("--stdin")
    return answered(
      session,
      Reply.Answer.Rejected(QueryOptions.refusal("lint reads files, not standard input", CliLint.usage())),
      "",
    )
  end

  case QueryOptions.parse(rest, session.options.style, CliLint.usage(), false)
    QueryOptions.Parsed.Refused(problem) -> answered(session, Reply.Answer.Rejected(problem), "")
    QueryOptions.Parsed.Ready(asked) ->
      styled = session.with(options: session.options.with(style: asked.style))
      case SymbolPaths.expand(styled.settings.workspace, asked.words, "", CliLint.usage())
        SymbolPaths.Expanded.Refused(problem) -> answered(styled, Reply.Answer.Rejected(problem), "")
        SymbolPaths.Expanded.Files(roots) ->
          entries = roots.map do |root: SymbolPaths.Root| lint_entry(root.typed) end
          lint_report(styled, entries, strict)
      end
  end
end

def lint_entry(file: String) -> CliLint.Entry
  case SourceReader.read(file)
    SourceFile.Read.Unreadable(_) -> CliLint.Entry.Unreadable(file)
    SourceFile.Read.Invalid(at) -> CliLint.Entry.Unparsed(file, Front.stage_problem(file, SourceFile.invalid_utf8(at)))
    SourceFile.Read.Text(text) -> CliLint.entry(file, text)
  end
end

# The answer of a run of `lint`. The JSON form is one document on stdout; the others print the suggestions and the
# last line (the count, or `lint failed` when a file did not parse or read) on stdout, and the diagnostics of the files
# that did not parse or read on stderr, in the order of the files.
def lint_report(session: Session, entries: List[CliLint.Entry], strict: Bool) -> Int
  if session.options.style == "json"
    print(CliLint.json_text(entries))
    return CliLint.status(entries, strict)
  end

  for entry in entries
    show_lint_entry(session, entry)
  end

  print(CliLint.summary_text(entries))
  CliLint.status(entries, strict)
end

def show_lint_entry(session: Session, entry: CliLint.Entry) -> Void
  case entry
    CliLint.Entry.Clean(_) -> return
    CliLint.Entry.Suggested(_, found) -> print(CliLint.suggestions_text(found))
    CliLint.Entry.Unparsed(file, problem) ->
      text = render(session, problem, file)
      if session.options.style == "ai"
        text = CliCheck.headed(file, text)
      end

      IO.warn(text)
    CliLint.Entry.Unreadable(file) -> IO.warn("agentica: cannot read #{file}")
  end
end

def fmt_usage(session: Session, message: String) -> Int
  problem = QueryOptions.at_arguments("FMT-USAGE", message, Diag.Help.Hint(CliFmt.usage()))
  reject(session, problem, problem.file, 2)
end

# `fmt --tree FILE`: the normal form of the file.
def fmt_tree(session: Session, file: String) -> Int
  case SourceReader.read(file)
    SourceFile.Read.Unreadable(_) -> fmt_usage(session, "cannot read #{file}")
    SourceFile.Read.Invalid(at) -> reject(session, Front.stage_problem(file, SourceFile.invalid_utf8(at)), file, 1)
    SourceFile.Read.Text(text) ->
      case CliFmt.tree(text)
        Diag.Outcome.Done(tree) -> emit(Reply.printed(tree + "\n"))
        Diag.Outcome.Failed(problem) -> reject(session, Front.stage_problem(file, problem), file, 1)
      end
  end
end

# `fmt -`: the standard input formatted to the standard output, with the settings of the working folder. A text that
# does not parse prints its diagnostic, and nothing goes to the standard output.
def fmt_stdin(session: Session) -> Int
  case StdinBuffer.take()
    StdinBuffer.Taken.Failed(message) -> emit(Reply.failed(2, "agentica: #{message}\n"))
    StdinBuffer.Taken.Got(buffer) ->
      buffered = session.with(buffer_file: STDIN_NAME, buffer_shown: buffer.shown)
      case buffer.read
        SourceFile.Read.Unreadable(message) -> emit(Reply.failed(2, "agentica: #{message}\n"))
        SourceFile.Read.Invalid(at) ->
          reject(buffered, Front.stage_problem(STDIN_NAME, SourceFile.invalid_utf8(at)), STDIN_NAME, 1)
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

          0
      end
  end
end

# Formats one file with `settings` (or the failure of its manifest): with `checking` it prints the path of a file that
# formatting would change, else it writes the new text in place. Gives the status of the file: 0 when it is formatted,
# 1 for a change found by `--check`, a file that does not parse or a bad manifest, 2 for a file that cannot be read or
# written.
def fmt_file(session: Session, file: String, settings: Result[Format.Settings], checking: Bool) -> Int
  return reject(session, Front.link_problem(Failure.unpack_failure(settings.message)), file, 1) if !settings.ok?

  case SourceReader.read(file)
    SourceFile.Read.Unreadable(_) ->
      IO.warn("agentica: cannot read #{file}")
      2
    SourceFile.Read.Invalid(at) -> reject(session, Front.stage_problem(file, SourceFile.invalid_utf8(at)), file, 1)
    SourceFile.Read.Text(text) ->
      case CliFmt.verdict(text, settings.unwrap!)
        CliFmt.Verdict.Same -> 0
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

          0
        CliFmt.Verdict.Refused(problem) -> reject(session, Front.stage_problem(file, problem), file, 1)
      end
  end
end

# Checks every file of `paths`, prints the problem of each file that fails (the first one of each, as for one file) and
# the count, and gives 1 when any failed. A path that names no file or folder, or a folder with no `.agc` file, is a
# usage error before any file is checked.
def check_all(session: Session, paths: List[String]) -> Int
  case SymbolPaths.expand(session.settings.workspace, paths, "", CliCheck.usage())
    SymbolPaths.Expanded.Refused(problem) -> answered(session, Reply.Answer.Rejected(problem), "")
    SymbolPaths.Expanded.Files(roots) ->
      entries = roots.map do |root: SymbolPaths.Root| check_entry(session, root.typed) end
      report(session, once_each(session, entries, roots))
  end
end

# A problem of an imported file comes back in the entry of every file that imports it. It is kept once: in the entry of
# the file itself when that failed with it, else in the first importer; the other importers are skipped.
def once_each(session: Session, entries: List[CliCheck.Entry], roots: List[SymbolPaths.Root]) -> List[CliCheck.Entry]
  shown = Set.new(entries.map(&own_key))
  kept: List[CliCheck.Entry] = []
  for entry in entries
    case entry
      CliCheck.Entry.Failed(file, problem) if problem.file != file ->
        imported = imported_name(session, problem, roots)
        key = problem_key(imported, problem)
        if shown.include?(key)
          kept = kept.push(CliCheck.Entry.Skipped(file, imported))
        else
          shown = shown.add(key)
          kept = kept.push(entry)
        end

      _ -> kept = kept.push(entry)
    end
  end

  kept
end

# The key of the problem of an entry that failed in its own file, else "".
def own_key(entry: CliCheck.Entry) -> String
  case entry
    CliCheck.Entry.Failed(file, problem) if problem.file == file -> problem_key(file, problem)
    _ -> ""
  end
end

def problem_key(file: String, problem: Problems.Problem) -> String
  "#{file}:#{problem.key_path}:#{problem.code}:#{problem.span.start.offset}"
end

# The file of `problem` as typed when it is one of the roots, else as the problem names it.
def imported_name(session: Session, problem: Problems.Problem, roots: List[SymbolPaths.Root]) -> String
  for root in roots
    return root.typed if Core.root?(problem.file, root.typed, session.settings)
  end

  problem.file
end

def check_entry(session: Session, file: String) -> CliCheck.Entry
  case Core.check(Cache.empty(), check_settings(session, file), file)
    Core.Verdict.Passed -> CliCheck.Entry.Passed(file)
    Core.Verdict.Unreadable -> CliCheck.Entry.Unreadable(file)
    Core.Verdict.Rejected(problem) -> CliCheck.Entry.Failed(file, Core.named(session.settings, problem, file))
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

  return emit(Reply.printed(CliCheck.ok_text(entries.size))) if failed == 0

  emit(Reply.failed(CliCheck.status(entries), CliCheck.failed_text(failed, entries.size)))
end

def show_entry(session: Session, entry: CliCheck.Entry) -> Void
  case entry
    CliCheck.Entry.Passed(_) -> return
    CliCheck.Entry.Skipped(_, _) -> return
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
  return emit(Reply.failed(2, Texts.usage_text())) if files.size != 1 or !QueryOptions.file_name?(files[0])

  with_buffer(session, files[0]) do |buffered: Session| program(buffered, "check", files) end
end

# Takes the standard input as the text of `file` and gives `then` a session whose workspace answers it. A standard
# input that cannot be taken is status 2 and `then` never runs.
def with_buffer(session: Session, file: String, then: Fn[Session, Int]) -> Int
  case StdinBuffer.take()
    StdinBuffer.Taken.Failed(message) -> emit(Reply.failed(2, "agentica: #{message}\n"))
    StdinBuffer.Taken.Got(buffer) ->
      workspace = StdinBuffer.over(session.settings.workspace, session.settings.env.windows, file, buffer)
      then.call(
        session.with(
          settings: session.settings.with(workspace: workspace),
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
    return verdict(session, source, Core.check(Cache.empty(), check_settings(session, source), source))
  end

  plan = CliRun.cache_plan(session.options, session.settings, verb, source)
  if session.cache_missed and verb != "compile"
    return read(session, verb, rest, BytecodeCache.missed(plan, session.settings))
  end

  case BytecodeCache.lookup(plan, session.settings)
    BytecodeCache.Lookup.Hit(bytes) ->
      return save(rest[2], bytes) if verb == "compile"

      start(session, rest, bytes)
    BytecodeCache.Lookup.Miss(seen) -> read(session, verb, rest, seen)
  end
end

# A run that compiles its program says so on stderr when that is a terminal: `Compiling FILE…` once the file is read,
# and the module count and the time once it is built (`compiled`). `compile`, the listings and `--ai` or `--json` print
# nothing.
def noticed(session: Session, verb: String, source: String) -> Session
  options = session.options
  quiet = verb == "compile" or verb == AHEAD or options.dump or options.dump_ir or options.style != "plain"
  return session if !session.stderr_tty or quiet

  IO.warn("Compiling #{source}…")
  session.with(compiling_since: Time.monotonic_ms)
end

def compiled(session: Session, source: String, modules: Int) -> Void
  return if session.compiling_since < 0

  took = Time.monotonic_ms - session.compiling_since
  counted = "#{modules} modules"
  if modules == 1
    counted = "1 module"
  end

  IO.warn("Compiled #{source} (#{counted}) in #{took / 1000}.#{took % 1000 / 100}s")
end

# `compile [FILE...]`: fills the bytecode cache for each file (with none, every main.agc under the working folder, as
# `check` walks it, outside tests/ and fixtures/ folders) as a run with the same options would, and says of each
# whether it was compiled or fresh (a JSON line each with `--json`). A file that fails is reported and the others still
# compile; the status is the worst one.
def compile_ahead(session: Session, files: List[String]) -> Int
  options = session.options
  if options.no_cache or options.dump or options.dump_ir or files.any? do |file: String| file.start_with?("-") end
    return emit(Reply.failed(2, Texts.usage_text()))
  end

  return ahead_each(session, files) if files.size > 0

  no_main = Reply.failed(2, "agentica: no #{MAIN_FILE} under this folder\n")
  case SymbolPaths.expand(session.settings.workspace, [], "", "")
    SymbolPaths.Expanded.Refused(problem) ->
      return emit(no_main) if problem.message.start_with?("no ")

      emit(Reply.failed(2, "agentica: #{problem.message}\n"))
    SymbolPaths.Expanded.Files(roots) ->
      files = roots.map do |root: SymbolPaths.Root| root.typed end
      mains = files.select(&entry_point?)
      return emit(no_main) if mains.size == 0

      ahead_each(session, mains)
  end
end

# A main.agc that is no test or fixture of the project.
def entry_point?(file: String) -> Bool
  parts = file.split("/")
  Paths.last_part(file) == MAIN_FILE and !parts.any? do |part: String| SKIPPED_FOLDERS.include?(part) end
end

def ahead_each(session: Session, files: List[String]) -> Int
  worst = 0
  for file in files
    status = ahead(building(session, file), file)
    if status > worst
      worst = status
    end
  end

  worst
end

def ahead_done(session: Session, file: String, state: String) -> Int
  return emit(Reply.printed("#{JSON.encode(Ahead(file: file, state: state))}\n")) if session.options.style == "json"

  emit(Reply.printed("#{state} #{file}\n"))
end

def ahead(session: Session, file: String) -> Int
  plan = CliRun.cache_plan(session.options, session.settings, file, file)
  case BytecodeCache.lookup(plan, session.settings)
    BytecodeCache.Lookup.Hit(_) -> ahead_done(session, file, "fresh")
    BytecodeCache.Lookup.Miss(seen) -> read(session, AHEAD, [file], seen)
  end
end

# The settings `check` reads `file` with: the check cache. Whether the file is a test is the check's own
# (analysis/analysis.agc, modules/test_files.agc).
def check_settings(session: Session, file: String) -> Env.Settings
  CheckCache.attach(session.settings, file, !session.options.no_cache)
end

def read(session: Session, verb: String, rest: List[String], plan: BytecodeCache.Plan) -> Int
  source = rest[0]
  case Front.read_root(session.settings.workspace, source)
    Front.Root.Unreadable(_) -> emit(Reply.failed(2, "agentica: cannot read #{source}\n"))
    Front.Root.Invalid(problem) -> reject(session, problem, source, 1)
    Front.Root.Readable -> linked(noticed(session, verb, source), verb, rest, plan)
  end
end

# `check`: say that the program checks, or reject its first problem. `check` accepts a library file: only what is built
# to run (a run, `compile`) needs a main.
def verdict(session: Session, source: String, found: Core.Verdict) -> Int
  case found
    Core.Verdict.Unreadable -> emit(Reply.failed(2, "agentica: cannot read #{source}\n"))
    Core.Verdict.Rejected(problem) -> reject(session, problem, source, 1)
    Core.Verdict.Passed ->
      return emit(Reply.printed("{\"ok\":true}\n")) if session.options.style == "json"

      emit(Reply.printed("check ok\n"))
  end
end

def linked(session: Session, verb: String, rest: List[String], plan: BytecodeCache.Plan) -> Int
  source = rest[0]
  case Front.check_file(source, session.settings)
    Front.Outcome.Rejected(problem) -> reject(session, problem, source, 1)
    Front.Outcome.Done(front) -> checked(session, verb, rest, front, plan)
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
    Pipeline.Compiled.Rejected(problem) -> reject(session, problem, source, 1)
    Pipeline.Compiled.Bytes(bytes) ->
      return save(rest[2], bytes) if verb == "compile"
      return ahead_done(session, source, "compiled") if verb == AHEAD

      compiled(session, source, front.linked.modules.size)
      start(session, rest, bytes)
  end
end

# Runs the program `bytes`.
def start(session: Session, rest: List[String], bytes: Bytes) -> Int
  session.hand_off.call(CliRun.launch(session.options, rest, bytes))
end

# `--dump-ir`: the lowered program in the text form of lower_text.agc. It is not the `format-ir` of the former front
# end, which dropped what the bytecode needs.
def dump_ir(session: Session, source: String, front: Front.Checked) -> Int
  case Lowering.lower(front.linked, front.checked)
    Lowering.Lowered.Failed(problem) -> reject(session, problem, source, 1)
    Lowering.Lowered.Done(program) ->
      text = LowerText.program_text(program)
      emit(Reply.printed("#{text}\n"))
  end
end

# `compile`: the bytes to the file, which is created or emptied first.
def save(output: String, bytes: Bytes) -> Int
  if !SaveFile.bytes(output, bytes, SAVE_TIMEOUT).ok?
    return emit(Reply.failed(2, "agentica: cannot write #{output}\n"))
  end

  0
end

# The first problem of a stage, in the form the options ask for, on stderr, with exit status `status`. A problem in the
# root file names it as it was typed (the linker knows it by its absolute path), and one in an imported file by its
# canonical path. A problem of the arguments (`<arguments>`) has no source lines to show.
def reject(session: Session, problem: Problems.Problem, source: String, status: Int) -> Int
  show(session, problem, source)
  status
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
  return JSON.encode(DiagnosticJson.json(shown)) if style == "json"

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

  Plain.text_of(shown, text)
end

# The text that the lines of a message come from. A std/ module is not a file of the working folder: it goes straight
# to the provider of the settings (the stdlib/ folder or the binary), even when the folder has a std/ of its own. A
# file with bytes that are not UTF-8 shows them as U+FFFD. The root file of `check --stdin` is the text of the input.
def source_text(session: Session, file: String, root: Bool) -> String
  settings = session.settings
  if root and session.buffer_file != ""
    return session.buffer_shown
  elsif !root and file.start_with?("std/")
    return text_of(Resolve.read_source(settings, file))
  end

  text_of(SourceReader.read_shown(file))
end

def text_of(read: SourceFile.Read) -> String
  case read
    SourceFile.Read.Text(text) -> text
    SourceFile.Read.Invalid(_) -> ""
    SourceFile.Read.Unreadable(_) -> ""
  end
end

# `agentica test`: the BDD driver (bdd_driver.agc), in this process. The words after `test` go to it as they are,
# with the options in front of `test` and what only this process knows: the binary, which the driver starts again as
# `agentica run` for the runner and for the programs under test (and the programs under test start it for `agentica
# FILE`). A front end that was not told where the binary is (no --self) cannot do that: one line on stderr, status 2.
def test(session: Session, words: List[String]) -> Int
  options = session.options
  binary = session.settings.self_path
  return emit(Reply.failed(2, Texts.test_without_binary_text())) if binary == ""

  # The test files run in VMs that the driver starts, which do not get the flags, so they are refused instead of being
  # dropped without a word. Those VMs inherit AGENTICA_SCHEDULERS and AGENTICA_JIT, which set them for all of them.
  if options.schedulers != ""
    return emit(Reply.failed(2, "agentica: test does not take --schedulers; set AGENTICA_SCHEDULERS instead\n"))
  end

  return emit(Reply.failed(2, "agentica: test does not take --jit; set AGENTICA_JIT instead\n")) if options.jit != ""

  if options.coverage != ""
    return emit(Reply.failed(2, "agentica: test does not take --coverage FILE; use agentica test --coverage\n"))
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
    Opts.Parsed.Broken(message) -> emit(Reply.failed(2, "agentica: the test driver was started wrongly: #{message}\n"))
    Opts.Parsed.Usage(message, shown) -> finish(Report.usage(message, shown))
    Opts.Parsed.Ready(ready) ->
      # The --deny-* flags after `test` are the driver's (ready.deny holds those in front of it too), and so is the
      # style: the builder follows them, as for `agentica --deny-native test`.
      settings = builder_settings(session.settings, ready.deny, ready.style, "test")
      finish(Driver.run(ready, settings))
  end
end

def finish(ending: Report.Ending) -> Int = emit(Reply.Reply(code: ending.code, out: ending.text, err: ""))

# Writes the answer to the standard streams and gives its status. stderr text ends with a line feed that IO.warn adds.
def emit(reply: Reply.Reply) -> Int
  if reply.out != ""
    print(reply.out)
  end

  if reply.err != ""
    IO.warn(reply.err.slice(0, reply.err.length - 1))
  end

  reply.code
end
