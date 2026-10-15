## Runs the tests of one `*_test.agc` file for `agentica test`.
##
## It lists the tests in a child VM, then runs them there one at a time.

import Report from "report"
import Child from "child"

## The options of a run: the VM path, the seed, the `--only` text and the timeout of each test in milliseconds.
export struct Settings
  vm: String
  seed: Int
  only: String
  timeout_ms: Int
end

struct UnitTest
  index: Int
  name: String
  span: Report.Span
end

struct Failure
  problem: Report.Error
  output: String
  blame: Bool
end

enum Listed
  Ready(List[UnitTest])
  Broken(Failure)
end

struct TestEnd
  verdict: Report.Verdict
  output: String
  stopped: Bool
  blame: Bool
end

struct Ending
  verdict: Report.Verdict
  output: String
end

## Runs the tests of the file `path` from its compiled `bytecode` and returns the result. A non-empty `front_end` is a
## front-end error of the file, which is reported instead.
export def run(settings: Settings, path: String, bytecode: String, front_end: String) -> Report.FileResult
  if front_end != ""
    parsed = Report.from_json(front_end)
    return Report.file_error(path, "tests", parsed.unwrap_or(Child.located("RUNTIME-BDD-INFRA", parsed.message, path)))
  end
  case list(settings, path, bytecode)
    Listed.Broken(found) -> return Report.file_failure(path, "tests", found.problem, found.output)
    Listed.Ready(found) ->
      chosen = found.filter do |item| settings.only == "" or item.name.include?(settings.only) end
      if chosen.size == 0
        return Report.FileResult(
          path: path,
          feature: "",
          kind: "tests",
          scenarios: [],
          verdict: Report.Verdict.Pass,
          output: "",
        )
      end
      return run_child(settings, path, bytecode, chosen)
  end
end

def list(settings: Settings, path: String, bytecode: String) -> Listed
  where = Report.Span(file: path, line: 1, column: 1, end_column: 1)
  spawned = Process.spawn_channel(settings.vm, args(settings, bytecode, 1000000, "list"), ".", 30000)
  if not spawned.ok?
    return broken(Report.error_at("RUNTIME-BDD-INFRA", spawned.message, where), "")
  end
  p = spawned.unwrap!
  Process.close_stdin(p, 5000)
  deadline = Time.monotonic_ms() + 30000
  read = Child.read_records(p, deadline)
  if read.problem == "process: output exceeds 1048576 bytes"
    Process.close(p)
    return broken(
      Report.error_at(
        "RUNTIME-BDD-OUTPUT-LIMIT",
        "the test file's output exceeds 1 MiB while listing its tests",
        where,
      ),
      "",
    )
  end
  output = Process.output(p, Child.left(deadline))
  code = Process.wait(p, 5000)
  Process.close(p)
  if read.problem == "network: operation timed out" or not output.ok?
    return broken(
      Report.error_at("RUNTIME-TEST-TIMEOUT", "the test file did not list its tests within 30 seconds", where),
      "",
    )
  end
  found = output.unwrap!
  records = read.items
  printed = found.stdout.split("\n").filter do |line| line != "" end.join("\n")
  shown = Child.tail(joined(printed, Child.stderr_text(found.stderr)), 65536)
  if found.truncated
    return broken(
      Report.error_at(
        "RUNTIME-BDD-OUTPUT-LIMIT",
        "the test file's output exceeds 1 MiB while listing its tests",
        where,
      ),
      shown,
    )
  end
  failures = records.filter do |record| Child.event_of(record) == "fail" end
  if failures.size > 0
    return broken(record_error(failures[0]), shown)
  end
  ready = records.any? do |record| Child.event_of(record) == "ready" end
  exit = code.unwrap_or(-1)
  if not ready or exit != 0
    crash = Child.stderr_diagnostic(found.stderr, where)
    if crash.ok?
      return broken(crash.unwrap!, shown)
    end
    if ready or exit != 0
      return broken(
        Report.error_at("RUNTIME-BDD-PREMATURE-EXIT", "the test file exited with code #{exit}", where),
        shown,
      )
    end
    return broken(Report.error_at("RUNTIME-TEST-RUN", "the test file did not call Test.run", where), shown)
  end
  empty: Map[Int, UnitTest] = {}
  tests = records.filter do |record| Child.event_of(record) == "test" end
  listed = tests.reduce(empty) do |acc: Map[Int, UnitTest], record: Json|
    line = Child.int_of(record, "line")
    column = Child.int_of(record, "column")
    acc.put(acc.size, UnitTest(index: acc.size, name: Child.text_of(record, "name"),
                               span: Report.Span(file: path, line: line, column: column, end_column: column)))
  end
  return Listed.Ready(listed.values)
end

