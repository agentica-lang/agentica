# CI, release and the copy-paste check

Read this before changing `.github/workflows/`, the Makefile, or before
adding VM source files, test peers or fixtures. The build and the release need
only a C toolchain (they start from `bootstrap/stage0.agcb`); Python tests run
through pytest, with existing `unittest.TestCase` modules supported during
migration. No job installs Racket: the Racket front end and its generators were
deleted, and `vm/unicode_data.c` is frozen, checked-in data (see
its header; a future generator must reproduce it byte for byte).

## The checks of ci.yml, sweep.yml and the release are make targets

The steps of `ci.yml` and `sweep.yml`, and the test steps of `release.yml`,
call `make` targets, so those checks run locally with the same command. In
those files only setup stays in the YAML: checkout, toolchain and `apt`
installs, caches and their keys, and the `changes` step. Still inline are
`site-examples.yml`, `platforms.yml`, `fuzz.yml` (its `make vm-fuzz` was
already a target) and the packaging steps of `release.yml` (the `strip` and
ELF checks, the archive). A new check in
`ci.yml` or `sweep.yml` gets a target first (in `.PHONY` and with a one-line
comment), then a step that calls it. Targets that are not obvious:

- `all` (the default goal, also `agentica`) builds `dist/agentica`, the one
  binary (`docs/future/18-front-end-language.md` §18.2). The chain, all in
  `build/stage/` and `build/vm/<mode>/`: a first binary
  (`build/vm/<mode>/bootstrap/agentica`, never shipped) is linked with
  `bootstrap/stage0.agcb` and the `std/` sources; it compiles `stage1`;
  `--front-end stage1` compiles `stage2`; `--front-end stage2` compiles
  `stage3`; make stops unless `stage2 == stage3`; `dist/agentica` is linked
  with `stage2`. The stages are the same bytes in every mode, and a mode
  builds only its own first binary. `make stage1`, `stage2` and `stage3` build
  the stages alone. `fixed-point` adds one check: `dist/agentica` compiles the
  front end with its own embedded sources, and that must be `stage2` again,
  and compiles `compiler/embedded/runner.agc` and `steps.agc` to the bytes
  that the binary carries (about 25 s). The first binary of the bootstrap
  carries no runner and no step program, because it has no `stage2` yet.
- Refreshing stage0 (`make stage0`). `bootstrap/stage0.agcb` is a stage2 that
  was checked in; it is the only seed of the build. Refresh it (1) after a
  change that the old stage0 cannot compile or load, and (2) before a
  release. The `stage1` recipe says which case it is: it prints that
  `bootstrap/stage0.agcb` is too old for this change. Steps: (a) if the old
  stage0 still compiles `compiler/` (a release refresh, or a change that adds
  something `compiler/` does not use yet), run `make fixed-point stage0`,
  check that the diff is only the one binary file, run `make` again (it must
  build from the new file) and commit it. (b) If it cannot (the change needs
  the new stage0: a syntax or builtin that `compiler/` itself uses, a new
  bytecode format version), split it in two PRs, as §18.2 says: the first adds
  the feature without using it in `compiler/`, and refreshes stage0; the
  second uses it. When that is not possible, compile `stage1` with another
  compiler and say so in the PR: `make stage0
STAGE1_COMPILER="path/to/agentica"`
  (a binary built from the parent commit in a second worktree); the later
  stages still run on the new first binary. A new bytecode format is harder:
  the new VM cannot load a program in the old format, so the old VM must run
  the new compiler once by hand. `make` does not automate that; the PR that
  changes the format writes the commands. `make` fails with a message when
  stage0 is too old, never with a silent difference. A stage0 is a 3.7 MB
  blob: refresh it only when needed, so the history stays small.
  Format 6 (the prelude flag) is not in the checked-in stage0 yet: the loader
  still reads format 5 (`AGC_FORMAT_PREVIOUS` in `vm/value.h`) so that the
  first binary of the bootstrap works. The next stage0 refresh makes it
  unneeded; remove it then.
- `cli` is gone (it built `dist/agentica-cli.agcb` for `tests/agentica-agcb`),
  and so are `bdd-driver` (`dist/agentica-bdd-driver.agcb`; the driver is part
  of the front end), `exe` and `vm` (the four names stay in the Makefile as
  targets that stop with a message, because `make vm` would otherwise find the
  `vm/` folder and do nothing). `test-cli` runs the tests of the product
  command line (`CLI_TESTS`) on `dist/agentica` (`AGENTICA_TEST_EXECUTABLE`;
  so the sanitizer job can run the same modules). The option and diagnostic
  forms of the command line are a golden of the whole output, messages
  included, in `tests/fixtures/cli/forms.json` (`tests/test_cli_forms.py`, like
  the VM goldens; `make goldens` rewrites it after an intended change, and the
  diff is the review).
