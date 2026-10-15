## What the front end is given by whoever runs it (docs/future/35-self-hosting.md, 35.3, "Front-end inputs"), and the
## shape of the hand-off of a compiled program.

## A compiled program to run: the bytes of its .agcb, the options of the VM that runs it (`--max-steps`, `--seed`,
## `--flush-timeout`, `--allow-run`, `--source-root DIR`, `--ai` or `--json`, in this order), and the arguments of the
## program (`System.args()`).
export struct Launch
  bytes: List[Int]
  flags: List[String]
  arguments: List[String]
end

## The processes a run starts. `vm` is the VM binary: the hand-off of an ordinary run starts it on the program, and
## `agentica test` starts runners and the programs under test on it. `command` is for `agentica test` too: the words
## that run this front end again (the programs under test start `agentica` themselves). `no_tests` is "" when `test`
## can run, else the reason it cannot, which the command prints. The std/ sources are not here: they are the provider
## of the `Settings` (a folder, or the single binary).
export struct Host
  vm: String
  command: List[String]
  no_tests: String
end

## The VM to use: the one the environment variable AGENTICA_VM names when it is set and not empty, else `default`. As
## Racket's `path->complete-path` does, a relative path gets the working folder in front and nothing else changes (a
## `..` or a link stays), so a message names the VM as Racket's does.
export def chosen_vm(default: String) -> String
  chosen = System.env("AGENTICA_VM")
  if !chosen.ok? or chosen.unwrap! == ""
    return default
  elsif chosen.unwrap!.starts_with?("/")
    return chosen.unwrap!
  end
  folder = Path.cwd()
  if !folder.ok?
    return chosen.unwrap!
  end
  if folder.unwrap!.ends_with?("/")
    return "#{folder.unwrap!}#{chosen.unwrap!}"
  end
  return "#{folder.unwrap!}/#{chosen.unwrap!}"
end
