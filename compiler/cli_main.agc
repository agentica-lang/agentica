import Cli from "cli"
import Host from "cli_host"
import Spawn from "cli_spawn"

# `agentica-vm --allow-run -- cli_main.agcb OPTIONS -- ARGUMENTS...` is `agentica ARGUMENTS...` as an ordinary run of
# the Agentica front end (docs/future/35-self-hosting.md, step 8a), not the default yet. The options are what the
# single binary will know by itself: `--version V` (the VERSION file), `--stdlib DIR` (the stdlib/ folder, the provider
# of the `std/` sources), `--vm PATH` (the VM binary; the environment variable AGENTICA_VM replaces it, as it does for
# the Racket command line) and `--program PATH` (this file, so `agentica test` can start the command again). The exit
# status is the one of the command line. tests/agentica-agcb is the script that fills the options in.
def main() -> Void
  version = ""
  stdlib = ""
  vm = ""
  program = ""
  arguments: List[String] = []
  words = System.args()
  at = 0
  while at < words.size and words[at] != "--"
    if at + 1 >= words.size
      fail("#{words[at]} needs a value")
    end
    if words[at] == "--version"
      version = words[at + 1]
    elsif words[at] == "--stdlib"
      stdlib = words[at + 1]
    elsif words[at] == "--vm"
      vm = words[at + 1]
    elsif words[at] == "--program"
      program = words[at + 1]
    else
      fail("unknown option #{words[at]}")
    end
    at += 2
  end
  if at >= words.size or version == "" or stdlib == "" or vm == "" or program == ""
    fail("the options --version, --stdlib, --vm and --program are required, and end with --")
  end
  arguments = words.drop(at + 1)
  command = [
    vm, "--allow-run", "--", program, "--version", version, "--stdlib", stdlib, "--vm", vm, "--program", program, "--",
  ]
  chosen = System.env("AGENTICA_VM")
  if chosen.ok? and chosen.unwrap! != ""
    vm = Path.resolve(chosen.unwrap!).unwrap_or(chosen.unwrap!)
  end
  host = Host.Host(stdlib: stdlib, vm: vm, command: command)
  System.exit(Cli.run(arguments, version, host, &Spawn.hand_off))
end

def fail(message: String) -> Void
  IO.warn("cli_main: #{message}")
  System.exit(2)
end
