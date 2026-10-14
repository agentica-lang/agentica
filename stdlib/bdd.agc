struct Settings
  base: String
  agentica: List[String]
  allow_run: Bool
  seeded: Bool
  seed: Int
end

struct StepLine
  index: Int
  definition: Int
  pattern: String
  captures: List[String]
  has_doc: Bool
  doc: String
  has_table: Bool
  table: List[List[String]]
end

enum Program
  NotStarted
  Running(Process)
end

struct Scenario
  settings: Settings
  state: Map[String, Json]
  step: StepLine
  program: Program
end

export struct Context
  scenario: Scenario
end

export struct Step
  pattern: String
  handler: Fn[Context, List[String], Context]
end

export def step(pattern: String, handler: Fn[Context, List[String], Context]) -> Step
  return Step(pattern: pattern, handler: handler)
end

# Serves the mode in System.args: "list" sends the patterns, "scenario" runs the steps the runner sends on the parent channel.
export def run(steps: List[Step]) -> Void
  all = predefined().concat(steps)
  args = System.args()
  mode = ""
  if args.size == 2 and args[0] == "--agentica-bdd"
    mode = args[1]
  end
  if mode == "list"
    check_tasks()
    all.each do |item|
      fields: Map[String, Json] = {"event": JSON.from("step"), "pattern": JSON.from(item.pattern)}
      deliver(record_text(fields))
    end
    emit("ready")
    System.exit(0)
  elsif mode == "scenario"
    check_tasks()
    serve(all)
  end
  IO.warn("run this step program with agentica test --steps FILE")
  System.exit(2)
end

export def doc_string(ctx: Context) -> String
  if ctx.scenario.step.has_doc
    return ctx.scenario.step.doc
  end
  halt("RUNTIME-BDD-CONTEXT", "this step has no Doc String")
  return ""
end

export def table(ctx: Context) -> List[List[String]]
  rows: List[List[String]] = ctx.scenario.step.table
  if not ctx.scenario.step.has_table
    halt("RUNTIME-BDD-CONTEXT", "this step has no Data Table")
  end
  return rows
end

export def assert(ctx: Context, condition: Bool, message: String) -> Context
  emit("assert")
  if not condition
    halt("RUNTIME-BDD-ASSERTION", message)
  end
  return ctx
end

export def set(ctx: Context, name: String, value: Json) -> Context
  return with_state(ctx, ctx.scenario.state.put(name, value))
end

export def get(ctx: Context, name: String) -> Result[Json]
  if ctx.scenario.state.has_key?(name)
    return ctx.scenario.state.get(name)
  end
  return error("missing scenario state")
end

export def given_program(ctx: Context, path: String) -> Context
  case ctx.scenario.program
    Program.Running(_) -> halt("RUNTIME-BDD-CONTEXT", "only one program may start per scenario")
    Program.NotStarted -> return start(ctx, path)
  end
  return ctx
end

export def when_line(ctx: Context, text: String) -> Context
  return send(ctx, text + "\n")
end

export def when_input(ctx: Context, text: String) -> Context
  return send(ctx, text)
end

export def when_eof(ctx: Context) -> Context
  p = program(ctx)
  closed = Process.close_stdin(p, 5000)
  check(closed.ok?, closed.message)
  return ctx
end

export def then_line(ctx: Context, expected: String, timeout_ms: Int) -> Context
  return compare_text(ctx, read_line(ctx, timeout_ms), expected)
end

export def then_json_line(ctx: Context, expected: String, timeout_ms: Int) -> Context
  actual = read_line(ctx, timeout_ms)
  left = JSON.parse(expected)
  right = JSON.parse(actual)
  if not left.ok? or not right.ok?
    halt("RUNTIME-BDD-JSON", "expected and received lines must be valid JSON")
    return ctx
  end
  return compare(ctx, Test.eq(right.unwrap!, left.unwrap!), JSON.encode(left.unwrap!), JSON.encode(right.unwrap!))
end

export def then_stdin_open(ctx: Context) -> Context
  p = program(ctx)
  wanted = "open stdin and active program"
  state = "closed stdin or stopped program"
  if Process.send(p, "", 5000).ok? and not Process.wait(p, 1).ok?
    state = wanted
  end
  return compare(ctx, Test.eq(state, wanted), wanted, state)
end

export def then_exit(ctx: Context, code: Int, timeout_ms: Int) -> Context
  p = program(ctx)
  positive(timeout_ms)
  status = Process.wait(p, timeout_ms)
  check(status.ok?, status.message)
  finished(p)
  actual = status.unwrap!
  return compare(ctx, Test.eq(actual, code), code.inspect, actual.inspect)
end

export def then_stdout(ctx: Context, expected: String) -> Context
  return compare_text(ctx, finished(exited(program(ctx))).stdout, expected)
end

export def then_stderr(ctx: Context, expected: String) -> Context
  return compare_text(ctx, finished(exited(program(ctx))).stderr, expected)
end

