## The inputs of the front end that are not the user's: the Agentica version, where the std/ sources are, and the path
## of the binary.
##
## The front end is run as `PROGRAM --version V [--stdlib DIR] [--self PATH] -- ARGUMENTS...`. The binary starts it
## with `--version V --self PATH -- ARGUMENTS...` (C passes its own version, its own path and the user's words, and
## grants the std/ sources that it carries); an ordinary run on the VM, as `make` does for the stages of the
## bootstrap, adds `--stdlib DIR` and the front end reads the std/ sources from that folder
## (docs/future/35-self-hosting.md, 35.3).

import Env from "link_env"

## What the arguments of the front end are: the settings and the words of the user, or the mistake of whoever started
## it (a bug of the caller, not a usage error of the user).
export enum Read
  Ready(Env.Settings, List[String])
  Broken(String)
end

## Reads the arguments of the front end.
export def read(arguments: List[String]) -> Read
  version = ""
  stdlib = ""
  self_path = ""
  at = 0
  while at < arguments.size and arguments[at] != "--"
    word = arguments[at]
    if at + 1 >= arguments.size or arguments[at + 1] == "--"
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
    at += 2
  end
  if at >= arguments.size
    return Read.Broken("the inputs end with --")
  elsif version == ""
    return Read.Broken("--version is required")
  end
  env = Env.process_env()
  words = arguments.drop(at + 1)
  if stdlib == ""
    return Read.Ready(Env.embedded_settings(env, version).with(self_path: self_path), words)
  end
  return Read.Ready(Env.settings(stdlib, env).with(version: version, self_path: self_path), words)
end