def broken(problem: Report.Error, output: String) -> Listed
  return Listed.Broken(Failure(problem: problem, output: output, blame: true))
end

def run_child(settings: Settings, path: String, bytecode: String, chosen: List[UnitTest]) -> Report.FileResult
  where = Report.Span(file: path, line: 1, column: 1, end_column: 1)
  spawned = Process.spawn_channel(
    settings.vm,
    args(settings, bytecode, 1000000 * (chosen.size + 1), "run"),
    ".",
    30000,
  )
  if not spawned.ok?
    return Report.file_error(path, "tests", Report.error_at("RUNTIME-BDD-INFRA", spawned.message, where))
  end
  p = spawned.unwrap!
  Process.close_stdin(p, 5000)
  empty: Map[Int, UnitTest] = {}
  queue = chosen.reduce(empty) do |acc: Map[Int, UnitTest], item: UnitTest| acc.put(acc.size, item) end
  results: Map[Int, Report.ScenarioResult] = {}
  ending = Ending(verdict: Report.Verdict.Pass, output: "")
  stopped = false
  i = 0
  while i < queue.size and not stopped
    item = queue.get(i).unwrap!
    started = Time.monotonic_ms()
    deadline = started + settings.timeout_ms
    done = TestEnd(verdict: Report.Verdict.Pass, output: "", stopped: false, blame: true)
    line_sent = Process.channel_send(p, "#{item.index}\n", Child.left(deadline))
    if line_sent.ok?
      done = await_test(settings, p, deadline, item.span)
    else
      found = failure(settings, p, line_sent.message, deadline, item.span)
      done = TestEnd(
        verdict: Report.Verdict.Fail(found.problem),
        output: found.output,
        stopped: true,
        blame: found.blame,
      )
    end
    if done.blame
      results = results.put(item.index, scenario(item, Time.monotonic_ms() - started, done.verdict, done.output))
    else
      ending = Ending(verdict: done.verdict, output: done.output)
    end
    stopped = done.stopped
    i += 1
  end
  if not stopped
    ending = finish(settings, p, where)
  end
  Process.close(p)
  scenarios = chosen.map do |item| results.get(item.index, scenario(item, 0, Report.Verdict.NotExecuted, "")) end
  return Report.FileResult(path: path, feature: "", kind: "tests", scenarios: scenarios, verdict: ending.verdict,
                           output: ending.output)
end

def await_test(settings: Settings, p: Process, deadline: Int, span: Report.Span) -> TestEnd
  line = Process.channel_read_line(p, Child.left(deadline))
  printed = Process.read_available(p, Child.left(deadline))
  if not printed.ok?
    found = failure(settings, p, printed.message, deadline, span)
    return TestEnd(
      verdict: Report.Verdict.Fail(found.problem),
      output: found.output,
      stopped: true,
      blame: found.blame,
    )
  end
  shown = Child.printed(printed.unwrap!)
  if not line.ok?
    found = failure(settings, p, line.message, deadline, span)
    output = found.output
    if found.blame
      output = Child.tail(joined(shown, found.output), 65536)
    end
    return TestEnd(verdict: Report.Verdict.Fail(found.problem), output: output, stopped: true, blame: found.blame)
  end
  record = Child.record_of(line.unwrap!)
  event = Child.event_of(record)
  if event == "pass"
    return TestEnd(verdict: Report.Verdict.Pass, output: "", stopped: false, blame: true)
  elsif event == "fail"
    return TestEnd(
      verdict: Report.Verdict.Fail(record_error(record)),
      output: Child.tail(shown, 65536),
      stopped: false,
      blame: true,
    )
  end
  problem = Report.error_at("RUNTIME-BDD-INFRA", "the test file broke the test record protocol", span)
  return TestEnd(verdict: Report.Verdict.Fail(problem), output: Child.tail(shown, 65536), stopped: true, blame: true)
end

def finish(settings: Settings, p: Process, where: Report.Span) -> Ending
  Process.channel_close(p, 5000)
  output = Process.output(p, settings.timeout_ms)
  if not output.ok?
    timeout = Report.error_at("RUNTIME-TEST-TIMEOUT", "the test file did not exit after its last test", where)
    return Ending(verdict: Report.Verdict.Fail(timeout), output: "")
  end
  found = output.unwrap!
  shown = Child.stderr_text(found.stderr)
  if found.truncated
    return Ending(verdict: Report.Verdict.Fail(stderr_limit(where)), output: shown)
  end
  code = Process.wait(p, 5000)
  if code.ok? and code.unwrap! == 0
    return Ending(verdict: Report.Verdict.Pass, output: "")
  end
  crash = Child.stderr_diagnostic(found.stderr, where)
  if crash.ok?
    return Ending(verdict: Report.Verdict.Fail(crash.unwrap!), output: shown)
  end
  problem = Report.error_at(
    "RUNTIME-BDD-PREMATURE-EXIT",
    "the test file exited with code #{code.unwrap_or(-1)}",
    where,
  )
  return Ending(verdict: Report.Verdict.Fail(problem), output: shown)
