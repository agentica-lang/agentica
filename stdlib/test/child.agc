import "report" as Report

export def marker() -> String
  return String.from_code(30) + "agentica-bdd "
end

export def record_of(line: String) -> Json
  at = line.index_of(marker()).unwrap_or(0) + marker().length
  return JSON.parse(line.slice(at, line.length - at)).unwrap_or(JSON.null())
end

export def event_of(record: Json) -> String
  return text_of(record, "event")
end

export def text_of(record: Json, key: String) -> String
  found = JSON.get(record, key)
  if found.ok?
    return JSON.string(found.unwrap!).unwrap_or("")
  end
  return ""
end

export def int_of(record: Json, key: String) -> Int
  found = JSON.get(record, key)
  if found.ok?
    return JSON.int(found.unwrap!).unwrap_or(1)
  end
  return 1
end

export def detail_of(record: Json, key: String) -> Report.Detail
  found = JSON.get(record, key)
  if found.ok? and JSON.string(found.unwrap!).ok?
    return Report.Detail.Known(JSON.string(found.unwrap!).unwrap!)
  end
  return Report.Detail.Unknown
end

export def left(deadline: Int) -> Int
  remaining = deadline - Time.monotonic_ms()
  if remaining < 1
    return 1
  end
  return remaining
end

export def located(code: String, message: String, path: String) -> Report.Error
  return Report.error_at(code, message, Report.Span(file: path, line: 1, column: 1, end_column: 1))
end

# A child that halts writes its --json diagnostic as the last line of stderr, and a child whose task crash was never
# observed writes the unobserved summary there; the lines of task crashes carry "task": true and are skipped.
export def stderr_diagnostic(stderr: String, span: Report.Span) -> Result[Report.Error]
  lines = stderr.split("\n").filter do |line| line != "" and not task_crash?(line) end
  if lines.size == 0
    return error("no diagnostic")
  end
  last = lines[lines.size - 1]
  summary = JSON.parse(last)
  if summary.ok? and JSON.get(summary.unwrap!, "unobserved_crashes").ok?
    count = int_of(summary.unwrap!, "unobserved_crashes")
    first = text_of(summary.unwrap!, "first")
    return ok(Report.error_at("RUNTIME-TASK-CRASHED", "#{count} task crashes not observed; first: #{first}", span))
  end
  return Report.from_json(last)
end

export def stderr_text(stderr: String) -> String
  return stderr.split("\n").filter do |line| line != "" and not task_crash?(line) and not diagnostic?(line) end.join("\n")
end

def task_crash?(line: String) -> Bool
  parsed = JSON.parse(line)
  return parsed.ok? and JSON.get(parsed.unwrap!, "task").ok?
end

def diagnostic?(line: String) -> Bool
  parsed = JSON.parse(line)
  return parsed.ok? and (JSON.get(parsed.unwrap!, "code").ok? or JSON.get(parsed.unwrap!, "unobserved_crashes").ok?)
end
