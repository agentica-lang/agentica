## The step API of `agentica test`.
##
## A step program builds a list of steps with `step` and passes it to `run`. A handler gets the context of its scenario
## and returns it: most functions here take the context first and return it, so keep the one they return.

# The variables the VM owns, which `Process.spawn_captured` refuses (`reserved_names` in vm/process.c).
VM_ENV_NAMES = ["AGENTICA_CHANNEL", "AGENTICA_VM_METRICS", "AGENTICA_VM_METRICS_FILE", "UV_USE_IO_URING"]

struct Settings
  base: String
  agentica: List[String]
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

# `closing` is one channel for the whole scenario, closed when the after hooks start: from then on a failed check ends
# the hook it runs in, not the scenario, on every context, also one that a hook captured when it was registered.
struct Scenario
  settings: Settings
  state: Map[String, Json]
  services: Map[String, Fn[Json, Result[Json]]]
  step: StepLine
  program: Program
  env: Map[String, String]
  arguments: List[String]
  after: List[Fn[Context, Result[Void]]]
  closing: Channel[Bool]
end

## The state of one scenario: the values saved with `set`, the services kept with `keep`, the current step, the
## environment and arguments for the program under test, the after hooks and the program under test.
export struct Context
  ## The scenario's state.
  scenario: Scenario
end

## A step definition: a pattern and the handler that runs for the steps that match it. Build one with `step`.
export struct Step
  ## The step text to match. `{string}` and `{int}` capture a value.
  pattern: String
  ## Gets the context and the captured values as strings, in order, and returns the context.
  handler: Fn[Context, List[String], Context]
end

## Returns a step that runs `handler` for the steps whose text matches `pattern`.
export def step(pattern: String, handler: Fn[Context, List[String], Context]) -> Step
  return Step(pattern: pattern, handler: handler)
end

## Serves the steps that `agentica test` asks for, with the built-in steps added in front of `steps`. It never returns.
## Run any other way, it prints how to run the step program and exits with code 2.
export def run(steps: List[Step]) -> Void
  all = predefined().concat(steps)
  args = System.args()
  mode = ""
  if args.size == 2 and args[0] == "--agentica-bdd"
    mode = args[1]
  end
  if mode == "list"
    check_start()
    all.each do |item|
      fields: Map[String, Json] = {"event": JSON.from("step"), "pattern": JSON.from(item.pattern)}
      deliver(record_text(fields))
    end

    emit("ready")
    System.exit(0)
  elsif mode == "scenario"
    check_start()
    serve(all)
  end
  IO.warn("run this step program with agentica test --steps FILE")
  System.exit(2)
end

## Returns the Doc String under the current step. Ends the scenario with an error when the step has none.
export def doc_string(ctx: Context) -> String
  if ctx.scenario.step.has_doc
    return ctx.scenario.step.doc
  end
  halt(ctx, "RUNTIME-BDD-CONTEXT", "this step has no Doc String")
  return ""
end

## Returns the Data Table under the current step as rows of cells. Ends the scenario with an error when the step has
## none.
export def table(ctx: Context) -> List[List[String]]
  rows: List[List[String]] = ctx.scenario.step.table
  if not ctx.scenario.step.has_table
    halt(ctx, "RUNTIME-BDD-CONTEXT", "this step has no Data Table")
  end
  return rows
end

## Fails the scenario with `message` when `condition` is false. Returns the context.
export def assert(ctx: Context, condition: Bool, message: String) -> Context
  emit("assert")
  if not condition
    halt(ctx, "RUNTIME-BDD-ASSERTION", message)
  end
  return ctx
end

## Ends the scenario as skipped, with `reason` in the report. The step ends at once, like a failed assertion, and no
## later step of the scenario runs. A skipped scenario is not a failure: the run can still pass.
export def skip(ctx: Context, reason: String) -> Context
  if closing?(ctx)
    halt(ctx, "RUNTIME-BDD-CONTEXT", "an after hook cannot skip the scenario")
  end
  # The hooks run first: the runner stops the child as soon as it reads the skip record.
  problems = run_after(ctx)
  if problems.size > 0
    deliver(after_record(problems))
    System.exit(1)
  end
  fields: Map[String, Json] = {"event": JSON.from("skip"), "reason": JSON.from(clip(reason))}
  deliver(record_text(fields))
  System.exit(0)
  return ctx
end

