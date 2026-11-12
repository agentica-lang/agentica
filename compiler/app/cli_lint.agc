## What `agentica lint [PATH...] [--strict]` says about several files: the usage line, the suggestions, the count line
## and the JSON document. Reading the files and printing is cli.agc's, which owns the output; the rules are in lint/.
##
## A suggestion is not an error: the run exits 0 however many there are, and `--strict` makes any suggestion exit 1 for
## a CI job. A file that does not lex or parse prints its diagnostic and exits 1, and a file that cannot be read exits
## 2, as for `check`.

import Core from "../analysis/analysis"
import Front from "../analysis/front"
import Diag from "../diagnostics/diagnostic"
import DiagnosticJson from "../diagnostics/diagnostic_json"
import Problems from "../diagnostics/problem"
import Lint from "../lint/lint"
import CliCheck from "cli_check"

# The usage line of `lint`, given as the help of QUERY-USAGE.
USAGE = "usage: agentica lint [PATH...] [--json] [--strict]"

## What linting one file gave. `file` is the path as it was typed or listed.
export enum Entry
  Clean(String)
  Suggested(String, List[Problems.Problem])
  Unparsed(String, Problems.Problem)
  Unreadable(String)
end

## The usage line of `agentica lint`.
export def usage() -> String = USAGE

## The entry of the file `file` whose text is `text`.
export def entry(file: String, text: String) -> Entry
  case Lint.check(file, text)
    Diag.Outcome.Failed(diagnostic) -> Entry.Unparsed(file, Front.stage_problem(file, diagnostic))
    Diag.Outcome.Done(found) ->
      return Entry.Clean(file) if found.size == 0

      Entry.Suggested(file, found)
  end
end

## The exit status of a run: 2 when a file could not be read, else 1 when a file did not parse, else 1 with `strict`
## and any suggestion, else 0.
export def status(entries: List[Entry], strict: Bool) -> Int
  if entries.any? do |entry: Entry| unreadable?(entry) end
    return 2
  elsif entries.any? do |entry: Entry| unparsed?(entry) end
    return 1
  elsif strict and suggestions(entries) > 0
    return 1
  end

  0
end

## The lines of the suggestions of one file: `file:line:column CODE message`, and its help under it.
export def suggestions_text(found: List[Problems.Problem]) -> String
  lines: List[String] = []
  for problem in found
    start = problem.span.start
    lines = lines.push("#{problem.file}:#{start.line}:#{start.column} #{problem.code} #{problem.message}")
    case problem.help
      Diag.Help.Hint(text) -> lines = lines.push("  help: #{text}")
      Diag.Help.NoHelp -> lines = lines
    end
  end

  "#{lines.join("\n")}\n"
end

## The last line of a run: that every file is fine, how many suggestions the files hold, or, when a file did not parse
## or could not be read, that the run failed (the suggestions of the other files follow after a `;`).
export def summary_text(entries: List[Entry]) -> String
  total = suggestions(entries)
  unparsed = entries.select(&unparsed?).size
  unreadable = entries.select(&unreadable?).size
  holding = entries.select(&suggested?).size
  if unparsed + unreadable == 0
    return "lint ok: #{CliCheck.files_text(entries.size)}\n" if total == 0

    return "lint: #{suggestions_count(total)} in #{holding} of #{CliCheck.files_text(entries.size)}\n"
  end

  failed = unparsed + unreadable
  line = "lint failed: #{failed} of #{CliCheck.files_text(entries.size)} could not be #{failure(unparsed, unreadable)}"
  if total > 0
    line = "#{line}; #{suggestions_count(total)} in #{CliCheck.files_text(holding)}"
  end

  "#{line}\n"
end

## The JSON document of a run: `ok` (no suggestion and no diagnostic), the number of files `checked` and of
## `suggestions`, and `files`, an entry for each file in order with its `file`, `ok` and its `suggestions` (diagnostic
## objects with a LINT- code) or, when it did not parse or read, its `diagnostic`.
export def json_text(entries: List[Entry]) -> String
  clean = entries.all? do |entry: Entry| clean?(entry) end
  document = JSON.object({
    "ok": JSON.from(clean),
    "checked": JSON.from(entries.size),
    "suggestions": JSON.from(suggestions(entries)),
    "files": JSON.array(entries.map do |entry: Entry| JSON.object(json_entry(entry)) end),
  })

  "#{JSON.encode(document)}\n"
end

def json_entry(entry: Entry) -> Map[String, JSON.Value]
  case entry
    Entry.Clean(file) -> {"file": JSON.from(file), "ok": JSON.from(true), "suggestions": JSON.array([])}
    Entry.Suggested(file, found) ->
      {
        "file": JSON.from(file),
        "ok": JSON.from(false),
        "suggestions": JSON.array(found.map do |problem: Problems.Problem| DiagnosticJson.json(problem) end),
      }
    Entry.Unparsed(file, problem) ->
      {"file": JSON.from(file), "ok": JSON.from(false), "diagnostic": DiagnosticJson.json(problem)}
    Entry.Unreadable(file) ->
      {"file": JSON.from(file), "ok": JSON.from(false), "diagnostic": DiagnosticJson.json(Core.unreadable(file))}
  end
end

def unreadable?(entry: Entry) -> Bool
  case entry
    Entry.Unreadable(_) -> true
    _ -> false
  end
end

def unparsed?(entry: Entry) -> Bool
  case entry
    Entry.Unparsed(_, _) -> true
    _ -> false
  end
end

def suggested?(entry: Entry) -> Bool
  case entry
    Entry.Suggested(_, _) -> true
    _ -> false
  end
end

def clean?(entry: Entry) -> Bool
  case entry
    Entry.Clean(_) -> true
    _ -> false
  end
end

# The number of suggestions in all the entries.
def suggestions(entries: List[Entry]) -> Int
  total = 0
  for entry in entries
    case entry
      Entry.Suggested(_, found) -> total += found.size
      _ -> total = total
    end
  end

  total
end

def suggestions_count(total: Int) -> String = "#{total} #{plural(total, "suggestion")}"

# What went wrong with the files that failed: they did not parse, could not be read, or both.
def failure(unparsed: Int, unreadable: Int) -> String
  if unreadable == 0
    return "parsed"
  elsif unparsed == 0
    return "read"
  end

  "parsed or read"
end

def plural(count: Int, word: String) -> String
  return word if count == 1

  "#{word}s"
end
