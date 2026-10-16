import Cli from "front_end_cli"
import Inputs from "front_end_inputs"

# The front end of the `agentica` binary: the program that C loads from its own data (or from --front-end FILE), that
# compiles what the user asks for in memory and hands the program to C to run. docs/future/35-self-hosting.md, 35.3,
# is the contract.
#
# Arguments: `--version V [--stdlib DIR] [--embedded-bdd] -- WORDS...`
# (front_end_inputs.agc). V is the Agentica version that every .agcb header
# names; it is an input, never a constant of compiler/. Without --stdlib the
# std/ sources come from the binary (FrontEnd.std_source); with it, from the
# files of DIR. WORDS are what the user typed after `agentica`.
#
# What it does: front_end_cli.agc, which step 8a replaces with the full CLI. It never reads standard input, never
# opens a file the user did not name, and writes only the file `compile` is asked for. Exit status: 0, 1 for a problem
# in the user's program (on stderr), 2 for a usage error or an input it cannot read or write; a run ends with the
# status of the program (FrontEnd.hand_off). A start with bad arguments is status 2 and a message that says so.
def main() -> Void
  case Inputs.read(System.args())
    Inputs.Read.Ready(settings, words) -> Cli.run(settings, words)
    Inputs.Read.Broken(message) ->
      IO.warn("agentica: the front end was started wrongly: #{message}")
      System.exit(2)
  end
end