## Returns the context with `value` saved under `name`, for the later steps of the same scenario.
export def set(ctx: Context, name: String, value: Json) -> Context
  return with_state(ctx, ctx.scenario.state.put(name, value))
end

## Returns the value saved under `name`, or an error when there is none.
export def get(ctx: Context, name: String) -> Result[Json]
  return ctx.scenario.state.get(name).to_result("missing scenario state")
end

## Returns the context with `service` kept under `name`, for the later steps of the same scenario. A service is a
## function from a request to a result, both JSON: the way to keep a value that is not JSON, such as an open database
## connection, which the function captures. The handles close when the scenario's child VM ends with the scenario.
export def keep(ctx: Context, name: String, service: Fn[Json, Result[Json]]) -> Context
  return with_services(ctx, ctx.scenario.services.put(name, service))
end

## Calls the service kept under `name` with `request` and returns its result, or an error when there is none.
export def call(ctx: Context, name: String, request: Json) -> Result[Json]
  found = ctx.scenario.services.get(name)
  if found.none?
    return error("missing scenario service")
  end
  return found.unwrap!.call(request)
end

## Returns the context with the environment variable `name` set to `value` for the program that `given_program` starts
## later, on top of the environment `agentica test` runs in. The scenario's own environment does not change, and the
## variable does not reach any other scenario. Setting a name again replaces its value; on Windows, where names ignore
## case, `"Path"` and `"PATH"` are one name, and two names that differ only in the case of a letter outside ASCII
## (`"Ä"`, `"ä"`) make `given_program` fail. It must come before `given_program`. `name` must be nonempty and
## cannot contain `=` or a NUL byte, `value` cannot contain a NUL byte, and the names the VM owns (`AGENTICA_CHANNEL`,
## `AGENTICA_VM_METRICS`, `AGENTICA_VM_METRICS_FILE`, `UV_USE_IO_URING`) cannot be set.
export def given_env(ctx: Context, name: String, value: String) -> Context
  not_started(ctx, "the environment")
  if name == "" or name.contains?("=") or has_nul?(name) or has_nul?(value)
    halt(
      ctx,
      "RUNTIME-BDD-CONTEXT",
      "an environment variable name must be nonempty and cannot contain = or NUL, and its value cannot contain NUL",
    )
  end
  if VM_ENV_NAMES.any? do |owned| same_env_name?(owned, name) end
    halt(ctx, "RUNTIME-BDD-CONTEXT", "the environment variable #{name} belongs to the VM and cannot be set")
  end
  # Where names ignore case the old spelling goes first: the child would get both and could see either.
  env = ctx.scenario.env.filter do |key, old| !same_env_name?(key, name) end
  return with_launch(ctx, env.put(name, value), ctx.scenario.arguments)
end

## Returns the context with `value` added to the command-line arguments of the program that `given_program` starts
## later: the program reads them with `System.args`, in the order of the calls. It must come before `given_program`.
export def given_argument(ctx: Context, value: String) -> Context
  not_started(ctx, "the arguments")
  return with_launch(ctx, ctx.scenario.env, ctx.scenario.arguments.push(value))
end

## Returns the context with `hook` registered to run when the scenario ends, whether it passed, failed or was skipped.
## Hooks run in the reverse order of registration, in the child process of the scenario, before the program under test
## is stopped. A hook gets the context at the end of the scenario and returns `error(message)` when its cleanup fails.
## The hook is kept in the context this returns: a step that fails on an older context does not run it.
## A failed hook fails a passing scenario and is added to the message of a failing one. The other hooks still run, also
## when a hook crashes or fails a `BDD` check, on its own context or on one it captured earlier. Hooks do not run when
## the process itself ends: a crash in a step, the scenario's time limit or `System.exit`.
export def after(ctx: Context, hook: Fn[Context, Result[Void]]) -> Context
  return with_after(ctx, ctx.scenario.after.push(hook))
end

## Starts the Agentica program at `path`, relative to the feature file, and returns the context that holds it. It runs
## with the environment variables and arguments given before it. One program may start per scenario.
export def given_program(ctx: Context, path: String) -> Context
  case ctx.scenario.program
    Program.Running(_) -> halt(ctx, "RUNTIME-BDD-CONTEXT", "only one program may start per scenario")
    Program.NotStarted -> return start(ctx, path)
  end
  return ctx
end

