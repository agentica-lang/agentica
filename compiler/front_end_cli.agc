## The command line of the single binary: the full CLI of cli.agc, with the hand-off of 8b. The words are what the user
## typed after `agentica`; front_end.agc has read the inputs (the version, the std/ provider, the path of the binary).
##
## A program is run by FrontEnd.hand_off: C ends this front end's run and starts the program in a new runtime, so the
## program never sees the compiler, `--max-steps`, `--seed` and `--allow-run` apply to it alone, and its standard
## streams are the real ones (no copy through this process, unlike cli_spawn.agc). Exit status: 0, 1 for a problem in
## the user's program, 2 for a usage error or a file that cannot be read or written; after a hand-off, the status of
## the program.
##
## `agentica test` is not here yet. The front end runs without --allow-run (35.3), so it cannot start the test runner,
## and the binary has no command that runs a compiled file with the VM's options (step 8d adds one). It answers with
## status 2 and says why.

import Cli from "cli"
import Host from "cli_host"
import Env from "link_env"

# What `agentica test` says in the single binary, until step 8d.
NO_TESTS = "the test command is not in the single binary yet: it cannot start the test runner (step 8d)"

## Runs the command line.
export def run(settings: Env.Settings, words: List[String]) -> Void
  host = Host.Host(vm: "", command: [], no_tests: NO_TESTS)
  System.exit(Cli.run(settings, words, host, &hand_off))
end

# The VM answers only when it refuses the hand-off; the program is running otherwise and this program is gone.
def hand_off(_host: Host.Host, launch: Host.Launch) -> Int
  handed = FrontEnd.hand_off(launch.bytes, launch.flags, launch.arguments)
  IO.warn("agentica: #{handed.message}")
  return 2
end
