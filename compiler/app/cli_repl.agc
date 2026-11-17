## `agentica repl`: reads entries from standard input, compiles each over the session (repl/repl_session.agc) and runs
## it in the session's child, `agentica run --session -` (vm/session.c), which keeps the loaded code, the names and the
## tasks between entries. An entry is one line, or more while the lines so far end inside it; an empty line drops a
## half entry. A line that starts with `:` at the start of an entry is a command.
##
## Plain style prints `=> VALUE : TYPE` for an entry that ends with an expression, and a problem on stderr; `--json`
## prints one JSON object per entry and command on stdout. The child prints what the entry prints (on stderr with
## `--json`). Exit status: 0 at the end of the input or after `:quit`, 1 when the input ends inside an entry, the
## child's status when it ends (`System.exit(n)` in an entry), 2 for a session that cannot start.

import Core from "../analysis/analysis"
import Diag from "../diagnostics/diagnostic"
import Ai from "../diagnostics/diagnostic_ai"
import DiagnosticJson from "../diagnostics/diagnostic_json"
import Plain from "../diagnostics/diagnostic_plain"
import Problems from "../diagnostics/problem"
import SourceReader from "../io/source_reader"
import Paths from "../modules/import_path"
import Env from "../modules/link_env"
import Repl from "../repl/repl_session"
import Source from "../syntax/source"
import SourceFile from "../syntax/source_file"
import Options from "cli_options"
import CliRun from "cli_run"

## Runs the session. `prompts` says to print a prompt before each line, as on a terminal.
def run(settings: Env.Settings, given: Options.Options, words: List[String], prompts: Bool) -> Int
  options = given
  for word in words
    if word == "--json"
      options = options.with(style: "json")
    elsif word == "--ai"
      options = options.with(style: "ai")
    else
      return usage()
    end
  end

  if settings.self_path == ""
    IO.warn("agentica: repl needs the path of the binary, which this front end was not given")
    return 2
  end

  flags = child_flags(options)
  case started(settings, flags, options.style)
    Start.Failed(message) ->
      IO.warn("agentica: #{message}")
      2
    Start.Running(loop) -> serve(loop.with(prompts: prompts and options.style == "plain"))
  end
end

private

# The virtual file of the session, in the working folder: imports resolve from there, and messages name it.
FILE = "(repl)"
# How long a write to the child or a wait for its answer may take, in milliseconds: an entry may run for long.
WAIT = 2_000_000_000
# The hex of at most this many bytes of program goes in one `chunk` line, which the child reads up to 1 MiB.
CHUNK = 262_144
COMMANDS = [
  [":type EXPR", "the type of an expression"],
  [":load FILE", "enter the text of a file"],
  [":reset", "start a new session"],
  [":quit", "end the session"],
  [":help", "this list"],
]

# The loop of a session: `items` is the number of entries and commands answered so far.
struct Loop
  session: Repl.Session
  child: Process
  settings: Env.Settings
  flags: List[String]
  style: String
  prompts: Bool
  items: Int = 0
end

enum Start
  Running(Loop)
  Failed(String)
end

# What the loop does after a line: read the next line with the text of an unfinished entry, or end with a status.
enum Step
  Next(Loop, String)
  Done(Int)
end

def usage() -> Int
  IO.warn("usage: agentica repl [--json | --ai]")
  2
end

# The options of the child: those of a run, without the JIT, the schedulers and coverage, which a session never takes.
def child_flags(options: Options.Options) -> List[String]
  flags = CliRun.launch(options, [FILE], "".bytes).flags
  kept: List[String] = []
  skip = false
  for flag in flags
    if skip
      skip = false
    elsif flag == "--jit" or flag == "--schedulers" or flag == "--coverage"
      skip = true
    else
      kept = kept.push(flag)
    end
  end

  kept
end

def started(settings: Env.Settings, flags: List[String], style: String) -> Start
  case Repl.start(FILE, settings)
    Repl.Started.Failed(problem) -> Start.Failed("the session cannot start: #{problem.code} #{problem.message}")
    Repl.Started.Ready(session, bytes) ->
      child = FrontEnd.spawn_session(settings.self_path, flags, style == "json")
      return Start.Failed(child.message) if !child.ok?

      sent = Process.send_bytes(child.unwrap!, bytes, WAIT)
      return Start.Failed(sent.message) if !sent.ok?

      closed = Process.close_stdin(child.unwrap!, WAIT)
      return Start.Failed(closed.message) if !closed.ok?

      loop = Loop(
        session: session,
        child: child.unwrap!,
        settings: settings,
        flags: flags,
        style: style,
        prompts: false,
      )

      Start.Running(loop)
  end
end

