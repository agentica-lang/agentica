## The command line of the binary: the full CLI of cli.agc, with the hand-off of 8b. The words are what the user
## typed after `agentica`; front_end.agc has read the inputs (the version, the std/ provider, the path of the binary).
##
## A program is run by FrontEnd.hand_off: C ends this front end's run and starts the program in a new runtime, so the
## program never sees the compiler, `--max-steps`, `--seed` and `--allow-run` apply to it alone, and its standard
## streams are the real ones. Exit status: 0, 1 for a problem in the user's program, 2 for a usage error or a file that
## cannot be read or written; after a hand-off, the status of the program.
##
## `agentica test` runs in this process, the BDD driver (bdd_driver.agc), and starts the runner and the programs under
## test as children of the binary: `agentica run` (cli.agc). C lets the front end start processes for it; the user's
## program never runs here.

import Cli from "cli"
import Launch from "cli_launch"
import Env from "../modules/link_env"

## Runs the command line.
export def run(settings: Env.Settings, words: List[String]) -> Void
  System.exit(Cli.run(settings, words, &hand_off))
end

# The VM answers only when it refuses the hand-off; the program is running otherwise and this program is gone.
def hand_off(launch: Launch.Launch) -> Int
  handed = FrontEnd.hand_off(launch.bytes, launch.flags, launch.arguments)
  IO.warn("agentica: #{handed.message}")
  return 2
end
