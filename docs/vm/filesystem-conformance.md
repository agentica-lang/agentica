# Filesystem conformance evidence

This is a coverage map, not a stronger language contract. The grammar and
library documentation define the contract. Passing a subset does not prove
an untested filesystem, permission configuration or reparse driver.

## Execution boundaries

- Local destructive tests: `make tests KIND=files DOCKER=1`. The launcher in
  `tools/docker_tests.py` checks read-only root and checkout mounts, disposable
  scratch, sentinels, no network, bounded memory/processes/time and cleanup.
  Launcher failures never fall back to running on the host.
- Actions destructive tests: `tools/run_remove_actions.py` requires an
  ephemeral GitHub-hosted runner and validates scratch under `RUNNER_TEMP`.
  Victims and sibling sentinels must remain inside that scratch.
- Local Wine compatibility: `make tests KIND=files WINE=1`. A fresh prefix
  exceeds 1 GiB, so this mode alone gets a bounded 3 GiB tmpfs. Native-only
  cases skip explicitly. Wine is not native NTFS, ACL or reparse evidence.

## Windows

The `vm-windows` job builds and executes `files-test.exe` and
`each_line-test.exe`, then the selected CLI modules. Its isolated scratch
step executes `tests/test_windows_filesystem_safety.py`.

- Metadata and restricted creation: `tests/test_windows_metadata_and_locks.py`
  checks read-only mode projection, zero owner ids and actual restricted
  creators. PR #349 ran six cases natively without skips.
- Locks: the same module checks process contention, process exit/termination,
  task completion, handle close and cached awaits. Its cancellation regression
  sequences a lock-owning child and an ancestor crash through channels, then
  acquires the lock again before the process ends.
- Lines: the same module checks empty, LF/CRLF, an unterminated last line,
  malformed UTF-8 and excessive line length. An exclusive Win32 open checks
  that `each_line` closes its reader on EOF, callback error, decoding error
  and owner cancellation while its process is still alive.
- No-replace rename: the isolated suite checks competing processes, existing
  file/directory destinations, source preservation and moving junctions
  without moving their targets.
- Remove: the isolated suite checks missing entries, Unicode/long names,
  junctions, reparse ancestors, sharing conflicts and ancestor replacement.
  Additional cases cover unsafe aliases, read-only failures, denied remove
  ACLs, depth failure and releasing traversal handles on failure. Rename under
  an ACL deny is not yet claimed.
- Errors: `files-test.exe` checks the libuv-to-errno adapter and Win32 error
  translation. Unmapped codes retain EIO. PR #348 passed natively.

New regression cases must pass on their own PR head before they are treated
as native evidence. Existing merged evidence does not validate later changes.

## Linux and macOS

- Linux: isolated `tree-test`, `files_private-test`, `test_vm_os_remove` and
  BDD cleanup run in Docker locally or runner scratch in Actions.
- Both macOS architectures: `vm-test`, ordinary filesystem CLI coverage and
  isolated runner-scratch removal/rename coverage run in Platforms CI.
- Platform-specific tests do not prove the opposite platform's semantics.
  Windows mandatory byte-range locks differ from Unix advisory locks.

## Open gates

Phase 6 is not yet completely covered:

- Actual cross-volume rename: prove a real second filesystem, not merely a
  drive alias, and check source preservation on failure.
- Successful UNC mutations: a hosted-runner fixture publishes only a fresh
  scratch subdirectory to the current user, exercises localhost UNC remove
  and rename, and removes the exact share in `finally`. The native job passed
  remove, rename and sentinel checks in run `39136358678`. Share-root rejection
  is also tested.
- Reparse tags beyond the junction cases: establish safe failure or unlink
  semantics for each supported fixture; do not generalize to all drivers.
- Traversal races: the stress-style replacement case preserves sentinels but
  does not force a particular enumeration/open interleaving. Deterministic
  disappearance/replacement tests remain necessary to close that gate.

Privileged share/volume fixtures need their own confinement and cleanup
review before being added. Do not weaken an execution boundary to make a
coverage gate green, or silently count unavailable capabilities as evidence.