def predefined() -> List[Step]
  return [
    step("the Agentica program {string}") do |ctx, args| given_program(ctx, args[0]) end,
    step("I send a line:") do |ctx, args| when_line(ctx, doc_string(ctx)) end,
    step("I send the line {string}") do |ctx, args| when_line(ctx, args[0]) end,
    step("I send input:") do |ctx, args| when_input(ctx, doc_string(ctx)) end,
    step("I close stdin") do |ctx, args| when_eof(ctx) end,
    step("I receive a line within {int} milliseconds:") do |ctx, args|
      then_line(ctx, doc_string(ctx), args[0].to_i!)
    end,
    step("I receive the line {string} within {int} milliseconds") do |ctx, args|
      then_line(ctx, args[0], args[1].to_i!)
    end,
    step("I receive a JSON line within {int} milliseconds:") do |ctx, args|
      then_json_line(ctx, doc_string(ctx), args[0].to_i!)
    end,
    step("stdin remains open") do |ctx, args| then_stdin_open(ctx) end,
    step("the program exits with code {int} within {int} milliseconds") do |ctx, args|
      then_exit(ctx, args[0].to_i!, args[1].to_i!)
    end,
    step("stdout is:") do |ctx, args| then_stdout(ctx, doc_string(ctx)) end,
    step("stderr is:") do |ctx, args| then_stderr(ctx, doc_string(ctx)) end,
  ]
end

# One step per channel line until the runner closes the channel; a failure has already ended the run with a fail record.
def serve(all: List[Step]) -> Void
  init = Process.parent_read_line(idle_ms())
  if not init.ok?
    System.exit(0)
  end
  settings = JSON.decode(init.unwrap!, Settings)
  if not settings.ok?
    halt("RUNTIME-BDD-INFRA", "invalid scenario settings: #{settings.message}")
  end
  empty: List[List[String]] = []
  blank = StepLine(index: 0, definition: 0, pattern: "", captures: [], has_doc: false, doc: "", has_table: false, table: empty)
  ctx = Context(scenario: Scenario(settings: settings.unwrap!, state: {}, step: blank, program: Program.NotStarted))
  line = Process.parent_read_line(idle_ms())
  while line.ok?
    found = JSON.decode(line.unwrap!, StepLine)
    if not found.ok?
      halt("RUNTIME-BDD-INFRA", "invalid step line: #{found.message}")
    end
    current = found.unwrap!
    if current.definition < 0 or current.definition >= all.size or all[current.definition].pattern != current.pattern
      halt("RUNTIME-BDD-INFRA", "the step program built a different list of steps: #{current.pattern}")
    end
    ctx = all[current.definition].handler.call(with_step(ctx, current), current.captures)
    if Task.pending_count() > 0
      halt("RUNTIME-BDD-PENDING-TASKS", "await pending tasks before returning from a BDD handler")
    end
    check_crash()
    probe(ctx)
    fields: Map[String, Json] = {"event": JSON.from("end"), "index": JSON.from(current.index)}
    deliver(record_text(fields))
    line = Process.parent_read_line(idle_ms())
  end
  System.exit(0)
end

def check_tasks() -> Void
  if Task.pending_count() > 0
    halt("RUNTIME-BDD-PENDING-TASKS", "await pending tasks before calling BDD.run")
  end
  check_crash()
end

def check_crash() -> Void
  crash = Task.unobserved_crash()
  if crash.ok?
    halt("RUNTIME-TASK-CRASHED", crash.unwrap!)
  end
end

def probe(ctx: Context) -> Void
  case ctx.scenario.program
    Program.Running(p) ->
      peek = Process.read_bytes(p, 0, 1000)
      if not peek.ok? and peek.message == over_text()
        halt("RUNTIME-BDD-OUTPUT-LIMIT", "program output exceeds 1 MiB")
      end
    Program.NotStarted -> return
  end
end

def start(ctx: Context, path: String) -> Context
  settings = ctx.scenario.settings
  joined: Result[String] = ok(path)
  if not path.start_with?("/")
    joined = Path.join([settings.base, path])
  end
  file = Path.resolve(joined.unwrap_or(path)).unwrap_or(path)
  info = File.stat(file, 5000)
  if not (info.ok? and file.end_with?(".agc")) or info.unwrap!.kind != "file"
    halt("RUNTIME-BDD-PROGRAM", "expected an existing .agc program")
  end
  if settings.agentica.size == 0
    halt("RUNTIME-BDD-INFRA", "Agentica executable is unavailable")
  end
  flags: List[String] = []
  if settings.allow_run
    flags = ["--allow-run"]
  end
  if settings.seeded
    flags = flags.concat(["--seed", settings.seed.to_s])
  end
  args = settings.agentica.drop(1).concat(flags).concat(["--max-steps", "1000000", file])
  spawned = Process.spawn_captured(settings.agentica[0], args, settings.base, 30000)
  if not spawned.ok?
    if spawned.message == "process: executable is unavailable"
      halt("RUNTIME-BDD-INFRA", "Agentica executable is unavailable")
    end
    halt("RUNTIME-BDD-IO", spawned.message)
  end
  return Context(scenario: Scenario(settings: settings, state: ctx.scenario.state, step: ctx.scenario.step,
                                    program: Program.Running(spawned.unwrap!)))
