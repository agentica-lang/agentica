## The shape of the hand-off of a compiled program (docs/vm/08-loader-and-cli.md §9).

## A compiled program to run: the bytes of its .agcb, the options of the VM that runs it (`--max-steps`, `--seed`,
## `--flush-timeout`, `--schedulers`, `--jit`, `--coverage FILE`, the `--deny-*` flags and `--sandbox` as given,
## `--source-root DIR`, `--ai` or `--json`, in this order), and the arguments of the program (`System.args()`).
struct Launch
  bytes: Bytes
  flags: List[String]
  arguments: List[String]
end
