## The reports that the driver writes itself, as one file error: a usage error and an infrastructure error. The
## reports of the tests come from the runner (stdlib/test/runner.agc).

import Diag from "../diagnostics/diagnostic"
import DiagnosticJson from "../diagnostics/diagnostic_json"
import Problems from "../diagnostics/problem"
import Source from "../syntax/source"
import Opts from "bdd_options"

## How a run ends: the exit code and the text to print.
export struct Ending
  code: Int
  text: String
end

## The report of a usage error. It is located at `<arguments>`.
export def usage(message: String, options: Opts.Options) -> Ending
  return one_error("<arguments>", "RUNTIME-BDD-USAGE", message, options)
end

## The report of an infrastructure error, located at the start of `file`.
export def infrastructure(message: String, file: String, options: Opts.Options) -> Ending
  return one_error(file, "RUNTIME-BDD-INFRA", message, options)
end

## A problem with no place of its own: the start of the file, and RUNTIME-BDD-INFRA when no code is needed.
export def located(file: String, code: String, message: String) -> Problems.Problem
  start = Source.Position(offset: 0, line: 1, column: 1)
  return Problems.problem(file, "", code, message, Source.Span(start: start, stop: start), Diag.Help.NoHelp)
end

# The report of a run that ends with this one file error: exit code 2, no scenario. The text report has no seed; the
# JSON report has the seed given with --seed, else null.
def one_error(file: String, code: String, message: String, options: Opts.Options) -> Ending
  if options.style == "json"
    seed = JSON.null()
    if options.seeded
      seed = JSON.from(options.seed)
    end

    entry = {
      "path": JSON.from(file),
      "feature": JSON.from(""),
      "kind": JSON.from(""),
      "status": JSON.from("failed"),
      "scenarios": JSON.array([]),
      "error": DiagnosticJson.json(located(file, code, message)),
    }
    report = {
      "ok": JSON.from(false),
      "passed": JSON.from(0),
      "failed": JSON.from(0),
      "skipped": JSON.from(0),
      "not_executed": JSON.from(0),
      "file_errors": JSON.from(1),
      "exit_code": JSON.from(2),
      "seed": seed,
      "files": JSON.array([JSON.object(entry)]),
    }
    return Ending(code: 2, text: "#{JSON.encode(JSON.object(report))}\n")
  end

  separator = "\n"
  if options.style == "ai"
    separator = " | "
  end

  line = "FAIL #{file}#{separator}#{file}:1:1 [#{code}] #{message}\n"
  return Ending(code: 2, text: "#{line}0 passed, 0 failed, 0 skipped, 0 not executed, 1 file errors\n")
end