end

def program(ctx: Context) -> Process
  found: Result[Process] = error("start a program before using its streams")
  case ctx.scenario.program
    Program.Running(p) -> found = ok(p)
    Program.NotStarted -> halt("RUNTIME-BDD-CONTEXT", found.message)
  end
  return found.unwrap!
end

def send(ctx: Context, text: String) -> Context
  sent = Process.send(program(ctx), text, 5000)
  if not sent.ok? and sent.message == "process: stdin is closed"
    halt("RUNTIME-BDD-CONTEXT", "stdin is already closed")
  end
  check(sent.ok?, sent.message)
  return ctx
end

def read_line(ctx: Context, timeout_ms: Int) -> String
  p = program(ctx)
  positive(timeout_ms)
  line = Process.read_line(p, timeout_ms)
  if not line.ok? and line.message == "process: end of input"
    halt("RUNTIME-BDD-ASSERTION", "stdout ended before the expected line")
  end
  check(line.ok?, line.message)
  return line.unwrap!
end

def exited(p: Process) -> Process
  if not Process.wait(p, 1).ok?
    halt("RUNTIME-BDD-CONTEXT", "complete output requires program exit")
  end
  return p
end

def finished(p: Process) -> ProcessOutput
  output = Process.output(p, 5000)
  check(output.ok?, output.message)
  if output.unwrap!.truncated
    halt("RUNTIME-BDD-OUTPUT-LIMIT", "program output exceeds 1 MiB")
  end
  return output.unwrap!
end

def positive(timeout_ms: Int) -> Void
  if timeout_ms <= 0
    halt("RUNTIME-BDD-TIMEOUT", "timeout must be a positive integer")
  end
end

# Ends the scenario child with a fail record for a failed stream operation.
def check(fine: Bool, message: String) -> Void
  if fine
    return
  end
  if message == "network: operation timed out"
    halt("RUNTIME-BDD-TIMEOUT", "BDD operation timed out")
  elsif message == over_text() or message == "process: line exceeds 1048576 bytes"
    halt("RUNTIME-BDD-OUTPUT-LIMIT", "program output exceeds 1 MiB")
  end
  halt("RUNTIME-BDD-IO", message)
end

def compare_text(ctx: Context, actual: String, expected: String) -> Context
  return compare(ctx, Test.eq(actual, expected), expected.inspect, actual.inspect)
end

def compare(ctx: Context, checked: Result[Void], expected: String, actual: String) -> Context
  emit("assert")
  if not checked.ok?
    fields: Map[String, Json] = {
      "event": JSON.from("fail"),
      "code": JSON.from("RUNTIME-BDD-ASSERTION"),
      "message": JSON.from("BDD assertion failed"),
      "expected": JSON.from(clip(expected)),
      "actual": JSON.from(clip(actual)),
    }
    finish(fields)
  end
  return ctx
end

def clip(text: String) -> String
  if text.length <= 65536
    return text
  end
  return "#{text.slice(0, 65536)}... (#{text.length - 65536} more characters)"
end

def with_state(ctx: Context, state: Map[String, Json]) -> Context
  return Context(scenario: Scenario(settings: ctx.scenario.settings, state: state, step: ctx.scenario.step,
                                    program: ctx.scenario.program))
end

def with_step(ctx: Context, current: StepLine) -> Context
  return Context(scenario: Scenario(settings: ctx.scenario.settings, state: ctx.scenario.state, step: current,
                                    program: ctx.scenario.program))
end

def halt(code: String, message: String) -> Void
  fields: Map[String, Json] = {"event": JSON.from("fail"), "code": JSON.from(code), "message": JSON.from(message)}
  finish(fields)
end

def finish(fields: Map[String, Json]) -> Void
  deliver(record_text(fields))
  System.exit(1)
end

def emit(event: String) -> Void
  fields: Map[String, Json] = {"event": JSON.from(event)}
  deliver(record_text(fields))
end

def deliver(text: String) -> Void
  IO.flush()
  sent = Process.parent_send(text, send_ms())
  if not sent.ok?
    if sent.message == "process: send exceeds 1048576 bytes"
      fields: Map[String, Json] = {"event": JSON.from("fail"), "code": JSON.from("RUNTIME-BDD-OUTPUT-LIMIT"), "message": JSON.from("handler output exceeds 1 MiB")}
      Process.parent_send(record_text(fields), send_ms())
    else
      IO.warn("BDD could not send a record to the runner: #{sent.message}")
    end
    System.exit(1)
  end
end

def idle_ms() -> Int
  return 86400000
end

def send_ms() -> Int
  return 5000
end

def record_text(fields: Map[String, Json]) -> String
  return JSON.encode(JSON.object(fields)) + "\n"
end

def over_text() -> String
  return "process: output exceeds 1048576 bytes"
end