## Sends `text` and a newline to the program's input.
export def when_line(ctx: Context, text: String) -> Context
  return send(ctx, "#{text}\n")
end

## Sends `text` to the program's input as it is.
export def when_input(ctx: Context, text: String) -> Context
  return send(ctx, text)
end

## Closes the program's input.
export def when_eof(ctx: Context) -> Context
  p = program(ctx)
  closed = Process.close_stdin(p, 5000)
  check(ctx, closed.ok?, closed.message)
  return ctx
end

## Returns the next output line of the program, waiting up to `timeout_ms` milliseconds. It is an error when the output
## ended or no line came in time.
export def read_line(ctx: Context, timeout_ms: Int) -> Result[String]
  line = raw_line(ctx, timeout_ms)
  if line.ok?
    return line
  end
  if line.message == ended_text()
    return error("stdout ended before a line")
  elsif line.message == timed_out_text()
    return error("no line within #{timeout_ms} milliseconds")
  end
  check(ctx, false, line.message)
  return line
end

## Checks that the next output line of the program is `expected`, waiting up to `timeout_ms` milliseconds.
export def then_line(ctx: Context, expected: String, timeout_ms: Int) -> Context
  return compare_text(ctx, next_line(ctx, timeout_ms), expected)
end

## Checks that the next output line and `expected` are the same JSON value, in any key order, waiting up to
## `timeout_ms` milliseconds.
export def then_json_line(ctx: Context, expected: String, timeout_ms: Int) -> Context
  actual = next_line(ctx, timeout_ms)
  left = JSON.parse(expected)
  right = JSON.parse(actual)
  if not left.ok? or not right.ok?
    halt(ctx, "RUNTIME-BDD-JSON", "expected and received lines must be valid JSON")
    return ctx
  end
  return compare(ctx, Test.eq(right.unwrap!, left.unwrap!), JSON.encode(left.unwrap!), JSON.encode(right.unwrap!))
end

## Checks that the program is still running with its input open.
export def then_stdin_open(ctx: Context) -> Context
  p = program(ctx)
  wanted = "open stdin and active program"
  state = "closed stdin or stopped program"
  if Process.send(p, "", 5000).ok? and not Process.wait(p, 1).ok?
    state = wanted
  end
  return compare(ctx, Test.eq(state, wanted), wanted, state)
end

## Waits up to `timeout_ms` milliseconds for the program to exit and checks that its exit code is `code`.
export def then_exit(ctx: Context, code: Int, timeout_ms: Int) -> Context
  p = program(ctx)
  positive(ctx, timeout_ms)
  status = Process.wait(p, timeout_ms)
  check(ctx, status.ok?, status.message)
  finished(ctx, p)
  actual = status.unwrap!
  return compare(ctx, Test.eq(actual, code), code.inspect, actual.inspect)
end

## Checks that the output no line step has read yet is `expected`. The program must have exited.
export def then_stdout(ctx: Context, expected: String) -> Context
  return compare_text(ctx, finished(ctx, exited(ctx, program(ctx))).stdout, expected)
end

## Checks that the whole error output is `expected`. The program must have exited.
export def then_stderr(ctx: Context, expected: String) -> Context
  return compare_text(ctx, finished(ctx, exited(ctx, program(ctx))).stderr, expected)
end

