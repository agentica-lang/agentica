# Repository map

Which folder or file owns something. The short tree is in `AGENTS.md`. The
`compiler/` and `stdlib/` files (but the entry programs) start with a `##`
module doc, and `vm/` and `mk/` files with a comment saying what they own:

```sh
for f in compiler/check/*.agc; do echo "== $f"; head -3 "$f"; done
```

This map names a file only when it carries a contract or a placement rule.

```text
Makefile, mk/     # the include order matters
bootstrap/        # stage0.agcb (references/ci.md)
compiler/         # the front end (§18.3): one folder per context; a new file goes in the folder of its context; imports across folders are relative (`../syntax/types`); agentica.toml holds [style] (119 columns)
  app/            # the command line (cli*.agc), the pipeline (pipeline.agc: shared by the CLI and the BDD driver), front_end_cli.agc; `test` calls the BDD driver in process, which starts `settings.self_path run ...`, so a later `run` word is a usage error
  analysis/       # the semantic queries, once (§39): analysis.agc for the CLI and std/analysis; front.agc reads, links and checks for run, compile, test and the queries
  io/             # the adapter to the machine: the only stage code that reads files and the environment (host.agc builds the Workspace); package fetch and deps/, bytecode and check caches (cache_files.agc: their shared safe-file rules), stdin buffer
  syntax/         # lexer, parser, AST, types.agc (the Type enum), suggest.agc (did_you_mean), unicode_table.agc (hand-edited)
  modules/        # the linker: workspace.agc (the port of the stages to the machine), resolve_import.agc (std/, pkg/, relative; std/internal/ is for std only), link_env.agc (Env, Settings), test_main.agc (the `main` of a test file with `test_*` functions)
  packages/       # §45: manifest, lock, workspace members, cache, hash and native libraries (native_library.agc); no I/O
  check/          # the checker; check_tables.agc (hand-edited); defaults.agc (shared with lowering); check_prelude.agc and prelude_files.agc (stages.md)
  catalog/        # the builtin catalog (imports only syntax/): builtins_data.agc and prelude_data.agc (by hand)
  lower/          # the IR and lowering; lower_tables.agc holds VM_BUILTINS
  bytecode/       # the writer; bytecode_tables.agc holds the format and OPCODES (same order as agc_opcode in vm/value.h)
  docs/           # `agentica doc` (§32.5)
  format/         # `agentica fmt` (§47); refreeze stages `format` (attach.agc) and `fmt` (fmt.agc); goldens in tests/fixtures/frontend/format/
  lint/           # `agentica lint` (#970): rules.agc (the LINT- codes), rule_*.agc (one per kind of node); pure, parse only
  bdd/            # the `agentica test` driver (references/bdd.md)
  embedded/       # runner.agc and steps.agc: not stage inputs; compiled with stage2 and embedded in the binary
vm/               # the C11 VM; layers and the "Read next" table in references/vm.md
  value.c         # values and memory; the only file that includes gc.h or calls GC_*
  *_os.h          # a system difference sits behind an `_os.h` header, one file per system
  agentica.c      # main: `run`, else the front end in a first runtime, retired at the hand-off, then the program in a second
  tests/          # C tests (references/vm-tests.md)
tests/            # pytest modules test_<area>.py
  test_spec_<area>.py   # language rules through the CLI; helpers in spec_support.py
  test_frontend_<stage>.py  # Agentica stages against frozen outputs (references/frontend.md); frontend_support.py, frontend_cases.py
  test_vm_diff_{1..8}.py  # golden shards; 8 is the command line, process, signal and path cases; vm_diff_support.py (references/vm-build.md)
  test_conformance.py   # every module is in an area of tools/conformance.py (references/ci.md)
  eval/           # agent evaluation, not part of make test (references/bench-eval.md)
stdlib/           # std/ modules, embedded in the binary; MODULES is the registry; CORE lists the compiler/ files std/analysis embeds as std/internal/compiler/<path>
  prelude/        # bodies of List, Map, Lazy, String and Bytes methods; not importable (references/stages.md)
  bdd/ test/      # internal to agentica test (references/bdd.md)
```
