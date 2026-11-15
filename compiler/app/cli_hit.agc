## The launcher of the binary (compiler/embedded/launcher.agc): a small program that C runs before the front end, to
## start a program whose bytecode is in the cache without loading the compiler (docs/vm/08-loader-and-cli.md §9). It
## serves one case, a run of a source file with a usable cache entry, with the code the command line uses for it
## (cli_options.agc, cli_run.agc, io/bytecode_cache.agc). Everything else it declines: it returns, having printed
## nothing, and C runs the front end, which does the whole work as if the launcher had not run.

import BytecodeCache from "../io/bytecode_cache"
import Env from "../modules/link_env"
import Options from "cli_options"
import CliRun from "cli_run"

## The exit status that tells C the cache was looked at and has no usable entry for this run: C passes
## `--cache-missed` to the front end (vm/agentica.c, AGC_LAUNCHER_MISSED), which then does not look again.
MISSED_STATUS = 3

## Hands the cached program of the run that `words` ask for to C, which ends this program. It returns when the words
## are not such a run, when the cache is off for it, or when C refuses the hand-off (the front end then says why), and
## exits with MISSED_STATUS when the cache has no usable entry.
def run(settings: Env.Settings, words: List[String]) -> Void
  case Options.parse(words, settings.version)
    Options.Parsed.Answer(_) -> return
    Options.Parsed.Ready(options) ->
      return if !CliRun.file_run?(options.words)

      denied = CliRun.settings(settings, options.deny)
      plan = CliRun.cache_plan(options, denied, options.words[0], options.words[0])
      case BytecodeCache.kept(plan, denied)
        none ->
          case plan
            BytecodeCache.Plan.Off -> return
            BytecodeCache.Plan.On(_) -> System.exit(MISSED_STATUS)
          end

        some(bytes) ->
          launch = CliRun.launch(options, options.words, bytes)
          _ = FrontEnd.hand_off(launch.bytes, launch.flags, launch.arguments)
      end
  end
end
