## The shape of the hand-off of a compiled program (docs/future/35-self-hosting.md, 35.3, "Front-end inputs").

## A compiled program to run: the bytes of its .agcb, the options of the VM that runs it (`--max-steps`, `--seed`,
## `--flush-timeout`, `--schedulers`, `--jit`, the `--deny-*` flags and `--sandbox` as given, `--source-root DIR`,
## `--ai` or `--json`, in this order), and the arguments of the program (`System.args()`).
export struct Launch
  bytes: Bytes
  flags: List[String]
  arguments: List[String]
end
