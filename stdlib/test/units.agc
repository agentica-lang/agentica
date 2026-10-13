import "report" as Report
import "child" as Child

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

enum Listed
  Ready(List[UnitTest])
  Broken(Report.Error)
end

struct TestEnd
  verdict: Report.Verdict
  output: String
  stopped: Bool
end

struct Failure
  problem: Report.Error
  stderr: String
end

export def run(settings: Settings, path: String, bytecode: String, front_end: String) -> Report.FileResult
  if front_end != ""
    parsed = Report.from_json(front_end)
    return Report.file_error(path, "tests", parsed.unwrap_or(Child.located("RUNTIME-BDD-INFRA", parsed.message, path)))
  end
  token = "#{Random.int(0, 2147483647)}-#{Random.int(0, 2147483647)}-#{Random.int(0, 2147483647)}"
  case list(settings, path, bytecode, token)
    Listed.Broken(problem) -> return Report.file_error(path, "tests", problem)
    Listed.Ready(found) ->
      chosen = found.filter do |item| settings.only == "" or item.name.include?(settings.only) end
      if chosen.size == 0
        return Report.FileResult(path: path, feature: "", kind: "tests", scenarios: [], verdict: Report.Verdict.Pass)
      end
      return run_child(settings, path, bytecode, token, chosen)
  end
end

def list(settings: Settings, path: String, bytecode: String, token: String) -> Listed
  where = Report.Span(file: path, line: 1, column: 1, end_column: 1)
  spawned = Process.spawn_captured(settings.vm, args(settings, bytecode, 1000000, "list"), ".", 30000)
  if not spawned.ok?
    return Listed.Broken(Report.error_at("RUNTIME-BDD-INFRA", spawned.message, where))
  end
  p = spawned.unwrap!
  sent = Process.send(p, token + "\n", 5000)
  Process.close_stdin(p, 5000)
  output = Process.output(p, 30000)
  code = Process.wait(p, 5000)
  Process.close(p)
  if not output.ok?
    return Listed.Broken(Report.error_at("RUNTIME-TEST-TIMEOUT", "the test file did not list its tests within 30 seconds", where))
  end
  found = output.unwrap!
  if found.truncated
    return Listed.Broken(Report.error_at("RUNTIME-BDD-OUTPUT-LIMIT", "test file output exceeds 1 MiB", where))
  end
  records = found.stdout.split("\n").map do |line| record_for(line, token) end.filter do |record| not JSON.null?(record) end
  failures = records.filter do |record| Child.event_of(record) == "fail" end
  if failures.size > 0
    return Listed.Broken(record_error(failures[0]))
  end
  ready = records.any? do |record| Child.event_of(record) == "ready" end
  if not ready or code.unwrap_or(-1) != 0
    crash = Child.stderr_diagnostic(found.stderr, where)
    if crash.ok?
      return Listed.Broken(crash.unwrap!)
    end
    if ready or not sent.ok?
      return Listed.Broken(Report.error_at("RUNTIME-BDD-PREMATURE-EXIT", "the test file exited with code #{code.unwrap_or(-1)}", where))
    end
    return Listed.Broken(Report.error_at("RUNTIME-TEST-RUN", "the test file did not call Test.run", where))
  end
  tests = records.filter do |record| Child.event_of(record) == "test" end
  return Listed.Ready((0...tests.size).to_a.map do |i|
    line = Child.int_of(tests[i], "line")
    column = Child.int_of(tests[i], "column")
    UnitTest(index: i, name: Child.text_of(tests[i], "name"),
             span: Report.Span(file: path, line: line, column: column, end_column: column))
  end)
end

