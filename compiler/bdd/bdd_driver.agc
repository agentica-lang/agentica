## The BDD driver: what `agentica test` does before and after the runner. It finds the test files,
## compiles the runner, the step program and each test file into a private run directory, writes the configuration,
## starts the runner (`agentica run`, a child of the binary) and prints its report. The runner
## (stdlib/test/runner.agc) runs the scenarios and the tests. The driver runs inside the front end of the binary
## (cli.agc), which gives it the settings: the version and the provider of the `std/` sources.
##
## Every failure of the driver's own work is an infrastructure error (RUNTIME-BDD-INFRA, exit code 2) in the format the
## user asked for. A failure to compile a test file or the step program is not: it goes to the runner, which reports it
## as the error of that file.

import Pipeline from "../app/pipeline"
import DiagnosticJson from "../diagnostics/diagnostic_json"
import Paths from "../modules/import_path"
import Env from "../modules/link_env"
import Compile from "bdd_compile"
import Discover from "bdd_discover"
import {IO_TIMEOUT, write_bytes, write_text} from "bdd_files"
import Opts from "bdd_options"
import Report from "bdd_report"
import RunDir from "bdd_rundir"
import Runner from "bdd_runner"
import SourceRoot from "bdd_source_root"

# The runner is a program of two lines, and the step program a program of one call when no --steps is given. A binary
# that carries the std/ sources carries these two compiled (compiler/embedded/, made by the Makefile with the same two
# texts, which tests/test_bdd.py checks), and only a run that reads the std/ sources from a folder compiles them.
RUNNER_ROOT = "import Runner from \"std/test/runner\"\n\ndef main() -> Void\n  Runner.main()\nend\n"
DEFAULT_STEPS = "import BDD from \"std/bdd\"\n\ndef main() -> Void\n  BDD.run([])\nend\n"

# What a report names as the source of the default step program that the binary carries: no file of the run directory.
EMBEDDED_STEPS_SOURCE = "std/bdd.agc"

# Where the tests are when no path is given.
DEFAULT_PATHS = ["specs/", "test/"]

# The file that is the step program when --steps is not given and a searched folder holds it.
DEFAULT_STEPS_FILE = "steps.agc"

# The step program, compiled: where its bytecode is (nothing is written when it did not compile; "" when it is the
# default one that the binary carries), the source the runner names in reports, the folder for the VM's --source-root,
# and the diagnostic that the runner reports in place of the steps ("" when it compiled).
struct Steps
  bytecode: String
  source: String
  root: String
  failure: String
  given: Bool
end

## Runs `agentica test` for the options and says how it ended. `settings` are the caller's: the Agentica version that
## the programs it compiles are written for, and its provider of the `std/` sources (the files of a folder, or the
## binary).
export def run(options: Opts.Options, settings: Env.Settings) -> Report.Ending
  if options.steps.size > 1
    return Report.usage("one --steps program; import the other files from it", options)
  end

  found = File.stat(options.vm, IO_TIMEOUT)
  if !found.ok? or found.unwrap!.kind != "file"
    message = "cannot find agentica at #{options.vm}"
    return Report.infrastructure(message, options.vm, options)
  end

  temporary = RunDir.temporary_directory()
  if !temporary.ok?
    return Report.infrastructure(temporary.message, RunDir.temporary_candidates()[0], options)
  end

  claimed = RunDir.claim(temporary.unwrap!)
  if !claimed.ok?
    return Report.infrastructure(claimed.message, temporary.unwrap!, options)
  end

  run_directory = claimed.unwrap!
  RunDir.sweep(temporary.unwrap!, run_directory)
  ending = inside(run_directory.path, options, settings, temporary.unwrap!)
  RunDir.release(run_directory)
  return ending
end

# Whether this binary carries the runner and the default step program, compiled with the std/ sources.
def embedded?(settings: Env.Settings) -> Bool
  return settings.embedded_bdd
end

