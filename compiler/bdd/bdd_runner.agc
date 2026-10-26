## Starting the BDD runner and reading what it reports.
##
## The runner (stdlib/test/runner.agc) is a program of its own, run by `agentica run` of the same binary as a captured
## child. It reads the configuration file, runs the tests and writes its report to a file of the run directory. It does
## not print the report: a captured child keeps 1 MiB of each stream and drops the rest, and a report of a big run is
## larger.

import SourceReader from "../io/source_reader"
import SourceFile from "../syntax/source_file"
import Discover from "bdd_discover"
import {IO_TIMEOUT} from "bdd_files"
import Opts from "bdd_options"

# The runner is an ordinary program with a 30 second start, and no limit on its run (each scenario has its own).
START_TIMEOUT = 30_000
WAIT_SLICE = 3_600_000
MAXIMUM_EXIT_CODE = 2

## The first line of the configuration file, as the runner decodes it (`Config` in stdlib/test/runner.agc).
export struct Config
  # The binary: the runner starts the step program and each test file with its `run` command.
  vm: String
  # The step program is the file `steps_bytecode`, or, when it is "", the default one that the binary carries
  # (`run --embedded steps`). A driver that does not know the embedded programs always writes a file.
  steps_bytecode: String
  steps_source: String
  steps_root: String
  steps_error: String
  steps_given: Bool
  agentica: List[String]
  count: Int
  empty_path: String
  empty_message: String
  style: String
  seeded: Bool
  seed: Int
  only: String
  test_timeout_ms: Int
  report_path: String
end

## The program of the runner: a file of the run directory, or the one the binary carries (`run --embedded runner`).
export enum Program
  File(String)
  Embedded(String)
end

## How a runner ended: with the exit code and the report it wrote, or with a message that says why it has no report.
export enum Ran
  Reported(Int, String)
  Failed(String)
end

## The text of the configuration file: the settings, then one line for each entry.
export def config_text(config: Config, entries: List[Discover.Entry]) -> String
  lines = [JSON.encode(config)].concat(entries.map do |entry: Discover.Entry| JSON.encode(entry) end)
  return "#{lines.join("\n")}\n"
end

## Runs the runner `program` on `config_file` with `agentica run` of the binary of the options, waits for it, and reads
## the report at `report_file`. The child gets this program's process id with --driver-pid, so it ends if this program
## does.
export def run(options: Opts.Options, program: Program, config_file: String, report_file: String) -> Ran
  words = ["run"]
  if options.seeded
    words = words.concat(["--seed", options.seed.to_s])
  end

  words = words.concat(["--driver-pid", System.pid().to_s])
  case program
    Program.File(path) -> words = words.concat(["--", path, config_file])
    Program.Embedded(name) -> words = words.concat(["--embedded", name, "--", config_file])
  end

  spawned = Process.spawn_captured(options.vm, words, ".", START_TIMEOUT)
  if !spawned.ok?
    return Ran.Failed("cannot start the BDD runner: #{spawned.message}")
  end

  child = spawned.unwrap!
  Process.close_stdin(child, IO_TIMEOUT)
  code = wait_for(child)
  output = Process.output(child, START_TIMEOUT)
  Process.close(child)
  if !code.ok?
    return Ran.Failed("the BDD runner did not end: #{code.message}")
  elsif !output.ok?
    return Ran.Failed("the BDD runner did not close its output: #{output.message}")
  end

  stderr = output.unwrap!.stderr
  if code.unwrap! < 0 or code.unwrap! > MAXIMUM_EXIT_CODE or stderr != ""
    return Ran.Failed("the BDD runner failed with exit code #{code.unwrap!}: #{message_line(stderr)}")
  end

  return read_report(code.unwrap!, report_file)
end

# Waits as long as the run takes: a wait that times out is repeated.
def wait_for(child: Process) -> Result[Int]
  waited = Process.wait(child, WAIT_SLICE)
  while !waited.ok? and waited.message == "network: operation timed out"
    waited = Process.wait(child, WAIT_SLICE)
  end

  return waited
end

def read_report(code: Int, report_file: String) -> Ran
  case SourceReader.read(report_file)
    SourceFile.Read.Text(text) -> return Ran.Reported(code, text)
    SourceFile.Read.Invalid(_) -> return Ran.Failed("the BDD runner wrote a report that is not UTF-8")
    SourceFile.Read.Unreadable(message) -> return Ran.Failed("the BDD runner wrote no report: #{message}")
  end
end

# What the runner said on stderr, in a line: the last diagnostic (the line that names its code and the one after it),
# not the stack frame that comes last. An earlier diagnostic, such as the crash of a task, is not the reason the
# runner ended.
def message_line(text: String) -> String
  lines = text.split("\n").filter do |line: String| line != "" end
  if lines.size == 0
    return "no diagnostic"
  end

  first = 0
  index = 0
  for line in lines
    if diagnostic_header?(line)
      first = index
    end

    index += 1
  end

  return lines.drop(first).take(2).join(" ")
end

# `PLACE:LINE:COLUMN error[CODE]` and nothing after it.
def diagnostic_header?(line: String) -> Bool
  marker = line.index_of(" error[")
  if !marker.ok? or !line.ends_with?("]")
    return false
  end

  place = line.slice(0, marker.unwrap!).split(":")
  code = line.slice(marker.unwrap! + 7, line.length - marker.unwrap! - 8)
  if place.size < 3 or code == "" or place.take(place.size - 2).join(":") == ""
    return false
  end

  return number?(place[place.size - 1]) and number?(place[place.size - 2]) and code_text?(code)
end

def number?(text: String) -> Bool
  return text.length > 0 and text.to_int.ok? and !text.starts_with?("-") and !text.starts_with?("+")
end

def code_text?(text: String) -> Bool
  for character in text.split("")
    point = String.code(character)
    if !((point >= 65 and point <= 90) or (point >= 48 and point <= 57) or point == 45)
      return false
    end
  end

  return true
end
