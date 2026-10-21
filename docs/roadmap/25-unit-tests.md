## Phase 25: Unit tests

It comes right after task crash isolation (phase 24), so a crash fails one
test; its place in the order is row 7.2.1 of the [roadmap](README.md).

**Done:** the builtin `Test` module (25a: `Test.test/eq/ok?/error?/`
`assert`, `Test.run` with list and run modes, one task per test);
`agentica test` runs `*_test.agc` files through the shared runner and
report (25b); the child protocol runs on its own channel, so a test
owns its stdin and stdout (25c: `Process.spawn_channel`, fd 3,
`AGENTICA_CHANNEL=3`). Record: the grammar's
[`Test` rules](../grammar/06c-tasks-and-tests.md#unit-tests-test),
`docs/bdd.md`, and `docs/vm/10-io-processes.md` §10.4.