# The run in its directory. Without the binary's own runner it is compiled before anything else: its failure is a bug
# of the installation.
def inside(directory: String, options: Opts.Options, settings: Env.Settings, temporary: String) -> Report.Ending
  if embedded?(settings)
    return ended(prepare_and_run(directory, options, settings, Runner.Program.Embedded("runner")), options, temporary)
  end

  case compile_runner(directory, settings)
    Pipeline.Compiled.Rejected(problem) ->
      message = "the BDD runner does not compile: #{problem.message}"
      return Report.infrastructure(message, options.vm, options)
    Pipeline.Compiled.Bytes(bytes) ->
      file = "#{directory}/runner.agcb"
      written = write_bytes(file, bytes)
      if !written.ok?
        return Report.infrastructure(written.message, temporary, options)
      end

      return ended(prepare_and_run(directory, options, settings, Runner.Program.File(file)), options, temporary)
  end
end

# The ending of a run, or the infrastructure error that stopped it.
def ended(ran: Result[Report.Ending], options: Opts.Options, temporary: String) -> Report.Ending
  if !ran.ok?
    return Report.infrastructure(ran.message, temporary, options)
  end

  return ran.unwrap!
end

def compile_runner(directory: String, settings: Env.Settings) -> Pipeline.Compiled
  source = "#{directory}/runner.agc"
  written = write_text(source, RUNNER_ROOT)
  if !written.ok?
    return Pipeline.Compiled.Rejected(Report.located(source, "RUNTIME-BDD-INFRA", written.message))
  end

  return Compile.file(source, settings, "cannot read the runner", false)
end

# Compiles the step program and the tests, writes the files the runner reads, runs it and reads its report. An error
# is a failure of the driver itself, and a failure of the runner is part of the ending.
def prepare_and_run(
  directory: String,
  options: Opts.Options,
  settings: Env.Settings,
  runner: Runner.Program,
) -> Result[Report.Ending]
  given = options.paths
  if given.size == 0
    given = DEFAULT_PATHS.filter do |path: String|
      found = File.stat(path, IO_TIMEOUT)
      found.ok? and found.unwrap!.kind == "directory"
    end
  end

  discovered = Discover.discover(given)
  chosen = options
  # The default step program is compiled only for a run that has a feature file, and is looked for only from the paths
  # that hold one, so an unrelated steps.agc beside unit tests does not break the run.
  features = discovered.filter do |entry: Discover.Entry| entry.kind == "feature" and entry.problem == "" end
  if options.steps.size == 0 and features.size > 0
    defaults = default_steps(given.filter do |path: String| holds_feature?(path, features) end)
    if defaults.size > 1
      return ok(Report.usage("two step programs found: pass --steps FILE (#{defaults.join(", ")})", options))
    end

    chosen = options.with(steps: defaults)
  end

  steps = try compile_steps(directory, chosen, settings)
  entries = try compile_tests(discovered, directory, settings, !options.no_cache)
  config = Runner.Config(
    vm: options.vm,
    steps_bytecode: steps.bytecode,
    steps_source: steps.source,
    steps_root: steps.root,
    steps_error: steps.failure,
    steps_given: steps.given,
    agentica: options.agentica.concat(options.deny),
    count: entries.size,
    empty_path: empty_path(given),
    empty_message: empty_message(given),
    style: options.style,
    seeded: options.seeded,
    seed: options.seed,
    only: options.only,
    test_timeout_ms: options.test_timeout_ms,
    report_path: "#{directory}/report.txt",
  )
  try write_text("#{directory}/config.jsonl", Runner.config_text(config, entries, options.tags))
  ran = Runner.run(options, runner, "#{directory}/config.jsonl", config.report_path)
  case ran
    Runner.Ran.Reported(code, text) -> return ok(Report.Ending(code: code, text: "#{text}\n"))
    Runner.Ran.Failed(message) -> return ok(Report.infrastructure(message, options.vm, options))
  end
end

# The `steps.agc` that serves as the step program when --steps is not given: for each path, the nearest one in the
# folder of the path (the path itself when it is a folder) or in a parent folder, up to the working directory and
# not above it. Each file is listed once.
def default_steps(searched: List[String]) -> List[String]
  here = Path.cwd().unwrap_or("")
  found: List[String] = []
  for path in searched
    file = steps_near(path, here)
    if file != "" and !found.any? do |known: String| known == file end
      found = found.push(file)
    end
  end

  return found
end

# Whether `path` is one of `features` or a folder that holds one. Both are resolved as Discover.discover resolves them.
def holds_feature?(path: String, features: List[Discover.Entry]) -> Bool
  resolved = Path.resolve(path).unwrap_or(path)
  below = resolved
  if !below.ends_with?("/")
    below = "#{below}/"
  end

  return features.any? do |entry: Discover.Entry| entry.path == resolved or entry.path.starts_with?(below) end
