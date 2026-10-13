import "report" as Report
import "child" as Child

export struct Settings
  vm: String
  seed: Int
  token: String
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
        return Report.FileResult(path: path, feature: "", kind: "tests", scenarios: [], verdict: Report.Verdict.Pass, output: "")
      end
      return run_child(settings, path, bytecode, chosen)
  end
end

def list(settings: Settings, path: String, bytecode: String) -> Listed
  where = Report.Span(file: path, line: 1, column: 1, end_column: 1)
  spawned = Process.spawn_captured(settings.vm, args(settings, bytecode, 1000000, "list"), ".", 30000)
  if not spawned.ok?
    return broken(Report.error_at("RUNTIME-BDD-INFRA", spawned.message, where), "")
  end
  p = spawned.unwrap!
  Process.send(p, settings.token + "\n", 5000)
  Process.close_stdin(p, 5000)
  output = Process.output(p, 30000)
  code = Process.wait(p, 5000)
  Process.close(p)
  if not output.ok?
    return broken(Report.error_at("RUNTIME-TEST-TIMEOUT", "the test file did not list its tests within 30 seconds", where), "")
  end
  found = output.unwrap!
  lines = found.stdout.split("\n")
  records = lines.map do |line| Child.record_for(line, settings.token) end.filter do |record| not JSON.null?(record) end
  printed = lines.filter do |line| line != "" and JSON.null?(Child.record_for(line, settings.token)) end.join("\n")
  shown = Child.tail(joined(printed, Child.stderr_text(found.stderr)), 65536)
  if found.truncated
    return broken(Report.error_at("RUNTIME-BDD-OUTPUT-LIMIT", "the test file's output exceeds 1 MiB while listing its tests", where), shown)
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
      return broken(Report.error_at("RUNTIME-BDD-PREMATURE-EXIT", "the test file exited with code #{exit}", where), shown)
    end
    return broken(Report.error_at("RUNTIME-TEST-RUN", "the test file did not call Test.run", where), shown)
  end
  empty: Map[Int, UnitTest] = {}
  listed = records.filter do |record| Child.event_of(record) == "test" end.reduce(empty) do |acc: Map[Int, UnitTest], record: Json|
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
  spawned = Process.spawn_captured(settings.vm, args(settings, bytecode, 1000000 * (chosen.size + 1), "run"), ".", 30000)
  if not spawned.ok?
    return Report.file_error(path, "tests", Report.error_at("RUNTIME-BDD-INFRA", spawned.message, where))
  end
  p = spawned.unwrap!
  sent = Process.send(p, settings.token + "\n", 5000)
  if not sent.ok?
    found = failure(settings, p, sent.message, Time.monotonic_ms() + 5000, where)
    Process.close(p)
    return Report.file_failure(path, "tests", found.problem, found.output)
  end
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
    line_sent = Process.send(p, "#{item.index}\n", Child.left(deadline))
    if line_sent.ok?
      done = await_test(settings, p, deadline, item.span)
    else
      found = failure(settings, p, line_sent.message, deadline, item.span)
      done = TestEnd(verdict: Report.Verdict.Fail(found.problem), output: found.output, stopped: true, blame: found.blame)
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
  lines: Map[Int, String] = {}
  count = 0
  size = 0
  while true
    line = Process.read_line(p, Child.left(deadline))
    if not line.ok?
      found = failure(settings, p, line.message, deadline, span)
      shown = found.output
      if found.blame
        shown = Child.tail(joined(tail_text(lines, count), found.output), 65536)
      end
      return TestEnd(verdict: Report.Verdict.Fail(found.problem), output: shown, stopped: true, blame: found.blame)
    end
    text = line.unwrap!
    record = Child.record_for(text, settings.token)
    event = Child.event_of(record)
    if event == "pass"
      return TestEnd(verdict: Report.Verdict.Pass, output: "", stopped: false, blame: true)
    elsif event == "fail"
      return TestEnd(verdict: Report.Verdict.Fail(record_error(record)), output: tail_text(lines, count), stopped: false,
                     blame: true)
    elsif event != ""
      problem = Report.error_at("RUNTIME-BDD-INFRA", "the test file broke the test record protocol", span)
      return TestEnd(verdict: Report.Verdict.Fail(problem), output: tail_text(lines, count), stopped: true, blame: true)
    end
    size += text.length + 1
    if size > 1048576
      problem = Report.error_at("RUNTIME-BDD-OUTPUT-LIMIT", "test output exceeds 1 MiB", span)
      return TestEnd(verdict: Report.Verdict.Fail(problem), output: tail_text(lines, count), stopped: true, blame: true)
    end
    lines = lines.put(count, text)
    count += 1
  end
  return TestEnd(verdict: Report.Verdict.Pass, output: "", stopped: false, blame: true)
end

def finish(settings: Settings, p: Process, where: Report.Span) -> Ending
  Process.close_stdin(p, 5000)
  output = Process.output(p, settings.timeout_ms)
  if not output.ok?
    return Ending(verdict: Report.Verdict.Fail(Report.error_at("RUNTIME-TEST-TIMEOUT", "the test file did not exit after its last test", where)),
                  output: "")
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
  problem = Report.error_at("RUNTIME-BDD-PREMATURE-EXIT", "the test file exited with code #{code.unwrap_or(-1)}", where)
  return Ending(verdict: Report.Verdict.Fail(problem), output: shown)
end

def failure(settings: Settings, p: Process, message: String, deadline: Int, span: Report.Span) -> Failure
  if message == "network: operation timed out"
    return timed_out(settings, span)
  end
  if message == "process: line exceeds 1048576 bytes"
    return Failure(problem: Report.error_at("RUNTIME-BDD-OUTPUT-LIMIT", "a line of test output exceeds 1 MiB", span), output: "",
                   blame: true)
  end
  if message == "process: output exceeds 1048576 bytes"
    return overflow(settings, p, deadline, span)
  end
  if message != "process: end of input" and message != "process: stdin is closed"
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
  problem = Report.error_at("RUNTIME-BDD-PREMATURE-EXIT", "the test file exited during the test (exit code #{code.unwrap_or(-1)})", span)
  return Failure(problem: problem, output: Child.stderr_text(stderr), blame: true)
end

def overflow(settings: Settings, p: Process, deadline: Int, span: Report.Span) -> Failure
  Process.close_stdin(p, Child.left(deadline))
  output = Process.output(p, Child.left(deadline))
  if not output.ok?
    return timed_out(settings, span)
  end
  stderr = output.unwrap!.stderr
  if stderr.length < 262144
    return Failure(problem: Report.error_at("RUNTIME-BDD-OUTPUT-LIMIT", "test output exceeds 1 MiB", span), output: "", blame: true)
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
    return Child.tail(lines.get(count - 1, ""), 65535)
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