end

def failure(settings: Settings, p: Process, message: String, deadline: Int, span: Report.Span) -> Failure
  if message == "network: operation timed out"
    return timed_out(settings, span)
  end
  if message == "process: line exceeds 1048576 bytes"
    problem = Report.error_at("RUNTIME-BDD-OUTPUT-LIMIT", "a line of test output exceeds 1 MiB", span)
    return Failure(problem: problem, output: "", blame: true)
  end
  if message == "process: output exceeds 1048576 bytes"
    return overflow(settings, p, deadline, span)
  end
  if not Child.gone?(message)
    return Failure(problem: Report.error_at("RUNTIME-BDD-IO", message, span), output: "", blame: true)
  end
  output = Process.output(p, Child.left(deadline))
  if not output.ok?
    return timed_out(settings, span)
  end
  stderr = output.unwrap!.stderr
  crash = Child.stderr_diagnostic(stderr, span)
  if crash.ok?
    return Failure(problem: crash.unwrap!, output: Child.stderr_text(stderr), blame: true)
  end
  code = Process.wait(p, Child.left(deadline))
  problem = Report.error_at(
    "RUNTIME-BDD-PREMATURE-EXIT",
    "the test file exited during the test (exit code #{code.unwrap_or(-1)})",
    span,
  )
  return Failure(problem: problem, output: Child.stderr_text(stderr), blame: true)
end

def overflow(settings: Settings, p: Process, deadline: Int, span: Report.Span) -> Failure
  Process.channel_close(p, Child.left(deadline))
  output = Process.output(p, Child.brief(deadline))
  if not output.ok?
    return Failure(
      problem: Report.error_at("RUNTIME-BDD-OUTPUT-LIMIT", "test output exceeds 1 MiB", span),
      output: "",
      blame: true,
    )
  end
  stderr = output.unwrap!.stderr
  if stderr.length < 262144
    shown = Child.tail(Child.printed(output.unwrap!.stdout), 65536)
    return Failure(
      problem: Report.error_at("RUNTIME-BDD-OUTPUT-LIMIT", "test output exceeds 1 MiB", span),
      output: shown,
      blame: true,
    )
  end
  where = Report.Span(file: span.file, line: 1, column: 1, end_column: 1)
  return Failure(problem: stderr_limit(where), output: Child.stderr_text(stderr), blame: false)
end

def timed_out(settings: Settings, span: Report.Span) -> Failure
  problem = Report.error_at("RUNTIME-TEST-TIMEOUT", "the test did not finish within #{settings.timeout_ms} ms", span)
  return Failure(problem: problem, output: "", blame: true)
end

def stderr_limit(where: Report.Span) -> Report.Error
  return Report.error_at("RUNTIME-BDD-OUTPUT-LIMIT", "the test file's stderr over all its tests exceeds 1 MiB", where)
end

def record_error(record: Json) -> Report.Error
  range = JSON.get(record, "range").unwrap_or(JSON.null())
  start = JSON.get(range, "start").unwrap_or(JSON.null())
  stop = JSON.get(range, "end").unwrap_or(JSON.null())
  span = Report.Span(
    file: Child.text_of(record, "file"),
    line: Child.int_of(start, "line"),
    column: Child.int_of(start, "column"),
    end_column: Child.int_of(stop, "column"),
  )
  original = JSON.null()
  if JSON.get(record, "stack").ok?
    original = Child.diagnostic_of(record)
  end
  return Report.Error(code: Child.text_of(record, "code"), message: Child.text_of(record, "message"), span: span,
                      end_line: Child.int_of(stop, "line"), expected: Child.detail_of(record, "expected"),
                      actual: Child.detail_of(record, "actual"), original: original)
end

def scenario(item: UnitTest, duration_ms: Int, verdict: Report.Verdict, output: String) -> Report.ScenarioResult
  return Report.ScenarioResult(name: item.name, tags: [], location: item.span, example: Report.Example.NoExample,
                               duration_ms: duration_ms, steps: [], verdict: verdict, output: output)
end

def joined(output: String, stderr: String) -> String
  return [output, stderr].filter do |part| part != "" end.join("\n")
end

def args(settings: Settings, bytecode: String, steps: Int, mode: String) -> List[String]
  return ["--allow-run", "--json", "--max-steps", steps.to_s, "--seed", settings.seed.to_s, "--", bytecode,
          "--agentica-test", mode]
end