def predefined() -> List[Step]
  return [
    step("the Agentica program {string}") do |ctx, args| given_program(ctx, args[0]) end,
    step("the environment variable {string} is {string}") do |ctx, args| given_env(ctx, args[0], args[1]) end,
    step("the program argument {string}") do |ctx, args| given_argument(ctx, args[0]) end,
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

# One step per channel line until the runner closes the channel; a failure has already ended the run with a fail
# record. The after hooks run when the channel closes, so a hook that fails turns a passing scenario into a failed one.
def serve(all: List[Step]) -> Void
  init = Process.parent_read_line(idle_ms())
  if not init.ok?
    System.exit(0)
  end
  settings = JSON.decode(init.unwrap!, Settings)
  if not settings.ok?
    abort("RUNTIME-BDD-INFRA", "invalid scenario settings: #{settings.message}")
  end
  empty: List[List[String]] = []
  blank = StepLine(
    index: 0,
    definition: 0,
    pattern: "",
    captures: [],
    has_doc: false,
    doc: "",
    has_table: false,
    table: empty,
  )

  no_hooks: List[Fn[Context, Result[Void]]] = []

  ctx = Context(
    scenario: Scenario(
      settings: settings.unwrap!,
      state: {},
      services: {},
      step: blank,
      program: Program.NotStarted,
      env: {},
      arguments: [],
      after: no_hooks,
      closing: Channel.new(1),
    ),
  )

  line = Process.parent_read_line(idle_ms())
  while line.ok?
    found = JSON.decode(line.unwrap!, StepLine)
    if not found.ok?
      halt(ctx, "RUNTIME-BDD-INFRA", "invalid step line: #{found.message}")
    end
    current = found.unwrap!
    if current.definition < 0 or current.definition >= all.size or all[current.definition].pattern != current.pattern
      halt(ctx, "RUNTIME-BDD-INFRA", "the step program built a different list of steps: #{current.pattern}")
    end
    ctx = all[current.definition].handler.call(with_step(ctx, current), current.captures)
    check_tasks("await pending tasks before returning from a BDD handler") do |code, message|
      halt(ctx, code, message)
    end

    probe(ctx)
    fields: Map[String, Json] = {"event": JSON.from("end"), "index": JSON.from(current.index)}
    deliver(record_text(fields))
    line = Process.parent_read_line(idle_ms())
  end
  problems = run_after(ctx)
  if problems.size > 0
    deliver(after_record(problems))
    System.exit(1)
  end
  System.exit(0)
end

# Runs the after hooks, the last registered first, each in its own task so that a crash or a failed `BDD` check in one
# (`finish` crashes the task once the scenario is closing) leaves the others to run. Returns the problem of each hook
# that failed. The `after` record tells the runner that hooks run, so a time limit reached from here is theirs.
def run_after(ctx: Context) -> List[String]
  ctx.scenario.closing.close
  problems: List[String] = []
  if ctx.scenario.after.size > 0
    emit("after")
  end
  for hook in ctx.scenario.after.reverse
    outcome = Task.await(Task.spawn do hook.call(ctx) end)
    if not outcome.ok?
      problems = problems.push(outcome.message)
    end
  end
  return problems
end

def after_record(problems: List[String]) -> String
  fields: Map[String, Json] = {
    "event": JSON.from("fail"),
    "code": JSON.from("RUNTIME-BDD-AFTER"),
    "message": JSON.from(clip("after hook failed: #{problems.join("; ")}")),
  }

  return record_text(fields)
end

# Ends the scenario when a task is still running (with `pending` as the message) or crashed unobserved. `fail` ends it:
# `abort` before the scenario's context exists, `halt` once it does, so the after hooks run.
def check_tasks(pending: String, fail: Fn[String, String, Void]) -> Void
  if Task.pending_count() > 0
    fail.call("RUNTIME-BDD-PENDING-TASKS", pending)
  end
  crash = Task.unobserved_crash()
  if crash.ok?
    fail.call("RUNTIME-TASK-CRASHED", crash.unwrap!)
  end
end

def check_start() -> Void
  check_tasks("await pending tasks before calling BDD.run") do |code, message| abort(code, message) end
end

def probe(ctx: Context) -> Void
  case ctx.scenario.program
    Program.Running(p) ->
      peek = Process.read_bytes(p, 0, 1000)
      if not peek.ok? and peek.message == over_text()
        halt(ctx, "RUNTIME-BDD-OUTPUT-LIMIT", "program output exceeds 1 MiB")
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
  # Under --deny-fs this VM cannot look at the file; the agentica command below reads it and says when it is missing.
  seen = info.ok? or !info.message.start_with?("denied:")
  if !file.end_with?(".agc") or (seen and !(info.ok? and info.unwrap!.kind == "file"))
    halt(ctx, "RUNTIME-BDD-PROGRAM", "expected an existing .agc program")
  end
  if settings.agentica.size == 0
    halt(ctx, "RUNTIME-BDD-INFRA", "Agentica executable is unavailable")
  end
  flags: List[String] = []
  if settings.seeded
    flags = flags.concat(["--seed", settings.seed.to_s])
  end
  # No --max-steps: the program runs as `agentica FILE.agc` does. A runaway program ends with its scenario, whose
  # deadline and `within N milliseconds` steps are the limits.
  args = settings.agentica.drop(1).concat(flags).concat([file]).concat(ctx.scenario.arguments)
  spawned = Process.spawn_captured(settings.agentica[0], args, settings.base, 30000, ctx.scenario.env)
  if not spawned.ok?
    if spawned.message == "process: executable is unavailable"
      halt(ctx, "RUNTIME-BDD-INFRA", "Agentica executable is unavailable")
    end
    halt(ctx, "RUNTIME-BDD-IO", spawned.message)
  end
  return Context(
    scenario: Scenario(
      settings: settings,
      state: ctx.scenario.state,
      services: ctx.scenario.services,
      step: ctx.scenario.step,
      program: Program.Running(spawned.unwrap!),
      env: ctx.scenario.env,
      arguments: ctx.scenario.arguments,
      after: ctx.scenario.after,
      closing: ctx.scenario.closing,
    ),
  )
end

# Environment and arguments are read when the program starts, so a later call would silently change nothing.
def not_started(ctx: Context, what: String) -> Void
  case ctx.scenario.program
    Program.Running(_) -> halt(ctx, "RUNTIME-BDD-CONTEXT", "#{what} must be set before the program starts")
    Program.NotStarted -> return
  end
end

def program(ctx: Context) -> Process
  found: Result[Process] = error("start a program before using its streams")
  case ctx.scenario.program
    Program.Running(p) -> found = ok(p)
    Program.NotStarted -> halt(ctx, "RUNTIME-BDD-CONTEXT", found.message)
  end
  return found.unwrap!
end

def send(ctx: Context, text: String) -> Context
  sent = Process.send(program(ctx), text, 5000)
  if not sent.ok? and sent.message == "process: stdin is closed"
    halt(ctx, "RUNTIME-BDD-CONTEXT", "stdin is already closed")
  end
  check(ctx, sent.ok?, sent.message)
  return ctx
end

def raw_line(ctx: Context, timeout_ms: Int) -> Result[String]
  p = program(ctx)
  positive(ctx, timeout_ms)
  return Process.read_line(p, timeout_ms)
end

def next_line(ctx: Context, timeout_ms: Int) -> String
  line = raw_line(ctx, timeout_ms)
  if not line.ok? and line.message == ended_text()
    halt(ctx, "RUNTIME-BDD-ASSERTION", "stdout ended before the expected line")
  end
  check(ctx, line.ok?, line.message)
  return line.unwrap!
end

def exited(ctx: Context, p: Process) -> Process
  if not Process.wait(p, 1).ok?
    halt(ctx, "RUNTIME-BDD-CONTEXT", "complete output requires program exit")
  end
  return p
end

def finished(ctx: Context, p: Process) -> ProcessOutput
  output = Process.output(p, 5000)
  check(ctx, output.ok?, output.message)
  if output.unwrap!.truncated
    halt(ctx, "RUNTIME-BDD-OUTPUT-LIMIT", "program output exceeds 1 MiB")
  end
  return output.unwrap!
end

def positive(ctx: Context, timeout_ms: Int) -> Void
  if timeout_ms <= 0
    halt(ctx, "RUNTIME-BDD-TIMEOUT", "timeout must be a positive integer")
  end
end

# Ends the scenario child with a fail record for a failed stream operation.
def check(ctx: Context, fine: Bool, message: String) -> Void
  if fine
    return
  end
  if message == timed_out_text()
    halt(ctx, "RUNTIME-BDD-TIMEOUT", "BDD operation timed out")
  elsif message == over_text() or message == "process: line exceeds 1048576 bytes"
    halt(ctx, "RUNTIME-BDD-OUTPUT-LIMIT", "program output exceeds 1 MiB")
  end
  halt(ctx, "RUNTIME-BDD-IO", message)
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

    finish(ctx, fields)
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
  return Context(
    scenario: Scenario(
      settings: ctx.scenario.settings,
      state: state,
      services: ctx.scenario.services,
      step: ctx.scenario.step,
      program: ctx.scenario.program,
      env: ctx.scenario.env,
      arguments: ctx.scenario.arguments,
      after: ctx.scenario.after,
      closing: ctx.scenario.closing,
    ),
  )
end

def with_services(ctx: Context, services: Map[String, Fn[Json, Result[Json]]]) -> Context
  return Context(
    scenario: Scenario(
      settings: ctx.scenario.settings,
      state: ctx.scenario.state,
      services: services,
      step: ctx.scenario.step,
      program: ctx.scenario.program,
      env: ctx.scenario.env,
      arguments: ctx.scenario.arguments,
      after: ctx.scenario.after,
      closing: ctx.scenario.closing,
    ),
  )
end

def with_step(ctx: Context, current: StepLine) -> Context
  return Context(
    scenario: Scenario(
      settings: ctx.scenario.settings,
      state: ctx.scenario.state,
      services: ctx.scenario.services,
      step: current,
      program: ctx.scenario.program,
      env: ctx.scenario.env,
      arguments: ctx.scenario.arguments,
      after: ctx.scenario.after,
      closing: ctx.scenario.closing,
    ),
  )
end

def with_launch(ctx: Context, env: Map[String, String], arguments: List[String]) -> Context
  return Context(
    scenario: Scenario(
      settings: ctx.scenario.settings,
      state: ctx.scenario.state,
      services: ctx.scenario.services,
      step: ctx.scenario.step,
      program: ctx.scenario.program,
      env: env,
      arguments: arguments,
      after: ctx.scenario.after,
      closing: ctx.scenario.closing,
    ),
  )
end

def with_after(ctx: Context, after: List[Fn[Context, Result[Void]]]) -> Context
  return Context(
    scenario: Scenario(
      settings: ctx.scenario.settings,
      state: ctx.scenario.state,
      services: ctx.scenario.services,
      step: ctx.scenario.step,
      program: ctx.scenario.program,
      env: ctx.scenario.env,
      arguments: ctx.scenario.arguments,
      after: after,
      closing: ctx.scenario.closing,
    ),
  )
end

# True once the after hooks have started (`run_after`).
def closing?(ctx: Context) -> Bool
  return ctx.scenario.closing.closed?
end

def has_nul?(text: String) -> Bool
  return text.bytes.to_a.include?(0)
end

# True when two names are one variable for `Process.spawn_captured` on this system: byte for byte, except that on
# Windows ASCII case is ignored. Windows ignores the case of other letters too, by a table of its own that std/ cannot
# read; such twins stay in the map, and the VM refuses them when `given_program` spawns (`case_twins` in vm/process.c).
def same_env_name?(a: String, b: String) -> Bool
  if a == b
    return true
  end
  if System.os() != "windows" or a.bytesize != b.bytesize
    return false
  end
  return ascii_folded(a) == ascii_folded(b)
end

def ascii_folded(name: String) -> List[Int]
  return name.bytes.to_a.map do |byte| ascii_lower(byte) end
end

def ascii_lower(byte: Int) -> Int
  if byte >= 65 and byte <= 90
    return byte + 32
  end
  return byte
end

# Fails the scenario at once, for the failures that no hook can follow: before the scenario's context exists.
def abort(code: String, message: String) -> Void
  fields: Map[String, Json] = {"event": JSON.from("fail"), "code": JSON.from(code), "message": JSON.from(message)}
  deliver(record_text(fields))
  System.exit(1)
end

def halt(ctx: Context, code: String, message: String) -> Void
  fields: Map[String, Json] = {"event": JSON.from("fail"), "code": JSON.from(code), "message": JSON.from(message)}
  finish(ctx, fields)
end

# Ends the scenario with a fail record. The record goes first and the after hooks run after it, so a hook that hangs or
# dies cannot hide the failure; the runner reads on until the child exits and adds a failed hook to the message. In a
# hook (`closing?`) it crashes the hook's task instead, which `run_after` turns into that hook's problem.
def finish(ctx: Context, fields: Map[String, Json]) -> Void
  if closing?(ctx)
    code = JSON.string(fields["code"]).unwrap_or("")
    gone: Result[Void] = error("#{code}: #{JSON.string(fields["message"]).unwrap_or("")}")
    gone.unwrap!
  end
  deliver(record_text(fields))
  problems = run_after(ctx)
  if problems.size > 0
    deliver(after_record(problems))
  end
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
      fields: Map[String, Json] = {
        "event": JSON.from("fail"),
        "code": JSON.from("RUNTIME-BDD-OUTPUT-LIMIT"),
        "message": JSON.from("handler output exceeds 1 MiB"),
      }

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
  return "#{JSON.encode(JSON.object(fields))}\n"
end

def ended_text() -> String
  return "process: end of input"
end

def timed_out_text() -> String
  return "process: operation timed out"
end

def over_text() -> String
  return "process: output exceeds 1048576 bytes"
end