def run_child(settings: Settings, path: String, bytecode: String, token: String, chosen: List[UnitTest]) -> Report.FileResult
  where = Report.Span(file: path, line: 1, column: 1, end_column: 1)
  spawned = Process.spawn_captured(settings.vm, args(settings, bytecode, 1000000 * (chosen.size + 1), "run"), ".", 30000)
  if not spawned.ok?
    return Report.file_error(path, "tests", Report.error_at("RUNTIME-BDD-INFRA", spawned.message, where))
  end
  p = spawned.unwrap!
  sent = Process.send(p, token + "\n", 5000)
  if not sent.ok?
    problem = failure(settings, p, sent.message, Time.monotonic_ms() + 5000, where).problem
    Process.close(p)
    return Report.file_error(path, "tests", problem)
  end
  results: Map[Int, Report.ScenarioResult] = {}
  stopped = false
  i = 0
  while i < chosen.size and not stopped
    item = chosen[i]
    started = Time.monotonic_ms()
    deadline = started + settings.timeout_ms
    ending = TestEnd(verdict: Report.Verdict.Pass, output: "", stopped: false)
    line_sent = Process.send(p, "#{item.index}\n", Child.left(deadline))
    if line_sent.ok?
      ending = await_test(settings, p, token, deadline, item.span)
    else
      found = failure(settings, p, line_sent.message, deadline, item.span)
      ending = TestEnd(verdict: Report.Verdict.Fail(found.problem), output: found.stderr, stopped: true)
    end
    results = results.put(i, scenario(item, Time.monotonic_ms() - started, ending.verdict, ending.output))
    stopped = ending.stopped
    i += 1
  end
  verdict = Report.Verdict.Pass
  if not stopped
    verdict = finish(settings, p, where)
  end
  Process.close(p)
  scenarios = (0...chosen.size).to_a.map do |k|
    results.get(k, scenario(chosen[k], 0, Report.Verdict.NotExecuted, ""))
  end
  return Report.FileResult(path: path, feature: "", kind: "tests", scenarios: scenarios, verdict: verdict)
end

def await_test(settings: Settings, p: Process, token: String, deadline: Int, span: Report.Span) -> TestEnd
  lines: Map[Int, String] = {}
  count = 0
  size = 0
  while true
    line = Process.read_line(p, Child.left(deadline))
    if not line.ok?
      found = failure(settings, p, line.message, deadline, span)
      return TestEnd(verdict: Report.Verdict.Fail(found.problem), output: joined(tail_text(lines, count), found.stderr),
                     stopped: true)
    end
    text = line.unwrap!
    event = Child.event_of(record_for(text, token))
    if event == "pass"
      return TestEnd(verdict: Report.Verdict.Pass, output: "", stopped: false)
    elsif event == "fail"
      return TestEnd(verdict: Report.Verdict.Fail(record_error(record_for(text, token))), output: tail_text(lines, count),
                     stopped: false)
    elsif event != ""
      problem = Report.error_at("RUNTIME-BDD-INFRA", "the test file broke the test record protocol", span)
      return TestEnd(verdict: Report.Verdict.Fail(problem), output: tail_text(lines, count), stopped: true)
    end
    size += text.length + 1
    if size > 1048576
      problem = Report.error_at("RUNTIME-BDD-OUTPUT-LIMIT", "test output exceeds 1 MiB", span)
      return TestEnd(verdict: Report.Verdict.Fail(problem), output: tail_text(lines, count), stopped: true)
    end
    lines = lines.put(count, text)
    count += 1
  end
  return TestEnd(verdict: Report.Verdict.Pass, output: "", stopped: false)
end

def finish(settings: Settings, p: Process, where: Report.Span) -> Report.Verdict
  Process.close_stdin(p, 5000)
  output = Process.output(p, settings.timeout_ms)
  if not output.ok?
    return Report.Verdict.Fail(Report.error_at("RUNTIME-TEST-TIMEOUT", "the test file did not exit after its last test", where))
  end
  code = Process.wait(p, 5000)
  if code.ok? and code.unwrap! == 0
    return Report.Verdict.Pass
  end
  crash = Child.stderr_diagnostic(output.unwrap!.stderr, where)
  if crash.ok?
    return Report.Verdict.Fail(crash.unwrap!)
  end
  return Report.Verdict.Fail(Report.error_at("RUNTIME-BDD-PREMATURE-EXIT", "the test file exited with code #{code.unwrap_or(-1)}", where))