def serve(first: Loop) -> Int
  loop = first
  pending = ""
  while true
    prompt(loop, pending)
    line = IO.gets()
    if !line.ok?
      if pending != ""
        counted = next_item(loop)
        problem = repl_problem(counted, "REPL-INCOMPLETE", "the input ended inside an entry", pending)
        report(counted, problem, pending, counted.session.lines + 1)
        finish(counted)
        return 1
      end

      return finish(loop)
    end

    case step(loop, pending, line.unwrap!.replace("\r", ""))
      Step.Next(after, text) ->
        loop = after
        pending = text
      Step.Done(status) -> return status
    end
  end

  0
end

def prompt(loop: Loop, pending: String) -> Void
  return if !loop.prompts

  if pending == ""
    IO.print("agc> ")
  else
    IO.print("..   ")
  end

  IO.flush()
end

def step(loop: Loop, pending: String, line: String) -> Step
  if pending == "" and line.strip == ""
    return Step.Next(loop, "")
  elsif pending != "" and line.strip == ""
    counted = next_item(loop)
    answer(counted, counted.session.lines + 1, {"ok": JSON.from(true), "discarded": JSON.from(true)})
    return Step.Next(counted.with(session: Repl.typed(loop.session, pending)), "")
  elsif pending == "" and line.start_with?(":")
    return command(next_item(loop), line)
  end

  text = line
  if pending != ""
    text = "#{pending}\n#{line}"
  end

  entry(loop, text)
end

def next_item(loop: Loop) -> Loop = loop.with(items: loop.items + 1)

# A command, whose line counts as a line of the session.
def command(loop: Loop, line: String) -> Step
  words = line.strip.split(" ")
  name = words[0]
  rest = line.strip.slice(name.length, line.strip.length - name.length).strip
  at = loop.session.lines + 1
  after = loop.with(session: Repl.typed(loop.session, line))
  if name == ":quit"
    return Step.Done(finish(loop))
  elsif name == ":help"
    help(loop, at)
    return Step.Next(after, "")
  elsif name == ":reset"
    finish(loop)
    case started(loop.settings, loop.flags, loop.style)
      Start.Failed(message) ->
        IO.warn("agentica: #{message}")
        return Step.Done(2)
      Start.Running(fresh) ->
        answer(loop, at, {"ok": JSON.from(true), "reset": JSON.from(true)})
        return Step.Next(fresh.with(prompts: loop.prompts), "")
    end
  elsif name == ":type" and rest != ""
    typed(loop, rest, at)
    return Step.Next(after, "")
  elsif name == ":load" and rest != ""
    return load(after, rest, at)
  elsif name == ":type" or name == ":load"
    report(loop, repl_problem(loop, "REPL-USAGE", "#{name} takes #{usage_of(name)}", line), line, at)
    return Step.Next(after, "")
  end

  report(
    loop,
    repl_problem(loop, "REPL-UNKNOWN-COMMAND", "#{name} is not a command; :help lists them", line),
    line,
    at,
  )

  Step.Next(after, "")
end

def usage_of(name: String) -> String
  return "an expression" if name == ":type"

  "a file"
end

def help(loop: Loop, at: Int) -> Void
  if loop.style == "json"
    commands = COMMANDS.map do |pair: List[String]|
      JSON.object({"command": JSON.from(pair[0]), "does": JSON.from(pair[1])})
    end

    answer(loop, at, {"ok": JSON.from(true), "commands": JSON.array(commands)})
  else
    lines = COMMANDS.map { |pair: List[String]| "#{padded(pair[0], 13)}#{pair[1]}\n" }
    IO.print(lines.join(""))
    IO.flush()
  end
end

# `:type`: the type of `text`, which the command's line `at` holds.
def typed(loop: Loop, text: String, at: Int) -> Void
  case Repl.type_of(loop.session, text, loop.settings)
    Repl.Typed.Type(type) ->
      if loop.style == "json"
        answer(loop, at, {"ok": JSON.from(true), "type": JSON.from(type)})
      else
        puts(type)
        IO.flush()
      end

    Repl.Typed.Incomplete ->
      report(loop, repl_problem(loop, "REPL-INCOMPLETE", "the expression is not complete", text), text, at)
    Repl.Typed.Failed(problem) -> report(loop, problem, text, at)
  end
end

# `:load FILE`: the text of the file as one entry, after the command's line `at`.
def load(loop: Loop, file: String, at: Int) -> Step
  case SourceReader.read_shown(file)
    SourceFile.Read.Text(text) ->
      body = text
      while body.end_with?("\n")
        body = body.slice(0, body.length - 1)
      end

      case Repl.load(loop.session, file, folder_of(file), body, loop.settings)
        Repl.Compiled.Incomplete ->
          report(loop, repl_problem(loop, "REPL-INCOMPLETE", "the file ends inside an entry", body), body, at)
          Step.Next(loop.with(session: Repl.typed(loop.session, body)), "")
        Repl.Compiled.Failed(problem) ->
          report(loop, problem, body, at)
          Step.Next(loop.with(session: Repl.typed(loop.session, body)), "")
        Repl.Compiled.Run(request) -> ran(loop, body, request, at)
      end

    _ ->
      report(loop, Core.unreadable(file), "", at)
      Step.Next(loop, "")
  end
