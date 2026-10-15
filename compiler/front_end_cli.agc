## The command line of the front end, as far as the single binary needs it before the full CLI (step 8a replaces this
## module; front_end.agc calls `Cli.run`). The words are what the user typed after `agentica`:
##
##   [OPTIONS] FILE.agc [ARGUMENTS...]    compile FILE and run it with ARGUMENTS
##   [OPTIONS] compile FILE.agc -o OUT    compile FILE and write the bytecode to OUT
##   --version                            print the Agentica version
##
## OPTIONS are --allow-run, --max-steps N, --seed N and --flush-timeout MS, the options of `agentica` that the VM
## takes; they are checked here as src/main.rkt checks them and apply to the program, not to the front end. A program
## is run by FrontEnd.hand_off: the VM ends the front end and starts the program in a new runtime.
##
## Exit status: 0 for success, 1 when the program has a problem (printed on stderr as src/main.rkt prints it), 2 for a
## usage error or a file that cannot be read or written. After a hand-off it is the status of the program.

import Problems from "check_failure"
import Compile from "bdd_compile"
import Plain from "diagnostic_plain"
import Resolve from "resolve_import"
import Env from "link_env"
import SaveFile from "save_file"
import SourceFile from "source_file"
import SourceRoot from "bdd_source_root"

# The commands of src/main.rkt that this front end does not have yet.
LATER = ["check", "doc", "help", "test"]

# What the options say, as the text the VM takes after its own option name; "" when an option was not given.
struct Options
  allow_run: Bool
  max_steps: String
  seed: String
  flush_timeout: String
end

## Runs the command line.
export def run(settings: Env.Settings, arguments: List[String]) -> Void
  options = Options(allow_run: false, max_steps: "", seed: "", flush_timeout: "")
  at = 0
  while at < arguments.size and arguments[at].starts_with?("-")
    word = arguments[at]
    at += 1
    if word == "--"
      # The words after it are the command, as in src/main.rkt.
      break
    elsif word == "--version"
      puts(settings.version)
      System.exit(0)
    elsif word == "--allow-run"
      options = options.with(allow_run: true)
    elsif word == "--max-steps" or word == "--seed" or word == "--flush-timeout"
      if at >= arguments.size
        usage()
      end
      options = option(options, word, arguments[at])
      at += 1
    else
      IO.warn("agentica: unknown switch: #{word}")
      System.exit(1)
    end
  end
  words = arguments.drop(at)
  if words.size == 0
    usage()
  elsif words[0] == "compile"
    compile_command(settings, words.drop(1))
  elsif LATER.any? do |command: String| command == words[0] end
    refuse("the #{words[0]} command is not in this front end yet")
  else
    run_command(settings, options, words[0], words.drop(1))
  end
end

def usage() -> Void
  IO.warn("usage: agentica [--version] [--max-steps N] [--seed N] [--flush-timeout MS] [--allow-run]")
  IO.warn("                <source-file> [args...]")
  IO.warn("       agentica compile <source-file> -o <file.agcb>")
  System.exit(2)
end

# One option with its value, checked as src/main.rkt checks it.
def option(options: Options, name: String, value: String) -> Options
  if name == "--max-steps"
    if !positive?(value)
      refuse("--max-steps needs a positive integer")
    end
    return options.with(max_steps: value)
  elsif name == "--seed"
    if !digits?(value) or value.length > 10 or value.to_int! > 2147483647
      refuse("--seed needs an integer from 0 to 2147483647")
    end
    return options.with(seed: value)
  end
  if !digits?(value)
    refuse("--flush-timeout needs a non-negative integer")
  end
  return options.with(flush_timeout: value)
end

def refuse(message: String) -> Void
  IO.warn("agentica: #{message}")
  System.exit(2)
end

def digits?(text: String) -> Bool
  if text == ""
    return false
  end
  for character in text.split("")
    code = String.code(character)
    if code < 48 or code > 57
      return false
    end
  end
  return true
end

def positive?(text: String) -> Bool
  return digits?(text) and text.replace("0", "") != ""
end

# `agentica compile FILE -o OUT`
def compile_command(settings: Env.Settings, words: List[String]) -> Void
  if words.size != 3 or words[1] != "-o"
    usage()
  end
  bytes = compiled(settings, words[0])
  saved = SaveFile.bytes(words[2], bytes, 60000)
  if !saved.ok?
    refuse("cannot write #{words[2]}")
  end
end

# `agentica FILE ARGUMENTS...`
def run_command(settings: Env.Settings, options: Options, file: String, arguments: List[String]) -> Void
  bytes = compiled(settings, file)
  handed = FrontEnd.hand_off(bytes, vm_options(options, file), arguments)
  # The VM answers only when it refuses the hand-off; the program is running otherwise and this program is gone.
  refuse(handed.message)
end

# The options of the VM, in the words it takes.
def vm_options(options: Options, file: String) -> List[String]
  words: List[String] = []
  if options.max_steps != ""
    words = words.concat(["--max-steps", options.max_steps])
  end
  if options.seed != ""
    words = words.concat(["--seed", options.seed])
  end
  if options.flush_timeout != ""
    words = words.concat(["--flush-timeout", options.flush_timeout])
  end
  if options.allow_run
    words = words.concat(["--allow-run"])
  end
  root = SourceRoot.option(file)
  if root != ""
    words = words.concat(["--source-root", root])
  end
  return words
end

# The bytes of the program in the file, or the end of the run with its problem on stderr.
def compiled(settings: Env.Settings, file: String) -> List[Int]
  case Compile.file(file, settings, "cannot read #{file}")
    Compile.Compiled.Bytes(bytes) -> return bytes
    Compile.Compiled.Rejected(problem) -> reject(problem, settings, file)
  end
  return []
end

# A problem of the program ends the run with status 1. The text of the file it names is read again for its lines; the
# root file that cannot be read at all is a usage error. The root file is named as the user typed it, the files it
# imports by their canonical paths, as src/main.rkt does.
def reject(problem: Problems.Problem, settings: Env.Settings, file: String) -> Void
  if problem.code == "RUNTIME-BDD-INFRA"
    refuse(problem.message)
  end
  shown = problem
  if is_root?(problem.file, file)
    shown = problem.with(file: file)
  end
  IO.warn(Plain.format(shown, source_text(problem.file, settings)))
  System.exit(1)
end

def is_root?(named: String, typed: String) -> Bool
  if named == typed
    return true
  end
  real = Path.real(typed)
  return real.ok? and real.unwrap! == named
end

def source_text(file: String, settings: Env.Settings) -> String
  text = text_of(SourceFile.read(file, Env.io_timeout()))
  if text == "" and file.starts_with?("std/")
    return text_of(Resolve.read_source(settings, file))
  end
  return text
end

def text_of(read: SourceFile.Read) -> String
  case read
    SourceFile.Read.Text(text) -> return text
    SourceFile.Read.Invalid(_) -> return ""
    SourceFile.Read.Unreadable(_) -> return ""
  end
end