end

def failure(settings: Settings, p: Process, message: String, deadline: Int, span: Report.Span) -> Failure
  if message == "network: operation timed out"
    return Failure(problem: Report.error_at("RUNTIME-TEST-TIMEOUT", "the test did not finish within #{settings.timeout_ms} ms", span),
                   stderr: "")
  end
  if message == "process: output exceeds 1048576 bytes" or message == "process: line exceeds 1048576 bytes"
    return Failure(problem: Report.error_at("RUNTIME-BDD-OUTPUT-LIMIT", "test output exceeds 1 MiB", span), stderr: "")
  end
  if message != "process: end of input" and message != "process: stdin is closed"
    return Failure(problem: Report.error_at("RUNTIME-BDD-IO", message, span), stderr: "")
  end
  output = Process.output(p, Child.left(deadline))
  if not output.ok?
    return Failure(problem: Report.error_at("RUNTIME-TEST-TIMEOUT", "the test did not finish within #{settings.timeout_ms} ms", span),
                   stderr: "")
  end
  stderr = output.unwrap!.stderr
  crash = Child.stderr_diagnostic(stderr, span)
  if crash.ok?
    return Failure(problem: crash.unwrap!, stderr: Child.stderr_text(stderr))
  end
  code = Process.wait(p, Child.left(deadline))
  return Failure(problem: Report.error_at("RUNTIME-BDD-PREMATURE-EXIT", "the test file exited during the test (exit code #{code.unwrap_or(-1)})", span),
                 stderr: Child.stderr_text(stderr))
end

def record_for(line: String, token: String) -> Json
  if not line.start_with?(Child.marker())
    return JSON.null()
  end
  record = Child.record_of(line)
  if Child.text_of(record, "token") != token
    return JSON.null()
  end
  return record
end

def record_error(record: Json) -> Report.Error
  range = JSON.get(record, "range").unwrap_or(JSON.null())
  start = JSON.get(range, "start").unwrap_or(JSON.null())
  stop = JSON.get(range, "end").unwrap_or(JSON.null())
  span = Report.Span(file: Child.text_of(record, "file"), line: Child.int_of(start, "line"), column: Child.int_of(start, "column"),
                     end_column: Child.int_of(stop, "column"))
  return Report.Error(code: Child.text_of(record, "code"), message: Child.text_of(record, "message"), span: span,
                      end_line: Child.int_of(stop, "line"), expected: Child.detail_of(record, "expected"),
                      actual: Child.detail_of(record, "actual"), original: JSON.null())
end

def scenario(item: UnitTest, duration_ms: Int, verdict: Report.Verdict, output: String) -> Report.ScenarioResult
  return Report.ScenarioResult(name: item.name, tags: [], location: item.span, example: Report.Example.NoExample,
                               duration_ms: duration_ms, steps: [], verdict: verdict, output: output)
end

def tail_text(lines: Map[Int, String], count: Int) -> String
  first = count
  kept = 0
  while first > 0 and kept + lines.get(first - 1, "").length + 1 <= 65536
    kept += lines.get(first - 1, "").length + 1
    first -= 1
  end
  if first == count and count > 0
    last = lines.get(count - 1, "")
    return last.slice(last.length - 65535, 65535)
  end
  return (first...count).to_a.map do |k| lines.get(k, "") end.join("\n")
end

def joined(output: String, stderr: String) -> String
  return [output, stderr].filter do |part| part != "" end.join("\n")
end

def args(settings: Settings, bytecode: String, steps: Int, mode: String) -> List[String]
  return ["--allow-run", "--json", "--max-steps", steps.to_s, "--seed", settings.seed.to_s, "--", bytecode,
          "--agentica-test", mode]
end