end

# The folder of a file from the working folder, which the session's imports start from.
def folder_of(file: String) -> String
  folder = Paths.directory_of(file)
  return folder if !Paths.rooted?(folder)

  Paths.stored_name(Path.cwd().unwrap_or(""), folder)
end

def entry(loop: Loop, text: String) -> Step
  case Repl.compile(loop.session, text, loop.settings)
    Repl.Compiled.Incomplete -> Step.Next(loop, text)
    Repl.Compiled.Failed(problem) ->
      counted = next_item(loop)
      report(counted, problem, text, loop.session.lines + 1)
      Step.Next(counted.with(session: Repl.typed(loop.session, text)), "")
    Repl.Compiled.Run(request) -> ran(next_item(loop), text, request, loop.session.lines + 1)
  end
end

# The answer of the child to an entry whose first line is `at`.
def ran(loop: Loop, text: String, request: Repl.Request, at: Int) -> Step
  answer = asked(loop.child, request)
  if !answer.ok?
    finish_quiet(loop)
    return Step.Done(ended(loop))
  end

  parsed = JSON.parse(answer.unwrap!)
  if !parsed.ok?
    IO.warn("agentica: the session's child gave an answer that is not JSON")
    finish(loop)
    return Step.Done(2)
  end

  root = parsed.unwrap!
  passed = flag(root, "ok")
  session = Repl.typed(loop.session, text)
  if passed
    session = request.ran
  elsif flag(root, "loaded")
    session = request.loaded
  end

  after = loop.with(session: session)
  refused = refusal(root)
  if refused != ""
    problem = repl_problem(loop, "REPL-REFUSED", "the session refused the entry: #{refused}", text)
    report(loop, problem, text, at)
  elsif loop.style == "json"
    answer(loop, at, json_answer(root, request, passed))
  elsif passed
    shown(root, request)
  else
    IO.warn(cleaned_text(text_of(root, "text")))
  end

  IO.flush()
  Step.Next(after, "")
end

def asked(child: Process, request: Repl.Request) -> Result[String]
  hex = OpenSSL.Digest.hexencode(request.bytes)
  at = 0
  while at < hex.length
    size = CHUNK * 2
    if at + size > hex.length
      size = hex.length - at
    end

    try Process.channel_send(child, "chunk #{hex.slice(at, size)}\n", WAIT)
    at += size
  end

  reads = numbers(request.reads)
  writes = numbers(request.writes)
  try Process.channel_send(child, "entry #{request.entry} #{reads} #{writes}\n", WAIT)
  Process.channel_read_line(child, WAIT)
end

def numbers(slots: List[Int]) -> String
  return "-" if slots.size == 0

  slots.map { |slot: Int| slot.to_s }.join(",")
end

def flag(root: JSON.Value, key: String) -> Bool
  found = JSON.get(root, key)
  return false if !found.ok?

  JSON.bool(found.unwrap!).unwrap_or(false)
end

def text_of(root: JSON.Value, key: String) -> String
  found = JSON.get(root, key)
  return "" if !found.ok?

  JSON.string(found.unwrap!).unwrap_or("")
end

# Why the child did not run the entry, which only a fault of the front end gives: it refused the request, or the entry
# gave back no struct of the right size.
def refusal(root: JSON.Value) -> String = "#{text_of(root, "refused")}#{text_of(root, "invalid")}"

def shown(root: JSON.Value, request: Repl.Request) -> Void
  if request.shown != ""
    puts("=> #{text_of(root, "value")} : #{request.shown}")
  end

  if request.dropped.size > 0
    puts("dropped #{request.dropped.join(", ")}: the type of each changed")
  end
end

# The answer to an entry that ran. One that failed kept no name or declaration.
def json_answer(root: JSON.Value, request: Repl.Request, passed: Bool) -> Map[String, JSON.Value]
  fields: Map[String, JSON.Value] = {"ok": JSON.from(passed)}
  if passed and request.shown != ""
    fields = fields.put("value", JSON.from(text_of(root, "value"))).put("type", JSON.from(request.shown))
  end

  bound: Map[String, JSON.Value] = {}
  declared: List[JSON.Value] = []
  dropped: List[JSON.Value] = []
  if passed
    for binding in request.bound
      bound = bound.put(binding.name, JSON.from(binding.type))
    end

    declared = request.declared.map { |name: String| JSON.from(name) }
    dropped = request.dropped.map { |name: String| JSON.from(name) }
  end

  fields = fields.put("bound", JSON.object(bound)).put("declared", JSON.array(declared))
  fields = fields.put("dropped", JSON.array(dropped))
  diagnostic = JSON.get(root, "diagnostic")
  if diagnostic.ok?
    fields = fields.put("diagnostic", cleaned_json(diagnostic.unwrap!))
  end

  fields