end

# The nearest `steps.agc` for one path, or "" when there is none. A path that cannot be resolved has none.
def steps_near(path: String, here: String) -> String
  resolved = Path.resolve(path)
  if !resolved.ok?
    return ""
  end

  folder = resolved.unwrap!
  info = File.stat(folder, IO_TIMEOUT)
  if !info.ok? or info.unwrap!.kind != "directory"
    folder = Paths.directory_of(folder)
  end

  below = here
  if !here.ends_with?("/")
    below = "#{here}/"
  end

  inside = here != "" and (folder == here or folder.starts_with?(below))
  while folder != ""
    file = Paths.join(folder, DEFAULT_STEPS_FILE)
    found = File.stat(file, IO_TIMEOUT)
    if found.ok? and found.unwrap!.kind == "file"
      return file
    end

    parent = Paths.directory_of(folder)
    if !inside or folder == here or parent == folder
      return ""
    end

    folder = parent
  end

  return ""
end

# The paths of the empty-run report: the first path given, or the first default folder.
def empty_path(given: List[String]) -> String
  first = DEFAULT_PATHS[0]
  if given.size > 0
    first = given[0]
  end

  return Path.resolve(first).unwrap_or(first)
end

def empty_message(given: List[String]) -> String
  if given.size == 0
    return "no .feature or *_test.agc files found: neither specs/ nor test/ exists"
  end

  return "no .feature or *_test.agc files found"
end

# The step program: the file of --steps, or the default one written in the run directory.
def compile_steps(directory: String, options: Opts.Options, settings: Env.Settings) -> Result[Steps]
  source = "#{directory}/steps.agc"
  root = ""
  compiled = Pipeline.Compiled.Bytes("".bytes)
  if options.steps.size == 0 and embedded?(settings)
    return ok(Steps(bytecode: "", source: EMBEDDED_STEPS_SOURCE, root: root, failure: "", given: false))
  elsif options.steps.size == 0
    try write_text(source, DEFAULT_STEPS)
    compiled = Compile.file(source, settings, "cannot read the step program #{source}", false)
  else
    source = Path.resolve(options.steps[0]).unwrap_or(options.steps[0])
    root = SourceRoot.option(options.steps[0])
    compiled = Compile.file(source, settings, "cannot read the step program #{options.steps[0]}", !options.no_cache)
  end

  bytecode = "#{directory}/steps.agcb"
  given = options.steps.size > 0
  case compiled
    Pipeline.Compiled.Rejected(problem) ->
      error_text = JSON.encode(DiagnosticJson.json(problem))
      return ok(Steps(bytecode: bytecode, source: source, root: root, failure: error_text, given: given))
    Pipeline.Compiled.Bytes(bytes) ->
      try write_bytes(bytecode, bytes)
      return ok(Steps(bytecode: bytecode, source: source, root: root, failure: "", given: given))
  end
end

# Compiles each test file (`_test.agc`) into the run directory. A file that does not compile keeps its diagnostic in
# `front_end` for the runner to report, and writes nothing. The other entries (feature files and problems) are not
# compiled.
def compile_tests(
  entries: List[Discover.Entry],
  directory: String,
  settings: Env.Settings,
  cached: Bool,
) -> Result[List[Discover.Entry]]
  out: List[Discover.Entry] = []
  index = 0
  for entry in entries
    if entry.kind == "tests" and entry.problem == ""
      out = out.push(try compile_test(entry, "#{directory}/test-#{index}.agcb", settings, cached))
    else
      out = out.push(entry)
    end

    index += 1
  end

  return ok(out)
end

def compile_test(entry: Discover.Entry, output: String, settings: Env.Settings, cached: Bool) -> Result[Discover.Entry]
  front_end = ""
  case Compile.file(entry.path, settings, "cannot read the test file #{entry.path}", cached)
    Pipeline.Compiled.Rejected(problem) -> front_end = JSON.encode(DiagnosticJson.json(problem))
    Pipeline.Compiled.Bytes(bytes) -> try write_bytes(output, bytes)
  end

  return ok(entry.with(bytecode: output, source_root: SourceRoot.option(entry.path), front_end: front_end))
end
