## What `agentica check` says about several files (`check [PATH...]`): the usage line, the count line and the JSON
## document. Reading the files and printing the problems is cli.agc's, which owns the output; this file holds the texts
## and the shape of the answer, so the form of the count lives in one place.

import Core from "../analysis/analysis"
import DiagnosticJson from "../diagnostics/diagnostic_json"
import Problems from "../diagnostics/problem"

# The first line of the `--ai` form of a diagnostic (diagnostics/diagnostic_ai.agc).
AI_HEADING = "check failed: 1 error"

# The usage line of `check`, given as the help of QUERY-USAGE.
USAGE = "usage: agentica check [PATH...] [--json]   or   agentica check --stdin FILE [--json]"

## What checking one file gave. `file` is the path as it was typed or listed. A `Failed` problem is already named by
## `file`.
export enum Entry
  Passed(String)
  Unreadable(String)
  Failed(String, Problems.Problem)
end

## The usage line of `agentica check`.
export def usage() -> String
  return USAGE
end

## The number of files that did not pass.
export def failures(entries: List[Entry]) -> Int
  return entries.select do |entry: Entry| !passed?(entry) end.size
end

## The exit status of a run: 2 when a file could not be read (a QUERY- problem), else 1 when a file failed, else 0.
export def status(entries: List[Entry]) -> Int
  if entries.any? do |entry: Entry| unreadable?(entry) end
    return 2
  elsif failures(entries) > 0
    return 1
  end

  return 0
end

## The `--ai` text of a problem of `file` with the file in place of its `check failed: 1 error` heading, which the last
## line of a run says for all the files.
export def headed(file: String, text: String) -> String
  if !text.starts_with?(AI_HEADING)
    return text
  end

  return "#{file}:#{text.slice(AI_HEADING.length, text.length - AI_HEADING.length)}"
end

## The line of a run in which every file passed.
export def ok_text(total: Int) -> String
  return "check ok: #{files_text(total)}\n"
end

## The last line of a run in which some file did not pass.
export def failed_text(failed: Int, total: Int) -> String
  return "check failed: #{failed} of #{files_text(total)}\n"
end

## The JSON document of a run: `ok`, the number of files `checked` and `failed`, and `files`, an entry for each file in
## the order it was checked with its `file`, `ok` and, when it did not pass, its `diagnostic`. A file that cannot be
## read has the QUERY-USAGE diagnostic of `Core.unreadable`.
export def json_text(entries: List[Entry]) -> String
  failed = failures(entries)
  files = entries.map do |entry: Entry| JSON.object(json_entry(entry)) end
  document = JSON.object(
    {
      "ok": JSON.from(failed == 0),
      "checked": JSON.from(entries.size),
      "failed": JSON.from(failed),
      "files": JSON.array(files),
    },
  )
  return "#{JSON.encode(document)}\n"
end

def json_entry(entry: Entry) -> Map[String, Json]
  case entry
    Entry.Passed(file) -> return {"file": JSON.from(file), "ok": JSON.from(true)}
    Entry.Unreadable(file) ->
      return {
        "file": JSON.from(file),
        "ok": JSON.from(false),
        "diagnostic": DiagnosticJson.json(Core.unreadable(file)),
      }
    Entry.Failed(file, problem) ->
      return {"file": JSON.from(file), "ok": JSON.from(false), "diagnostic": DiagnosticJson.json(problem)}
  end
end

def unreadable?(entry: Entry) -> Bool
  case entry
    Entry.Unreadable(_) -> return true
    Entry.Passed(_) -> return false
    Entry.Failed(_, _) -> return false
  end
end

def passed?(entry: Entry) -> Bool
  case entry
    Entry.Passed(_) -> return true
    Entry.Unreadable(_) -> return false
    Entry.Failed(_, _) -> return false
  end
end

def files_text(count: Int) -> String
  if count == 1
    return "1 file"
  end

  return "#{count} files"
end
