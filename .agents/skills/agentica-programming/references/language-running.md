# Running

Rules of the command line that `agentica --help` does not spell out; run it for
the list of commands and flags.

- `agentica FILE.agc ARGS` checks, then runs; `System.args()` returns ARGS (the
  words after the file are the program's). Exit 0 is success, 1 a diagnostic,
  2 bad usage or an unreadable file.
- `agentica check [PATH...]` only checks. One file prints `check ok` (with
  `--json` `{"ok":true}`, or the diagnostic). A folder, no path or several
  paths check every `.agc` file, print each failing file's first diagnostic and
  a count line, and exit 1 (2 if a file is unreadable); `--json` prints one
  object `{ok, checked, failed, files}`. A problem of an imported file shows
  once, not once per importer. A folder skips hidden folders,
  `agc_libs/`, `_build/`, the `deps/` of a project and symbolic links to files,
  as `symbol` does; `build/` is not skipped.
- `agentica repl` runs each entry (a line, or more while one is open) over a
  session: names, declarations and tasks live on, a redefined `def` is what
  earlier callers call, and a name changes type only through `x: T = ...`.
  `--json` prints one object per entry and command (`entry`, `line`, `ok`,
  `value`, `type`, `bound`, `declared`, `dropped`, `skipped`, `diagnostic`);
  `:type EXPR`, `:load FILE`, `:reset`, `:quit`. A struct or enum declared
  with another shape drops the names that hold it. Exit 1 when the input ends
  inside an entry (`REPL-INCOMPLETE`).
- `agentica fmt` formats in place; a file that does not parse is left as it is
  (exit 1). `[style]` of the nearest `agentica.toml` sets the width (default
  119) and `blank_line_after_end`. `agentica lint` suggests style changes
  (`LINT-` codes, never errors); it only parses, so run `check` for
  correctness. For CI, `fmt --check` and `lint --strict` exit 1 on a change.
- `--ai` prints a diagnostic as compact text, `--json` as one object (the last
  stderr line, after the program's own stderr). Put them before the file.
- `agentica help NAME` prints a builtin's signature, or a builtin type's
  fields or variants (`File.Info`) (unknown name: exit 2);
  `agentica doc PATH` the exported API of a file or `std/` module;
  `agentica help std/MODULE[.NAME]` the exports of a module or one export with
  its doc.
- `--deny-run`, `--deny-net`, `--deny-fs`, `--deny-env` and `--deny-native` make
  the blocked calls fail with `denied: --deny-X`; `--sandbox` sets all of them,
  for untrusted code. A program can start a process past one flag, so use
  `--sandbox` or add `--deny-run`.
- `--max-steps N` bounds expression and statement entries across all tasks
  (`RUNTIME-STEP-LIMIT`); it is not an I/O timeout.
- `--max-heap SIZE` (`256M`; bytes, or `K`, `M`, `G`) ends a run whose memory
  would grow past it: one stderr line with `RUNTIME-HEAP-LIMIT`, exit code 70.
  The heap starts at 32M, so a smaller size only stops it from growing.
- `--coverage FILE` writes the line coverage of the run as LCOV (the program's
  files, not `std/` or fetched packages), a failed run too; the JIT is off for
  that run. `agentica test --coverage` (no file) writes the coverage of the
  sources a test run ran to `coverage/lcov.info` (`bdd.md`).
- `agentica compile FILE.agc -o OUT.agcb` writes bytecode; `agentica run
  [FLAGS] -- OUT.agcb [ARGS...]` runs it, on the same Agentica version only.
  Flags go before `--` (`--max-steps`, `--max-heap`, `--seed`, `--schedulers N`, `--jit MODE`,
  `--deny-*`, `--sandbox`, `--source-root DIR`, `--coverage FILE`, `--ai`,
  `--json`). `agentica compile [FILE...]` (no `-o`) fills the bytecode cache
  for the files, or for every `main.agc` under `.` outside `tests/` and
  `fixtures/`, and prints `compiled F` or `fresh F` for each (exit 1 if one
  fails).
- `agentica F.agc`, `agentica compile` and `agentica test` keep the compiled
  program of each root file in `_build/bytecode/`, in the folder of the nearest
  `agentica.toml` (else beside F), and read it while F, its imports,
  `agentica.toml`, `agentica.lock` and the places the `pkg/` search looked at
  are the same (a hit has no front-end diagnostics). A folder or entry that is a
  link, not yours, or writable by others is not used (`chmod go-w` a folder you
  made). `--no-cache` skips it for one run; `AGENTICA_BUILD_DIR=DIR` replaces
  `_build/`; an unwritable folder runs without it. `--dump*`, `run` and a
  `compile` under `--deny-*` never use it. `check` and `type-at` keep checked
  imports in `_build/check/` under the same rules and give the same answers with
  and without it.
- Scheduler threads (`--schedulers N`): `tasks.md`.