end

# One JSON answer on stdout, for the item `loop.items` whose first line in the session is `at`.
def answer(loop: Loop, at: Int, fields: Map[String, JSON.Value]) -> Void
  return if loop.style != "json"

  puts(JSON.encode(JSON.object(fields.put("entry", JSON.from(loop.items)).put("line", JSON.from(at)))))
  IO.flush()
end

# A diagnostic of the child without what the session wrote around the entry: the frame of the entry's function and
# the task of the session that runs it.
def cleaned_json(diagnostic: JSON.Value) -> JSON.Value
  case JSON.node(diagnostic)
    JSON.Node.Object(members) ->
      out: Map[String, JSON.Value] = {}
      for key in members.keys
        value = members[key]
        if key == "stack"
          empty: List[JSON.Value] = []
          frames = JSON.list(value)
            .unwrap_or(empty)
            .filter do |frame: JSON.Value| !entry_frame?(text_of(frame, "function")) end

          if frames.size > 0
            out = out.put(key, JSON.array(frames))
          end
        elsif key != "spawned_at" or !session_place?(text_of(value, "file"))
          out = out.put(key, value)
        end
      end

      JSON.object(out)
    _ -> diagnostic
  end
end

# The text of a diagnostic of the child with the same lines left out, and a stack heading with no frame left.
def cleaned_text(text: String) -> String
  kept: List[String] = []
  for line in text.split("\n")
    words = line.strip.split(" ")
    entry = words.size > 1 and words[1] == "at" and entry_frame?(words[0])
    spawned = line.strip.start_with?("task spawned at #{FILE} serve")
    if !entry and !spawned
      kept = kept.push(line)
    end
  end

  out: List[String] = []
  at = 0
  for line in kept
    heading = line.strip.start_with?("= stack") or line.strip == "stack:"
    following = ""
    if at + 1 < kept.size
      following = kept[at + 1]
    end

    if !heading or indent(following) > indent(line)
      out = out.push(line)
    end

    at += 1
  end

  while out.size > 0 and out[out.size - 1].strip == ""
    out = out.take(out.size - 1)
  end

  out.join("\n")
end

def indent(line: String) -> Int
  return 0 if line.strip == ""

  at = 0
  while line.slice(at, 1) == " "
    at += 1
  end

  at
end

def padded(text: String, width: Int) -> String
  out = text
  while out.length < width
    out = out + " "
  end

  out
end

def entry_frame?(name: String) -> Bool = name.start_with?("repl_entry_")

def session_place?(file: String) -> Bool = file.start_with?(FILE)

# A problem in the style of the session, the answer to the item whose first line is `at`: plain text on stderr with
# the lines of the session and `typed`, the text of the entry after them, or one JSON object on stdout.
def report(loop: Loop, problem: Problems.Problem, typed: String, at: Int) -> Void
  named = problem
  text = ""
  if Repl.session_file?(loop.session, problem.file)
    named = problem.with(file: FILE)
    text = "#{loop.session.text}#{typed}\n"
  else
    case SourceReader.read_shown(problem.file)
      SourceFile.Read.Text(found) -> text = found
      _ -> text = ""
    end
  end

  if loop.style == "json"
    answer(loop, at, {"ok": JSON.from(false), "diagnostic": DiagnosticJson.json(named)})
  elsif loop.style == "ai"
    IO.warn(Ai.ai(named, text))
  else
    IO.warn(Plain.text_of(named, text))
  end

  IO.flush()
end

# A problem of the session at the line after its last, whose text is `text`.
def repl_problem(loop: Loop, code: String, message: String, text: String) -> Problems.Problem
  line = loop.session.lines + 1
  start = Source.Position(offset: 0, line: line, column: 1)
  stop = Source.Position(offset: 0, line: line, column: text.split("\n")[0].length + 1)
  Problems.problem(loop.session.file, "", code, message, Source.Span(start: start, stop: stop), Diag.Help.NoHelp)
end

# Ends the session: the end of the channel ends the child, whose status is the session's.
def finish(loop: Loop) -> Int
  _ = Process.channel_close(loop.child, WAIT)
  ended(loop)
end

def finish_quiet(loop: Loop) -> Void
  _ = Process.channel_close(loop.child, WAIT)
end

def ended(loop: Loop) -> Int = Process.wait(loop.child, WAIT).unwrap_or(1)
