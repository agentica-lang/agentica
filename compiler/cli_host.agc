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

## The places a run reads from and runs in. `stdlib` is the folder of the `std/` sources (the provider of an ordinary
## run). `vm` is the VM binary: the hand-off of an ordinary run starts it on the program, and `agentica test` starts
## runners and the programs under test on it. `command` is for `agentica test` too: the words that run this front end
## again (the programs under test start `agentica` themselves). The single binary needs neither.
export struct Host
  stdlib: String
  vm: String
  command: List[String]
end
