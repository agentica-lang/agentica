## What a run of a program needs from the command line besides the compile: the settings a --deny-* flag changes, the
## plan of the bytecode cache, and the hand-off of the bytes. The command line (cli.agc) uses them for a run and for
## `compile`; they import no stage of the front end.

import SourceRoot from "../bdd/bdd_source_root"
import BytecodeCache from "../io/bytecode_cache"
import Env from "../modules/link_env"
import Launch from "cli_launch"
import Options from "cli_options"

## The first words that are commands. Any other first word is the source file of a run (cli.agc, dispatch).
COMMANDS = [
  "test",
  "help",
  "doc",
  "fmt",
  "lint",
  "install",
  "add",
  "update",
  "outline",
  "type-at",
  "symbol",
  "refs",
  "run",
  "check",
  "compile",
]

## Whether the words after the options are a run of a source file: a first word that is no command.
def file_run?(words: List[String]) -> Bool = words.size > 0 and !COMMANDS.include?(words[0])

## The settings of a run or a `compile` with the flags `deny`: under any --deny-* flag or --sandbox no native module
## is built, and the bytecode cache keeps such programs apart (Settings.native_denied).
def settings(settings: Env.Settings, deny: List[String]) -> Env.Settings
  return settings if deny.size == 0

  settings.with(native_denied: true)
end

## The bytecode cache (io/bytecode_cache.agc) serves a run and `compile` (whose bytes are the ones a fresh compile
## writes): not a listing of the tree or the IR, and not `--no-cache`. `check` never gets here. A `compile` under a
## --deny-* flag does not use it: it refuses a native module that needs a build (`builder_settings` in cli.agc), where
## a run's entry names the library by its bare name.
def cache_plan(options: Options.Options, settings: Env.Settings, verb: String, source: String) -> BytecodeCache.Plan
  denied_compile = verb == "compile" and options.deny.size > 0
  wanted = !options.no_cache and !options.dump and !options.dump_ir and !denied_compile
  BytecodeCache.plan(settings, source, wanted)
end

## The hand-off of the program `bytes` of the file `rest[0]`: the VM gets the options in a fixed order, and the
## program the words after the file as its arguments.
def launch(options: Options.Options, rest: List[String], bytes: Bytes) -> Launch.Launch
  Launch.Launch(bytes: bytes, flags: vm_flags(options, rest[0]), arguments: rest.drop(1))
end

private

# The options the VM gets, in a fixed order.
def vm_flags(options: Options.Options, source: String) -> List[String]
  flags: List[String] = []
  if options.max_steps != ""
    flags = flags.concat(["--max-steps", options.max_steps])
  end

  if options.max_heap != ""
    flags = flags.concat(["--max-heap", options.max_heap])
  end

  if options.seed != ""
    flags = flags.concat(["--seed", options.seed])
  end

  if options.flush_timeout != ""
    flags = flags.concat(["--flush-timeout", options.flush_timeout])
  end

  if options.schedulers != ""
    flags = flags.concat(["--schedulers", options.schedulers])
  end

  if options.jit != ""
    flags = flags.concat(["--jit", options.jit])
  end

  if options.coverage != ""
    flags = flags.concat(["--coverage", options.coverage])
  end

  flags = flags.concat(options.deny)
  root = SourceRoot.option(source)
  if root != ""
    flags = flags.concat(["--source-root", root])
  end

  if options.style == "ai"
    flags = flags.push("--ai")
  elsif options.style == "json"
    flags = flags.push("--json")
  end

  flags
end
