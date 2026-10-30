# Running

The exact rules of the command line: running, checking and compiling a
program, the bytecode cache and the sandbox flags.

- `agentica FILE.agc ARGS` checks, then runs; `System.args()` returns ARGS (the
  words after the file are the program's). Exit 0 is success, 1 a diagnostic,
  2 bad usage or an unreadable file.
- `agentica check [PATH...]` only checks. One file path prints `check ok` (with
  `--json` `{"ok":true}`, or the diagnostic). A folder, no path (the current
  folder) or several paths check every `.agc` file, print each failing file's
  first diagnostic and a count line, and exit 1 (2 if a file is unreadable);
  with `--json` they print one object `{ok, checked, failed, files}` on stdout.
  A folder skips hidden folders, `agc_libs/`, the `deps/` of a project and
  symbolic links to files, as `symbol` does; `build/` is not skipped.
  `check --stdin FILE.agc` reads the text from standard input.
- `--ai` prints a diagnostic as compact text, `--json` as one object (the last
  stderr line, after the program's own stderr). Put them before the file.
- `agentica help NAME` prints a builtin's signature (unknown name: exit 2);
  `agentica doc PATH` the exported API of a file or `std/` module.
- `--deny-run`, `--deny-net`, `--deny-fs`, `--deny-env` and `--deny-native` make
  the blocked calls fail with `denied: --deny-X`; `--sandbox` sets all of them,
  for untrusted code. A program can start a process past one flag, so use
  `--sandbox` or add `--deny-run`.
- `--max-steps N` bounds expression and statement entries across all tasks
  (`RUNTIME-STEP-LIMIT`); it is not an I/O timeout.
- `agentica compile FILE.agc -o OUT.agcb` writes bytecode; `agentica run
  [FLAGS] -- OUT.agcb [ARGS...]` runs it (`run` only as the first word), on the
  same Agentica version only. Flags go before `--`: `--max-steps`, `--seed`,
  `--flush-timeout`, `--schedulers N`, `--jit MODE` (`on` by default, x86-64
  only), the `--deny-*` flags, `--sandbox`, `--source-root DIR`, `--ai`,
  `--json`. `agentica run --version` also lists the libraries.
- `agentica F.agc` and `agentica test` keep the compiled program of each root
  file in `_build/bytecode/`, in the folder of the nearest `agentica.toml`
  (else beside F), and read it while F, its imports, `agentica.toml`,
  `agentica.lock` and the places the `pkg/` search looked at are the same (a
  hit has no front-end diagnostics). A folder or entry that is a link, not
  yours, or writable by others is not used (`chmod go-w` a folder you made).
  `--no-cache` skips it for one run; `AGENTICA_BUILD_DIR=DIR` replaces
  `_build/`; an unwritable folder runs without it. `compile`, `--dump*` and
  `run` never use it. `check` (and the query commands) keep checked imports in
  `_build/check/` under the same rules and give the same answers with and
  without it.
- Scheduler threads (`--schedulers N`): `tasks.md`.
