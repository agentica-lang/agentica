import "report" as Report

export struct Records
  items: List[Json]
  problem: String
end

export def read_records(p: Process, deadline: Int) -> Records
  items: List[Json] = []
  while true
    line = Process.channel_read_line(p, left(deadline))
    if not line.ok?
      return Records(items: items, problem: line.message)
    end
    record = record_of(line.unwrap!)
    if not JSON.null?(record)
      items = items.push(record)
    end
  end
  return Records(items: items, problem: "")
end

export def record_of(line: String) -> Json
  return JSON.parse(line).unwrap_or(JSON.null())
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

export def gone?(message: String) -> Bool
  return message == "process: end of input" or message == "process: stdin is closed" or message == "process: channel is closed" or message.starts_with?("error writing to stream port")
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

export def printed(output: String) -> String
  if output.end_with?("\n")
    return output.slice(0, output.length - 1)
  end
  return output
end

export def tail(text: String, limit: Int) -> String
  if text.length <= limit
    return text
  end
  return text.slice(text.length - limit, limit)
end

# A child that halts writes its --json diagnostic as the last line of stderr, and a child whose task crash was never
# observed writes the unobserved summary there; the lines of task crashes carry "task": true and are skipped.
export def stderr_diagnostic(stderr: String, span: Report.Span) -> Result[Report.Error]
  lines = stderr.split("\n").filter do |line| line != "" and not vm_shape?(line, true) end
  if lines.size == 0
    return error("no diagnostic")
  end
  last = lines[lines.size - 1]
  if summary?(last)
    summary = JSON.parse(last).unwrap!
    count = int_of(summary, "unobserved_crashes")
    first = text_of(summary, "first")
    return ok(Report.error_at("RUNTIME-TASK-CRASHED", "#{count} task crashes not observed; first: #{first}", span))
  end
  if vm_shape?(last, false)
    return Report.from_json(last)
  end
  return error("no diagnostic")
end

export def stderr_text(stderr: String) -> String
  kept = stderr.split("\n").filter do |line|
    line != "" and not vm_shape?(line, true) and not vm_shape?(line, false) and not summary?(line)
  end
  return tail(kept.join("\n"), 65536)
end

def vm_shape?(line: String, task: Bool) -> Bool
  parsed = JSON.parse(line)
  if not parsed.ok?
    return false
  end
  root = parsed.unwrap!
  range = JSON.get(root, "range").unwrap_or(JSON.null())
  start = JSON.get(range, "start").unwrap_or(JSON.null())
  stop = JSON.get(range, "end").unwrap_or(JSON.null())
  fields: Map[String, Json] = {
    "code": JSON.from(text_of(root, "code")),
    "file": JSON.from(text_of(root, "file")),
    "message": JSON.from(text_of(root, "message")),
    "range": JSON.object({"start": position(start), "end": position(stop)}),
  }
  if task
    fields = fields.put("task", JSON.from(true))
  end
  return JSON.encode(JSON.object(fields)) == JSON.encode(root)
end

def position(at: Json) -> Json
  fields: Map[String, Json] = {"line": JSON.from(int_of(at, "line")), "column": JSON.from(int_of(at, "column"))}
  return JSON.object(fields)
end

def summary?(line: String) -> Bool
  parsed = JSON.parse(line)
  if not parsed.ok?
    return false
  end
  root = parsed.unwrap!
  fields: Map[String, Json] = {
    "unobserved_crashes": JSON.from(int_of(root, "unobserved_crashes")),
    "first": JSON.from(text_of(root, "first")),
  }
  return JSON.encode(JSON.object(fields)) == JSON.encode(root)
end
