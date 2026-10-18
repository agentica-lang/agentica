## Phase 25: Unit tests

The rules are in the grammar
([`06c-tasks-and-tests.md`](../grammar/06c-tasks-and-tests.md#unit-tests-test)).
Phase 25 adds the builtin
`Test` module and runs `*_test.agc` files with `agentica test`, next to the
features, through the BDD runner and report. It comes right after task crash
isolation (phase 24), so a crash fails one test; its place in the order is row
7.1 of the [roadmap](README.md). It took two PRs, each with its own tests and docs.

**Done:** the builtin `Test` module (25a: `Test.test/eq/ok?/error?/`
`assert`, `Test.run` with list and run modes, one task per test);
`agentica test` runs `*_test.agc` files through the shared runner and
report (25b); the child protocol runs on its own channel, so a test
owns its stdin and stdout (25c: `Process.spawn_channel`, fd 3,
`AGENTICA_CHANNEL=3`). Record: the grammar's
[`Test` rules](../grammar/06c-tasks-and-tests.md#unit-tests-test),
`docs/bdd.md`, and `docs/vm/10-io-processes.md` §10.4.
    **Review round:** a cut of stdout or stderr wakes a pending
    `channel_read_line` with `process: output exceeds 1048576 bytes` (sticky,
    lines first), so a test or a handler that prints for ever fails at 1 MiB
    with `RUNTIME-BDD-OUTPUT-LIMIT` (`endless_test.agc` and a BDD step, each
    asserted to end long before the deadline); an index line that is not valid
    UTF-8 is the `RUNTIME-BDD-INFRA` fail record too; goldens `test-bad-index`,
    `test-bad-index-bytes` (the exit after a fail record) and
    `process-channel-close` (`Process.close` and a task cancel with a channel
    read and a send pending); a 1 MB test name makes `Test.run` list send a
    record bigger than the socket buffer (the queued write path, in the protocol
    peer).
