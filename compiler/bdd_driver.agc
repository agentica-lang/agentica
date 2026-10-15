## The BDD driver: what `agentica test` does before and after the runner. It finds the test files,
## compiles the runner, the step program and each test file into a private run directory, writes the configuration,
## starts the runner on the VM and prints its report. The runner (stdlib/test/runner.agc) runs the scenarios and the
## tests.
##
## Every failure of the driver's own work is an infrastructure error (RUNTIME-BDD-INFRA, exit code 2) in the format the
## user asked for. A failure to compile a test file or the step program is not: it goes to the runner, which reports it
## as the error of that file.

import Compile from "bdd_compile"
import Discover from "bdd_discover"
import {IO_TIMEOUT, write_bytes, write_text} from "bdd_files"
import Opts from "bdd_options"
import Report from "bdd_report"
import RunDir from "bdd_rundir"
import Runner from "bdd_runner"
import SourceRoot from "bdd_source_root"
import DiagnosticJson from "diagnostic_json"
import Paths from "import_path"
import Env from "link_env"

# The runner is a program of two lines, and the step program a program of one call when no --steps is given.
RUNNER_ROOT = "import Runner from \"std/test/runner\"\n\ndef main() -> Void\n  Runner.main()\nend\n"
DEFAULT_STEPS = "import BDD from \"std/bdd\"\n\ndef main() -> Void\n  BDD.run([])\nend\n"

# Where the tests are when no path is given.
DEFAULT_PATHS = ["specs/", "test/"]

# The std/ sources on stdin: where each goes in the stdlib/ folder, and what it holds.
struct StdSource
  path: String
  text: String
end

struct StdSources
  files: List[StdSource]
end

# The step program, compiled: where its bytecode is (nothing is written when it did not compile), the source the
# runner names in reports, the folder for the VM's --source-root, and the diagnostic that the runner reports in place
# of the steps ("" when it compiled).
struct Steps
  bytecode: String
  source: String
  root: String
  failure: String
  given: Bool
end

## Runs `agentica test` for the options and says how it ended.
export def run(options: Opts.Options) -> Report.Ending
  if options.steps.size > 1
    return Report.usage("one --steps program; import the other files from it", options)
  end
  found = File.stat(options.vm, IO_TIMEOUT)
  if !found.ok? or found.unwrap!.kind != "file"
    message = "cannot find the VM at #{options.vm}; run make vm or set AGENTICA_VM"
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
  ending = inside(run_directory.path, options, temporary.unwrap!)
  RunDir.release(run_directory)
  return ending
end

# The run in its directory. The std/ sources are written first, and the runner compiled before anything else: its
# failure is a bug of the installation. The programs name the Agentica version of the VM that will run them.
def inside(directory: String, options: Opts.Options, temporary: String) -> Report.Ending
  installed = install_std_sources(directory)
  if !installed.ok?
    return Report.infrastructure(installed.message, temporary, options)
  end
  version = Runner.vm_version(options.vm)
  if !version.ok?
    return Report.infrastructure(version.message, options.vm, options)
  end
  settings = Env.settings("#{directory}/std", Env.process_env()).with(version: version.unwrap!)
  case compile_runner(directory, settings)
    Compile.Compiled.Rejected(problem) ->
      message = "the BDD runner does not compile: #{problem.message}"
      return Report.infrastructure(message, options.vm, options)
    Compile.Compiled.Bytes(bytes) ->
      ran = prepare_and_run(directory, options, settings, bytes)
      if !ran.ok?
        return Report.infrastructure(ran.message, temporary, options)
      end
      return ran.unwrap!
  end
end

# The std/ sources, which `agentica` has embedded and sends on stdin as {"files": [{"path": ..., "text": ...}]}, go to
# the `std` folder of the run directory, which is the stdlib/ folder of the linker. They live and die with the run.
def install_std_sources(directory: String) -> Result[Void]
  sources = try JSON.decode(IO.read(), StdSources)
  for source in sources.files
    path = "#{directory}/std/#{source.path}"
    try Dir.mkdir(Paths.directory_of(path), IO_TIMEOUT)
    try write_text(path, source.text)
  end
  return ok()
end

