## Phase 27: Signals

Specified in [`docs/future/46-signals.md` section
46](../future/46-signals.md#46-signals). Phase 27 lets a program handle the stop
signals of its container, send signals to its children and to a pid it did not
start, and drain `std/http` on a stop. Its items keep the numbers of §46.7
(46a to 46d), so the spec and this file match. It is row 7.8 of the
[roadmap](README.md) order. Items 46c and 46d wait for the bootstrap of the
self-hosted front end ([§18](../future/18-front-end-language.md), step 8).
Items 46a and 46b may run earlier, as VM-only rows, when no other VM PR is
waiting.

46a and 46b are VM C code and `compiler/` builtin table rows. That
holds for option (B) of §46.3.1; option (A), or an enum parameter the
checker cannot handle, is a front-end change in `compiler/`. 46c changes
the driver in `compiler/`, so it comes after the bootstrap.
46d is Agentica code in `std/http`; it comes after 46b by the owner's order
(§46.7 does not require it). Each item has its own PR, with its own tests and
docs.

- [ ] **46a: subscription (§46.3.1 to §46.3.3, §46.7).**
  - **VM:**
    - the `Signal` enum and its names (§46.3.1), and the choice between
      options (A) and (B) for the name, made in this PR (§46.8, question 12);
    - the masks and the handler change in `vm/loop.c`; the stop set grows by
      USR1, USR2 and QUIT; the EINTR retry goes in `vm/output.c` (§46.3.2);
    - Quit takes the `_exit(131)` path (§46.3.3).
  - **Builtin data:** the rows of `compiler/builtins_data.agc` and the
    catalog regeneration of that time, checked by its test.
  - **Fixture:** `struct Signal` in `tests/fixtures/vm/http-server-close.agc`
    is renamed, since the name becomes reserved.
  - **Tests:** the C tests of `vm/tests`, and the Python cases 1, 3 (without
    the child) and 6 of §46.6, in `tests/test_vm_signals.py`.
  - **Docs:** a Signals subsection in `docs/grammar/06c-tasks-and-tests.md`;
    the reserved name in `docs/grammar/04-lexical.md`; the site page, which
    says that Ctrl-\ (Quit) stops a direct run (§46.8, question 3); the
    programming skill (`SKILL.md` for the core rule, and a reference file);
    and a `CHANGELOG.md` entry under `[Unreleased]`, marked `**Breaking:**`,
    for the reserved name and the USR1, USR2 and QUIT change.
- [ ] **46b: sending (§46.3.5 to §46.3.8, §46.7).**
  - **Builtins:** `Process.signal`, `Process.spawn_group`,
    `Process.signal_group` and `System.signal`, with the pidfd probe and
    `--allow-run` (§46.3.5 to §46.3.8; §46.8, questions 5, 8 and 11: without
    pidfd, `System.signal` returns an error).
  - **VM:** the group close and the end-of-run group kill for group children
    (§46.3.6).
  - **Tests:** the Python cases 2, 4 and 5 of §46.6, in
    `tests/test_vm_signals.py`.
  - **Docs:** `docs/grammar/06d-io-and-network.md` (Processes); the site
    Process page (`site/content/library/io-and-system/process.md`); the
    programming skill's `references/processes.md`, with its row in `SKILL.md`
    if needed; `docs/vm/10-io-processes.md` §10.4; and a `CHANGELOG.md` entry.
    The Process docs say that a group child inherits stdin, so the program must
    not read stdin while such a child runs (§46.8, question 9). The catalog is
    regenerated in the same PR, as in 46a.
- [ ] **46c: the driver (§46.7, §46.8 question 7).**
  - **Driver:** the driver starts the VM in its own process group and forwards
    the signal once (§46.8, question 7, option (c)), in place of the 2-second
    wait, which stays until then. It changes the driver of step 8 of §18, so
    it comes after the bootstrap.
  - **Tests:** a test with terminal input, written first (§46.7). §46.6 names
    no case for it, so the 46c PR specifies it.
  - **Docs:** the site page gets the container recipe, which runs
    `agentica compile` and then `agentica run` directly (§46.1) and uses
    `docker run --init` to reap orphans (§46.8, question 10); and a
    `CHANGELOG.md` entry for the driver change.
- [ ] **46d: graceful HTTP stop (§46.7).**
  - **Agentica:** a drain in `std/http`: stop accepting connections, and wait
    for the handlers to finish, up to a deadline. It is Agentica code and does
    not need the VM work of 46a or 46b in full (§46.7). It comes after 46b by
    the owner's order (§46.7 does not require it).
  - **Tests:** none is named in §46.6 yet; the 46d PR adds them, hermetic on
    localhost with port 0 and everything cleaned up, as `AGENTS.md` requires.
  - **Docs:** the `std/http` docs (the site page, and the HTTP reference of the
    programming skill, `references/network.md`) and a `CHANGELOG.md` entry
    under `[Unreleased]`.

**Done when:** a program handles TERM, INT, HUP, USR1 and USR2 and stops its
children before it exits, with QUIT as the force path; it sends signals to its
own children and to a pid it did not start (`System.signal`, with
`--allow-run`); the driver forwards a stop at once (46c); `std/http` drains its
handlers on a stop (46d); and the gh-runner entrypoint of §46.4 can be written
in Agentica. The tests of §46.6 pass, and each PR holds its own contracts.
