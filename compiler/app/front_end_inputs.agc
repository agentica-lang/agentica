## The inputs of the front end that are not the user's: the Agentica version,
## where the std/ sources are, and the path of the binary.
##
## The front end is run as
## `PROGRAM --version V [--stdlib DIR] [--self PATH] [--embedded-bdd] [--cache-missed] [--stderr-tty] -- ARGUMENTS...`.
## The binary starts it as `--version V --self PATH [--embedded-bdd] -- ARGUMENTS...`;
## C passes its version, path and whether it carries compiled BDD programs, and
## grants the std/ sources that it carries. An ordinary VM run, as `make` does
## for bootstrap stages, adds `--stdlib DIR`, so the front end reads std/ from
## that folder (docs/vm/08-loader-and-cli.md §9).

import Host from "../io/host"
import Env from "../modules/link_env"
import Workspace from "../modules/workspace"

## What the arguments of the front end are: the settings and the words of the user, or the mistake of whoever started
## it (a bug of the caller, not a usage error of the user).
enum Read
  Ready(Env.Settings, List[String])
  Broken(String)
end

## Whether C says that the launcher looked for the cache entry of this run and found none it could use
## (`--cache-missed`, app/cli_hit.agc): the front end then compiles without looking again.
def cache_missed?(arguments: List[String]) -> Bool = marked?(arguments, MISSED)

## Whether C says that stderr is a terminal (`--stderr-tty`): a run that compiles then says so there.
def stderr_tty?(arguments: List[String]) -> Bool = marked?(arguments, TTY)

## Reads the arguments of the front end. `workspace` is the machine as the program sees it: the front end gives the
## one that verifies native artifacts (io/native_workspace.agc), the launcher the plain one (io/host.agc), which is
## all a cache lookup reads.
def read(arguments: List[String], workspace: Workspace.Workspace) -> Read
  version = ""
  stdlib = ""
  self_path = ""
  embedded_bdd = false
  at = 0
  while at < arguments.size and arguments[at] != "--"
    word = arguments[at]
    step = 2
    if word == "--embedded-bdd"
      embedded_bdd = true
      step = 1
    elsif word == MISSED or word == TTY
      step = 1
    elsif at + 1 >= arguments.size or arguments[at + 1] == "--"
      return Read.Broken("#{word} needs a value")
    elsif word == "--version"
      version = arguments[at + 1]
    elsif word == "--stdlib"
      stdlib = arguments[at + 1]
    elsif word == "--self"
      self_path = arguments[at + 1]
    else
      return Read.Broken("unknown input #{word}")
    end

    at += step
  end

  if at >= arguments.size
    return Read.Broken("the inputs end with --")
  elsif version == ""
    return Read.Broken("--version is required")
  end

  env = Host.process_env()
  words = arguments.drop(at + 1)
  if stdlib == ""
    return Read.Ready(Env.embedded_settings(workspace, env, version, embedded_bdd).with(self_path: self_path), words)
  end

  Read.Ready(Env.settings(workspace, stdlib, env).with(version: version, self_path: self_path), words)
end

private

MISSED = "--cache-missed"
TTY = "--stderr-tty"

def marked?(arguments: List[String], mark: String) -> Bool
  for word in arguments
    return false if word == "--"
    return true if word == mark
  end

  false
end