- `test` and `test-slow` run pytest on modules named
  `tests/test_<area>.py` (design in `docs/future/18-front-end-language.md`
  §18.7). Existing `unittest.TestCase` classes are collected too. `TESTS` is a
  list of module files or directories (the default `tests/`). A leading
  `./` and a trailing `/` are ignored; any other path (a file of another kind, a
`.py`
  file outside `tests/test_<area>.py`, a name that is not a folder) fails with a
  message.
  A directory adds its own `test_*.py` files and is not searched recursively on
  purpose: `tests/eval/test_*.py` are not modules for this runner. `PY_ALONE`
  in the Makefile (`tests/test_vm_latency.py`, `tests/test_vm_task_map.py`)
lists
  modules that a directory does not pick up: they run when named, as
  `make vm-latency` and `make vm-task-map` do.
- `make tests KIND=fast|files|slow|all` is the group selector over those
  tiers: `fast` is `make test`, `slow` is `make test-slow`, `files` is the
  destructive filesystem group (Docker locally, Actions scratch in CI) and
  `all` is the three of them in that order. `DOCKER=1` runs a group in the
  Ubuntu test container and `WINE=1` runs the Windows checks of it under Wine
  (`kind=fast` and `files` only). `TESTS=` narrows only host fast/slow runs;
  Make rejects it for `files`, `all`, Docker and Wine rather than ignoring it.
  `make test`, `test-slow`, `test-bdd`, `windows-docker-check`,
`windows-docker-remove-check` and
  `windows-docker-remove-wine-check` stay as the explicit forms and delegate
  to the same routes; an unknown `KIND` fails before anything runs.
- `make goldens` also rewrites `tests/fixtures/cli/forms.json`.
  `tools/refreeze.py` (pytest, run by `make goldens` in Poetry with its
  `--fast-only` tier; the full run also rewrites the slow-tier manifests)
  rewrites the frozen
  goldens that `tests/test_frontend_<stage>.py` compare the Agentica stages
  with (`references/frontend.md`, "Frozen comparisons") from the Agentica
  stages. It is not a CI step. The Racket writers that made them
  (`make frontend-freeze`, `make frontend-snapshot`) were removed in step 8d-3
  and the Racket front end with them; the tag `bootstrap-racket` keeps both.
- Each Python module runs in its own process (`poetry run py.test
  tests/test_<area>.py` from the root), run by make itself: `make -k -O
  -j$(JOBS)` over `py-test/<file>` targets, so a failure shows that module's
  report and the other modules still run. `-O` needs GNU make 4.0 or newer
  (macOS ships 3.81; its CI jobs install GNU make as `gmake`). CI installs
  the test group from `pyproject.toml` and `poetry.lock`; test peers remain
  standard-library-only.
  The helpers are `tests/agentica_test.py` (paths,
  the VM binary, the CLI, `run` with a timeout, `compile_agc`,
  `make_temp_dir`, `compile_text`, `@slow`, `tool` for Node;
  `run(stdout_to=, stderr_to=)` sends a stream to a file such as `/dev/full`),
  and `Child` and `start_vm(flags=)` for a peer or VM read line by line
  (`next_line`, `next_stderr_line`, `stdout_text`, `wait`, `close_stdin`;
`read_stdout=False`
  for a pipe that must stay full), killed with its process group when the test
  ends, also on Ctrl-C or SIGTERM; `process_alive` (Windows: ctypes; POSIX:
  `kill 0` plus a zombie check) and `wait_until` check that a test left no
  process, `agc_literal` writes a path as an Agentica string, and `make_suite`
  and `report_cases` build and read
  `agentica test --json` suites. Without `python3`, `CI` set fails the run
  and a local run reports a skip; a missing VM binary does the same for a
  test.
- `test-slow` runs the slow tier (`AGENTICA_TEST_SLOW=1`). Existing
  `unittest.TestCase` tests use the `@slow` wrapper; pytest functions use the
  `slow` marker. The Makefile clears the flag for `make test`; local runs use
  only the fast tier.
- Timeouts, three layers, all stretched by `AGENTICA_TEST_TIMEOUT_SCALE` (a
  float, default 1; `ci.yml` and `sweep.yml` set 4 for the slow runners):
  one test (`tests/agentica_test.py`: SIGALRM per `unittest.TestCase` test,
  120 s, 900 s for `@slow`; `@timeout(seconds)` overrides it for a method or
  a class; `faulthandler` kills the module 30 s later if the signal cannot
  run); one test module (the `MODULE_LIMIT` of the Makefile:
  `timeout -k 10` around pytest; 600 s, 1800 s for `make test-slow`); the
job `timeout-minutes` of the workflow, which must
  stay larger than the module limit times the scale. Deadlines that a correct
  run must beat take `scaled(seconds)` (or `ms` in
  `tests/test_bdd_integration.py`); a
  deadline that a test expects to fire, or a bound that measures the product
  (`LIMIT_MS` of `tests/test_vm_latency.py`, the 200 ms step deadline of the
  cleanup case), stays unscaled. Step deadlines stay under the 30 s scenario
  deadline of `agentica test`, which has no flag.
- `dist/agentica` is built before `make test` and `make smoke`, and `make test`
  then starts its test workers in parallel.