def compile_runner(directory: String, settings: Env.Settings) -> Compile.Compiled
  source = "#{directory}/runner.agc"
  written = write_text(source, RUNNER_ROOT)
  if !written.ok?
    return Compile.Compiled.Rejected(Report.located(source, "RUNTIME-BDD-INFRA", written.message))
  end
  return Compile.file(source, settings, "cannot read the runner")
end

# Compiles the step program and the tests, writes the files the runner reads, runs it and reads its report. An error
# is a failure of the driver itself, and a failure of the runner is part of the ending.
def prepare_and_run(
  directory: String, options: Opts.Options, settings: Env.Settings, runner: List[Int]
) -> Result[Report.Ending]
  try write_bytes("#{directory}/runner.agcb", runner)
  steps = try compile_steps(directory, options, settings)
  given = options.paths
  if given.size == 0
    given = DEFAULT_PATHS.filter do |path: String|
      found = File.stat(path, IO_TIMEOUT)
      found.ok? and found.unwrap!.kind == "directory"
    end
  end
  entries = try compile_tests(Discover.discover(given), directory, settings)
  config = Runner.Config(
    vm: options.vm,
    steps_bytecode: steps.bytecode,
    steps_source: steps.source,
    steps_root: steps.root,
    steps_error: steps.failure,
    steps_given: steps.given,
    agentica: options.agentica,
    count: entries.size,
    empty_path: empty_path(given),
    empty_message: empty_message(given),
    style: options.style,
    allow_run: options.allow_run,
    seeded: options.seeded,
    seed: options.seed,
    only: options.only,
    test_timeout_ms: options.test_timeout_ms,
    report_path: "#{directory}/report.txt",
  )
  try write_text("#{directory}/config.jsonl", Runner.config_text(config, entries))
  ran = Runner.run(options, "#{directory}/runner.agcb", "#{directory}/config.jsonl", config.report_path)
  case ran
    Runner.Ran.Reported(code, text) -> return ok(Report.Ending(code: code, text: "#{text}\n"))
    Runner.Ran.Failed(message) -> return ok(Report.infrastructure(message, options.vm, options))
  end
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
  compiled = Compile.Compiled.Bytes([])
  if options.steps.size == 0
    try write_text(source, DEFAULT_STEPS)
    compiled = Compile.file(source, settings, "cannot read the step program #{source}")
  else
    source = Path.resolve(options.steps[0]).unwrap_or(options.steps[0])
    root = SourceRoot.option(options.steps[0])
    compiled = Compile.file(source, settings, "cannot read the step program #{options.steps[0]}")
  end
  bytecode = "#{directory}/steps.agcb"
  given = options.steps.size > 0
  case compiled
    Compile.Compiled.Rejected(problem) ->
      error_text = JSON.encode(DiagnosticJson.json(problem))
      return ok(Steps(bytecode: bytecode, source: source, root: root, failure: error_text, given: given))
    Compile.Compiled.Bytes(bytes) ->
      try write_bytes(bytecode, bytes)
      return ok(Steps(bytecode: bytecode, source: source, root: root, failure: "", given: given))
  end
end

# Compiles each test file (`_test.agc`) into the run directory. A file that does not compile keeps its diagnostic in
# `front_end` for the runner to report, and writes nothing. The other entries (feature files and problems) are not
# compiled.
def compile_tests(
  entries: List[Discover.Entry], directory: String, settings: Env.Settings
) -> Result[List[Discover.Entry]]
  out: List[Discover.Entry] = []
  index = 0
  for entry in entries
    if entry.kind == "tests" and entry.problem == ""
      out = out.push(try compile_test(entry, "#{directory}/test-#{index}.agcb", settings))
    else
      out = out.push(entry)
    end
    index += 1
  end
  return ok(out)
end

def compile_test(entry: Discover.Entry, output: String, settings: Env.Settings) -> Result[Discover.Entry]
  front_end = ""
  case Compile.file(entry.path, settings, "cannot read the test file #{entry.path}")
    Compile.Compiled.Rejected(problem) -> front_end = JSON.encode(DiagnosticJson.json(problem))
    Compile.Compiled.Bytes(bytes) -> try write_bytes(output, bytes)
  end
  return ok(entry.with(bytecode: output, source_root: SourceRoot.option(entry.path), front_end: front_end))
end