- `smoke` is the example smoke runs
  (`tests/smoke.sh`, on `dist/agentica`). `dist/agentica` is a real Makefile
  rule over `compiler/*.agc`, `stdlib/*.agc`, `VERSION`, the VM objects and
  `bootstrap/stage0.agcb`, and `test`, `test-bdd`, `test-cli` and `smoke` all
  use it, so a pull never leaves a stale binary and an up-to-date one is not
  rebuilt. The process, module and distribution tests are ordinary modules of
  `make test` now (there is no `test-ci`, `test-exe` or second executable).
- `vendored-check` links the VM against the vendored OpenSSL and checks it
  (static, the submodule's version); `vendored-test` adds the TLS and HTTP
  tests on that binary.
- `vm-lint` includes the clang-tidy 19 version check; `vm-trace-off` builds
  with `TRACE=0` and checks `--version`.
- `vm-layers` (Linux only; needs `rg` and `nm`) builds the VM, compiles each
  `vm/*.h` on its own, runs `vm/tools/check-layers.sh` on the objects of the
  mode (`docs/vm/15-layers.md` §15.5) and its self-test. A new `vm/*.c` file
  goes in one list of the script.
- `vm-sanitize-build` and `vm-sanitize-test` (`SANITIZE_JOBS`, 4) are the
  Python modules (`VM_PY_TESTS`, the golden shards among them, run with
  `make test-py`) that run against the binary in the sanitizer job. They and
  `vm-diff-test` do not depend on `dist/agentica` on purpose: they test the
  binary that an earlier step built (`SANITIZE=1` makes `dist/agentica` the
  sanitizer build).
- VM-only artifacts under `build/` (never shipped, never in user docs): the C
  test binaries of `vm-test`, `build/vm/<mode>/agentica-vm-fuzz` (the fuzzer
  links the VM without a front end), the bootstrap first binary, and
  `build/vm/<mode>/agentica` (a second link of the binary for `vm-gc-stress`
  and `vendored-check`, so they do not replace `dist/agentica`).
  `AGENTICA_VM_BINARY=path` makes the Python tests run another build of the
  binary (`path run ...`).
- `VM_OS` is the platform the VM is built for: the host by default, or
  `Windows_NT` for the cross build below. It selects the sources, libraries,
  linker flags and the embedded object format; `OS`, which Windows sets and no
  other host does, stays the "is this Windows" test for the rest of the
  Makefile. `RUN_PROGRAM` prefixes build recipes that must execute a program
  they have just compiled; `VM_TEST_RUNNER` prefixes each C test binary.
- `vm-test-binaries` builds the C test programs of `vm-test` without running
  them. `windows-docker-build` uses the pinned image in
  `tools/windows-check.Dockerfile` (llvm-mingw's UCRT toolchain and Wine) to
  cross-build `dist/agentica.exe` and those programs. Wine is required in the
  build container too: the self-hosting bootstrap runs each Windows binary to
  compile the next stage. `windows-docker-check` uses a second container from
  the same image to run the C tests and the Windows `platforms.yml` Python
  modules (`test_single_binary.py`, `test_source_paths.py` and
  `test_platform_bootstrap.py`) against wrappers that launch the Windows
  executable through Wine. To add fast modules, pass
  `WINDOWS_TEST_MODULES="tests/test_foo.py ..."`. Each container mounts the
  checkout as the current user; `VM_OS=Windows_NT`,
  `AGENTICA_GC=vendored`, `AGENTICA_OPENSSL=vendored` and the COFF embedding
  are selected for the cross build. The Wine prefix stays in
  `build/wine-home`, so it is made once. It needs Docker with BuildKit and
  the buildx plugin, the network for the pinned toolchain archive and base
  image, and about 6 GB of disk; no Windows machine. Override `WINDOWS_IMAGE` or
`WINDOWS_DOCKERFILE` to use another
  image. No CI job calls these targets. Wine is not a substitute for native
  Windows CI; tests relying on Windows process creation, command-line UTF-16
  conversion or symlink resolution can differ under Wine.
  Docker is the local isolation layer for the destructive filesystem group
  (`make tests KIND=files`, `make test-bdd`). `docker-test-image` builds the
  Ubuntu test container from `tools/ubuntu-test.Dockerfile` (Ubuntu 26.04;
  `TEST_BASE` selects the base) with `build-essential`, `libgc-dev`,
  `libssl-dev`, `nodejs`, `pkg-config`, `perl` and `python3`, so the container
  builds the checkout against the distribution libgc/OpenSSL instead of the
  vendored ones. `tools/docker-tests.sh
  --mode fast|files|slow|all|bdd|probe` runs one group in one owned container:
  read-only root and checkout, disposable `/tmp` tmpfs, two named volumes over
  `/source/build` and `/source/dist` (named after the image id, so a rebuilt
  image builds again; `docker volume ls` lists them), no capabilities, no
  network for the destructive modes, bounded memory/processes/time. The
  launcher probes those mounts first and always removes only its uniquely
  named container; it never falls back to the host. Isolated modules cannot be
  selected through ordinary local `test-py`: the Makefile points them to
  `make tests KIND=files`. `make test-remove-actions` is CI-only: it fails
  unless running on a GitHub-hosted Actions runner; it also runs
  `windows_remove-test`, the ordinary-file line tests (every OS) and the two
  portable lock tests (non-Windows). Each case gets a unique `RUNNER_TEMP`
  subtree and an outside sentinel detects an escape, with bounded subprocesses
  and cleanup. This is a regression guard on an ephemeral
  OS-enforced sandbox. The Linux, macOS and Windows platform jobs use that
  native route, including Windows private-handoff deletion and refusal tests.
Wine
  (`make tests KIND=files WINE=1`, `windows-docker-remove-wine-check`) is
  optional local compatibility coverage, not proof of native NTFS, ACL or
  reparse-point behavior, and the container writes its Wine prefix in the
  disposable `/tmp`. The general `windows-docker-check` mount remains writable
  and is not the destructive-test sandbox.
- `vm-diff-build` and `vm-diff-test` are the golden tests
  (`tests/test_vm_diff_*.py`);
  `sweep-full` runs them with `AGENTICA_SWEEP=full` (the weekly `sweep.yml`).
  `test-distribution` is the release's relocated-executable test
  (`tests/test_stdlib_distribution.py` copies `dist/agentica` alone away from
  the checkout and runs it, `agentica test` included).

## Windows console

`tests/test_windows_console_stop.py` runs on the Windows job (it needs a Windows
console, so Wine skips it). It starts the VM with `CREATE_NEW_PROCESS_GROUP` and
sends `CTRL_BREAK_EVENT`: the exit is 149 (128 + `SIGBREAK`), a child that
ignores the event is stopped, buffered file data is written, and a stuck stdout
does not hold the exit. Two more cases write stdout and stderr to a pseudo
console (ConPTY), which the VM writes from a pool thread with `WriteConsoleW`:
one checks the text and its order, the other a line longer than the 64 KiB
buffer, whose first write ends inside a character, and that no replacement
character reaches the console. A new process group turns Ctrl+C off, so Ctrl+C
is not sent; libuv reports both events through one console handler
(`uv_signal_t`).

`tests/test_windows_handle_counts.py` also needs native Windows (named pipes and
`GetProcessHandleCount`), so it runs on the Windows job and Wine skips it.

`tests/test_windows_process_cleanup.py` is the Windows side of the cases that
start `/bin/sh`, use SIGTERM or SIGKILL, read `/proc`, use chmod or put a shell
script in place of the binary (those are host-only on Windows and name their
counterpart): a Python child, the process list of PowerShell, an access list
(`icacls`) and a copy of `node.exe` with a preloaded script as the binary,
because the VM starts only `.exe` and `.com` files there. Wine skips it.

Piped-input tests do not exercise console input. After changing Windows stdin
handling, a check on a native Windows terminal (not Wine) is useful but does not
block a change. Save this as `console-input.agc` in a scratch directory:

```agentica
def main() -> Void
  puts("waiting")
  IO.flush()
  puts(IO.gets())
end
```

1. Run `dist/agentica.exe console-input.agc` without redirecting stdin. After
   `waiting`, type `hello` and Enter. Expect `ok("hello")` and exit 0.
2. Run it again, wait for `waiting`, then press Ctrl+C without entering text.
   Expect a prompt return, no read-error diagnostic and no surviving VM.
   libuv handles the signal on the loop even if `_read` remains blocked in
   the pool; retrying an interrupted `_read` must not be the signal handler.

The fast `test_platform_bootstrap.py` cases separately check binary stdin
(NUL, CR/LF, Ctrl+Z and 0xff), an empty open pipe while a timer runs and the
program exits, and builtin lock repetition, contention and close/reacquire.
The native C file test also checks Windows-enforced read exclusion.

## Pull requests (`.github/workflows/ci.yml`)

CI runs its checks on pull requests and pushes to `master`, on GitHub-hosted
Ubuntu runners.

- `test`: first the `changes` step (below), then `make -j vm-test test-bdd`
  (one make: the C tests run in parallel and `dist/agentica` is built beside
  them, from `bootstrap/stage0.agcb`), `make test JOBS=6` (the whole suite on
  the binary; it builds the binary first), `make test-shared` (the binary
  modules again with every shared-state lock on), `make fixed-point` (stage2
  == stage3
  from stage0, and the binary compiling the front end to stage2 again; about
  15 s after `make test` built the stages, as a step of its own so a failure
  shows alone), `make test-cli`, `make test-slow` (the `@slow` cases of the test
  files),
  `make vm-latency` and `make vm-task-map` alone after that, `make smoke` (the
example smoke runs in `tests/smoke.sh`, in parallel), the vendored OpenSSL
  check (the last step that builds), and then `make dup-check` (it runs even
  when an earlier step fails, so a clone or an npm outage does not hide the
  test results). The vm-latency negative control starts its two VMs together
  (it can only raise latency, so the control stays valid). The vendored check
stays last: it rebuilds
  `build/vm/release/obj` with other flags, so nothing that builds the binary
  may run beside it.
- `dup-check` as a job runs only on `master` pushes (it saves the npm cache).
- `vm-sanitizers` (`needs: test`, and it still runs when `test` fails):
  `make vm-lint`, one `make -j vm-test vm-fuzz`, `make vm-layers` (on the
  sanitizer objects; the job installs ripgrep if `rg` is missing), the ASan
golden,
  bytecode, trace, TCP and TLS tests, `make fixed-point` on the sanitizer
  binary (about 75 s and 1.8 GB: the VM has no GC then; it runs before
  `vm-sanitize-test`, whose `tests/test_single_binary.py` needs the sanitizer
  `dist/agentica` that it built), and the GC stress build (which does not
  run the fixed point: it collects every 64 allocations, so it links the
  `stage2` of the release build and the golden tests compile with
  `dist/agentica`). `RUNTIME-TEST-TIMEOUT` (a hung test, a 30 s deadline with
  no flag) has coverage only in the slow tier (`@slow` in
  `tests/test_unit_test.py`). The TCP tests need
  Node; the TLS tests need Node and Python 3. Both PR jobs set
  `AGENTICA_SWEEP=sampled`, so their golden and GC-stress runs sample the
  `--max-steps` sweep with a seed from `GITHUB_SHA`; a failure prints
  `AGENTICA_SWEEP_SEED`. The full sweep runs locally (`make test`), in
  `release.yml` (`AGENTICA_SWEEP=full`), and weekly in `sweep.yml` (Monday
  03:00 UTC, or by hand) on the release VM.
- OpenSSL: every CI job builds with the system OpenSSL (the default
  `AGENTICA_OPENSSL=system`; a guard step installs `libssl-dev pkg-config` when
  `pkg-config` cannot find OpenSSL 3, a no-op on our runners), the
  sanitizer and GC-stress builds too, so no job builds an instrumented
  OpenSSL. Only the release sets `AGENTICA_OPENSSL=vendored`. To keep that path
  from rotting, the last building step of `test` restores the cached vendored
  release-mode OpenSSL (restore only) and, on a hit, links
  `build/vm/release/agentica` against it, checks that `readelf -d`
  shows no `libssl` or `libcrypto` and that `run --version` names the
  submodule's version, and runs the TLS and HTTP tests on that binary. On
  a miss (a new OpenSSL key, such as a submodule bump) it skips;
  `warm-third-party` runs the same link check on `master`.
- libgc: pull request jobs build with the system libgc (the default
  `AGENTICA_GC=system`); the same guard step also installs `libgc-dev` when
  `pkg-config` cannot find `bdw-gc` 8.2.0 or newer (a no-op on the current
  runner image, which has libgc-dev 8.2.12). `GC_MIN` is 8.2.0 because that
  is the series the VM is tested with; Debian 12 and 13 and Ubuntu 24.04 and
  newer ship 8.2.x, and older systems use `AGENTICA_GC=vendored`. The jobs
  that run on `push` to `master` (`warm-third-party`), the weekly `sweep.yml`
  and the release set `AGENTICA_GC: vendored`, so the full sweep tests the GC
  the release ships and the submodule's `gc.o` stays built for the release and
  for GC stress, which always uses it. `vendored-check` links
  with the vendored libgc and OpenSSL and fails on a dynamic `libgc`, OpenSSL
  or `msys-2.0.dll` (`readelf -d`, `otool -L` or `objdump -p`);
  the release also checks the unpacked archive. The key of
  `make -s vm-third-party-key` starts with a `libgc=` line, and the VM flag
  stamps include the mode. Both modes use the same `build/vm/release/obj`
  directory; a change of mode changes the stamps, which forces a full
  recompile and relink. `fuzz.yml` stays on the system default.
- The `test` and `vm-sanitizers` jobs need Node and Python 3 for the
  network peers. The golden tests need Python 3 too (the child channel
  fixtures run through `tests/fixtures/channel-run.py`): `sweep.yml` and the
  golden step of `release.yml` print `python3 --version` before them, and
  the goldens fail in CI when it is missing.

### When `vm-sanitizers` runs

The first steps of the `test` job (the `changes` step, checkout with
`fetch-depth: 2`) diff the pull request merge commit against its base
(`git diff HEAD^1 HEAD`) and publish the result as job outputs. It runs
`vm-sanitizers` only when the VM,
lowering or bytecode files, the `std/` modules, or CI itself, change:

- `vm/`, `bootstrap/`, `compiler/front_end*`, `compiler/lower*`,
  `compiler/bytecode*`, `VERSION`;
- `tests/test_vm_diff_*`, `tests/vm_diff_support.py`, `tests/test_vm_trace.py`,
  `tests/test_vm_tcp.py`,
  `tests/fixtures/tcp-peer.js`, `tests/test_vm_tls.py`,
  `tests/fixtures/tls-peer.js`, `tests/fixtures/tls-peer.py`,
  `tests/fixtures/tls/`, `tests/test_vm_http.py`, `tests/fixtures/http-*`,
  `tests/test_vm_stop.py`, `tests/fixtures/stop-peer.py`,
  `tests/test_vm_channel.py`, `tests/fixtures/channel-peer.py`,
  `tests/test_vm_stdout.py`, `tests/fixtures/stdout-peer.py`,
  `tests/test_vm_logger.py`, `tests/fixtures/logger-peer.*`,
  `tests/test_vm_monotonic.py`, `tests/fixtures/monotonic-peer.*`,
  `tests/test_vm_file_lines.py`, `tests/fixtures/lines-peer.py`,
  `tests/test_vm_os.py`,
  `tests/test_vm_stack.py`, `tests/agentica_test.py` (the helper of the
  unittest modules),
  `tests/test_vm_test_protocol.py`, `tests/fixtures/test-protocol-peer.*`,
  `tests/test_vm_child_channel.py`, `tests/test_vm_child_channel_posix.py`,
  `tests/fixtures/child-channel*`,
  `tests/fixtures/child_channel.py`, `tests/fixtures/channel-run.py`,
  `tests/fixtures/vm/`;
- `stdlib/`: every `std/` module written in Agentica, `stdlib/bdd/` too (the
  pattern is `stdlib/*`; in a shell `case`, `*` also matches `/`);
- the Makefile, `.gitmodules`, `.clang-tidy`, `ci.yml`.

Otherwise it shows as skipped. If the `changes` step does not set its outputs,
`vm-sanitizers` still
runs. A manual run always runs it. Front-end changes (checker, AST,
builtins, `compiler/`) skip `vm-sanitizers` on purpose; the `test` job still
runs the `vm-diff` golden shards and every CLI test with the real VM. Keep
that path list in `ci.yml` in step with new VM files.

Only a manual run, or a pull request that changes `vm/trace.*` or
`vm/tests/trace_test.c`, also runs `make vm-trace-off` (`make vm-test
TRACE=0`, then it checks that `run --version` says `trace off`).

Pull requests and `master` pushes that change only docs, the site or
Markdown skip the whole CI workflow. A newer push cancels an older run.

## Conformance matrix (`platforms.yml`)

One job per system, named `conformance <platform>`: `linux-x86_64`
(`ubuntu-latest`, system libgc and OpenSSL), `windows-x86_64` (`windows-2025`,
MSYS2 UCRT64), `macos-x86_64` (`macos-15-intel`) and `macos-arm64`
(`macos-latest`); the last three link the vendored OpenSSL, as the release
does. Each job runs the same steps, so a promise of the language is tested on
every system or says why not:

1. `make vm-test`, `vendored-check` and `bootstrap-smoke` (the first binary,
   linked with `bootstrap/stage0.agcb`, passes
   `tests/test_platform_bootstrap.py` alone), then `make fixed-point` (the
   build from stage0 and stage2 == stage3).
2. One step per area of `tools/conformance.py`, `make conformance-area/<area>`
   (it writes JUnit files under `build/conformance/<area>/`): `cli`, `spec`,
   `golden` (`AGENTICA_SWEEP=sampled`), `library`, `files` (and then
   `make test-remove-actions`, the destructive cases in the runner scratch),
   `processes`, `tasks` (one worker, the timing cases) and `network`.
3. `make conformance-report`: a table in the job summary (also the tier and
   the golden sweep that ran), `summary.json` with the outcome of every case,
   and an exit code 1 when a module did not finish, a case failed, an area has
   no passed case, or a case was skipped for a reason that is not allowed.
   The destructive group is a row too: `tools/run_remove_actions.py` writes
   `build/conformance/destructive/remove-actions.xml`.

A last job, `conformance all-systems`, downloads the four `summary.json` files
(`tools/conformance.py merge`) and fails when a system is missing or a case ran
on none of them (host-only or open gap everywhere).

The areas are the lists in `tools/conformance.py`. A new `tests/test_*.py` must
be in an area or in `EXCLUDED` with a reason, or `tests/test_conformance.py`
fails. Not in the matrix: the Docker and Wine groups, the slow tier,
sanitizers, fuzz and gc-stress (`ci.yml`, `fuzz.yml`), and
`test_vm_multicore.py` (several schedulers on every system is the next step).

Run one system by hand: on that system, `make conformance` (all areas and the
report, `make conformance-area/<area>` for one; a developer machine reports the
destructive group as not run, and CI fails if it is missing). The report needs
`CONFORMANCE_PLATFORM=<name>` only to check a CI job against its name.

Skip rules, checked by the report:

- `host_only(condition, reason)` of `tests/agentica_test.py`: the system really
  lacks a capability (POSIX signals, FIFOs, `/dev/stdin`, mode bits on Windows;
  `/dev/full` on macOS; Windows handles elsewhere). The reason starts with
  `host-only:`, names the capability, and, when it names a counterpart test,
  says what that test checks. A harness limit (a test that uses `/bin/sh` for a
  behavior Windows has too) or a product gap is not host-only. The pair
  (module, system) must be in `HOST_ONLY_ALLOWED`, which a reviewer reads; a
  golden fixture named `-posix` or `-windows` is host-only on the other family
  by its name.
- `known_issue(condition, number, reason)`: the promise holds on the system but
  its test is missing, or the product has a bug. The reason is `known-issue:
  #N ...`, the number is in `KNOWN_ISSUES`, and the report lists every such
  skip under "Open gaps". Remove the skip, the entry and the issue together.
- A tool the test needs (Node, `tomllib`, IPv6) is installed by the workflow,
  and a missing one fails: `tool()` and `require()` fail when `CI` or
  `AGENTICA_REQUIRE_VM` is set. A skip for a missing tool fails the report.
- A golden fixture that differs by system is split into a shared fixture and
  `-posix` / `-windows` parts, so the shared lines run everywhere.
- A test that cannot pass because of a hosted-runner limit is not skipped
  silently: say so in the PR.

## Caches and `master` pushes

- The vendored OpenSSL's headers, `libssl.a`, `libcrypto.a` and stamp are
  cached for the release mode only, with `actions/cache`. The key is the
  hash of `make -s vm-openssl-key AGENTICA_OPENSSL=vendored` (the Configure and
  make command lines, compiler version, OpenSSL version and submodule
  commit). `warm-third-party` saves it; `test` only restores it.
- The sanitizer and GC-stress builds of yyjson, picohttpparser, libuv and
  `build/vm/gc.o` are not cached with `actions/cache`: with the ccache volume
  warm they rebuild in under a second, less than restoring the caches took.
- Every compile goes through ccache: the Makefile finds it on `PATH`, and
  the runner image (ccache 4.12) points `CCACHE_DIR` at a volume that both
  runners share (`CCACHE_MAXSIZE=5G`), so hits carry across jobs and
  pull requests. PR jobs can write to that volume, so the release sets
  `CCACHE=` (in the job env and on the `make` line) and never uses it.
- `vm-sanitizers` runs its `make` steps with `-j"$(nproc)"`, and
  `make vm-sanitize-test` runs the Python modules, the golden shards first.
`make vm-test` and `make vm-lint` run their C tests
  and clang-tidy files in parallel (`xargs -P $(JOBS)`).
- A `master` push runs no tests. It runs only `dup-check` (which also saves
  the npm cache of jscpd, keyed by `tools/jscpd/package-lock.json`) and
  one job that fills caches under the PR jobs' keys:
  - `warm-third-party` builds the vendored release-mode OpenSSL and runs
    the vendored link check.

  These exist because a pull request can restore caches saved on its own
  merge ref or on `master`, never another pull request's.

## Other workflows

Actions → Run workflow:

- `platforms.yml` is the conformance matrix (next section), on pull requests
  that carry the `platforms` label and on pushes to `master`. A manual
  dispatch may pick the system OpenSSL instead of the vendored one.
- `fuzz.yml` fuzzes the sanitizer VM with 5 million mutants and a random
  seed.

`sweep.yml` runs by schedule (Monday 03:00 UTC) and by hand: the `vm-diff`
shards on
the release VM with `AGENTICA_SWEEP=full` (`make sweep-full`). Nothing else in
CI runs on a schedule.

Two more workflows: `site-examples.yml` and `pages.yml` (see
`references/site.md`).

## Release (`release.yml`)

Four native packages, one build job each (`linux`, `macos` with a two-row
matrix, `windows`), all with `AGENTICA_OPENSSL: vendored` and
`AGENTICA_GC: vendored`, built from `bootstrap/stage0.agcb` (`make vm-test
fixed-point`). Each needs only a C toolchain:

- **Package:** `linux-x86_64` (`.tar.gz`)
  - **Runner and toolchain:** `ubuntu-latest`, pinned `zig cc` against glibc
    2.28 (`CC` in `GITHUB_ENV`)
- **Package:** `windows-x86_64` (`.zip`)
  - **Runner and toolchain:** `windows-2025`, MSYS2 UCRT64 GCC (the shell is
    `msys2 {0}`, `PYTHON=python`)
- **Package:** `macos-x86_64` (`.tar.gz`)
  - **Runner and toolchain:** `macos-15-intel`, Apple clang, `gmake`,
    `MACOSX_DEPLOYMENT_TARGET=12.0`
- **Package:** `macos-arm64` (`.tar.gz`)
  - **Runner and toolchain:** `macos-latest`, the same

Per package, in order: build, strip (macOS: `strip -x` then `codesign --force
--sign -`, an ad hoc signature that arm64 needs; there is no Developer ID
signature or notarization, which need credentials), `make release-check`,
`make release-package`, `make release-smoke`, upload `agentica-PLATFORM`.
`RELEASE_PLATFORM` (env, from the matrix) names the package; the Makefile
derives the check format and the architecture from it and
`tools/release-check.sh` compares that architecture with the machine and with
the binary, so a runner that is not what its name says fails. The Linux job also
runs the golden tests with the full sweep (`make vm-diff-test`),
`make test-distribution` and the examples.

- `tools/release-check.sh elf|macho|pe BINARY ARCH FLOOR` reads the real format
  with that system's tools. ELF: the glibc floor with `objdump -T` (an empty
  list is an error with its own message), PIE, BIND_NOW, RELRO, the stack
  protector, FORTIFY, no NEEDED `libgc`, `libssl` or `libcrypto`. Mach-O:
  `lipo -archs` is exactly the one architecture, `file`, `vtool` platform and
  `minos` equal `MACOSX_DEPLOYMENT_TARGET` (the link target of the final
  binary; it does not prove that every object or API is safe on macOS 12, and
  CI does not run macOS 12), `otool -L` lists libSystem and system paths only, PIE, stack protector, FORTIFY, a valid code signature. PE:
  `objdump -f` is `pei-x86-64`, every imported DLL is a Windows system DLL or
  the Universal C Runtime (never `msys-2.0.dll`, `libgcc_s_seh-1.dll`,
  `libwinpthread-1.dll`, a library of OpenSSL or libgc), and DllCharacteristics
  has ASLR, high-entropy ASLR and DEP. ELF and Mach-O also run `run --version`
  and compare its OpenSSL with the submodule's `VERSION.dat`; PE checks it names
  libgc. A change of a floor or of the allowed DLLs is made in that script.
- `tools/release.py package` writes `agentica-VERSION-PLATFORM.(tar.gz|zip)`
  with `bin/agentica` (`bin/agentica.exe` on Windows), `LICENSE`, `NOTICE` and
  the seven files of `licenses/` (the same set on every platform; the names are
  in `LICENSE_FILES`), then verifies the member list: exactly those files, once
  each, below one folder; a link or a device is refused. The archive is
  reproducible (commit time, root owner): the same binary gives the same
  bytes. The binary itself is not reproducible. A new third-party library adds
  its license file there.
- `tools/release.py smoke` (run it as `python -I`) first compares the packaged
  binary with the checked one, extracts into a folder with spaces and non-ASCII
  letters away from the checkout, and runs the binary there with a `PATH` of the
  system folders only (`/usr/bin:/bin`, or `System32` on Windows): `--version`,
  `run --version`, help, `check` (ok and `CHECK-TYPE-MISMATCH`), running a
  non-ASCII program, `compile` then `run --`, `--seed`, `std/` imports,
  `agentica test` for unit tests (passing and failing) and for a BDD spec
  with a step program and a predefined `Given the Agentica program` step,
  files (write,
  append, read, rename, list, stat, remove), processes (`--allow-run` spawning
  the packaged binary), and loopback TCP and HTTP (`std/http` client and
  server), which must pass on all four. TLS is covered by the OpenSSL version
  line only (it needs certificates).
- The `collect` job (every run) downloads the artifacts without merging, runs
  `tools/release.py collect` (exactly the four archives of `VERSION`: nothing
  missing, extra or duplicated; each archive verified) and uploads
  `SHA256SUMS`. The `publish` job runs only for a tag push (`version` has
  checked that the tag is `VERSION`), repeats `collect`, compares the sums, runs
  `sha256sum -c` and creates the GitHub Release with empty notes. A manual
  `workflow_dispatch` only uploads the artifacts.

Before merging a change to `release.yml`, the packaging tools or the binary
format, dispatch a dry run: `gh workflow run release.yml --ref BRANCH`. The
tags, the version and the CHANGELOG rules are under "Tags, versions and
CHANGELOG" below. Refresh `bootstrap/stage0.agcb` before cutting a release.

### Tags, versions and CHANGELOG

- The `VERSION` file at the repository root (one line, no `v`) is the single
  source of the version. `make version` prints it and the Makefile passes it to
  C as `AGC_VERSION`; `agentica --version` reports it. The Agentica front end
  takes it as an input (`Settings.version`; `--version V` in the arguments of
  `compiler/front_end.agc`), and writes it into each `.agcb` header. Keep it in
  sync with the Git tag.
- Every PR with a user-visible change adds a short entry under `## [Unreleased]`
  in `CHANGELOG.md` (Added, Changed, Removed or Fixed; start a change that
  breaks programs or CLI use with `**Breaking:**`; add the PR number).
  Internal-only work (CI, refactors, docs) needs none.
- Cutting a release (the bump PR, the tag, the release notes, the Pages
  rebuild and the checks after it): `.agents/skills/agentica-release/`.

## Copy-paste check (jscpd)

- `make dup-check` runs jscpd over C in `vm/` and Python in `tests/` with
  `.jscpd.json`. The Python scan skips `tests/eval/tasks/`, whose reference and
  candidate programs are intentionally paired, and triple-quoted text such as
  embedded Agentica programs. Its `weak` mode skips comments, so similar file
  header comments are not clones.
- jscpd is pinned with its whole dependency tree by
  `tools/jscpd/package-lock.json` and installed by `npm ci --ignore-scripts`
  into `tools/jscpd/node_modules`.
- CI runs it in the `test` job of pull requests and in its own `dup-check`
  job on `master` pushes, and fails on any clone not in
  `.jscpd-baseline.json`, so new duplicated code fails CI.
- Remove the copy instead of growing the baseline. After removing old clones,
  refresh it with `make dup-baseline` and commit the file. A reviewer must
  reject a PR that grows the baseline instead of removing a copy.

## What CI runs

- Pull requests: the jobs and their make targets are listed under "Pull
  requests" above.
- `master` pushes: `dup-check` and the cache jobs, under "Caches and `master`
  pushes".
- Schedule and by hand: `sweep.yml` and "Other workflows".
- Release: "Release (`release.yml`)".
