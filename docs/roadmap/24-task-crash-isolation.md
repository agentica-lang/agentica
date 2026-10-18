## Phase 24: Task crash isolation

The semantics are in the grammar's task section
([`06c-tasks-and-tests.md`][task-rules]).
This file is the implementation record. Phase 24 is VM work with a small
language change: a runtime error in a task other than
`main` ends only that task. Its place in the order is row 7.1 of the
[roadmap](README.md). It took one PR, with its own tests and docs.

**Done:** a runtime error in a task other than `main` ends only that
task (24a); one handle-ownership rule — a handle belongs to the task
that opened it and moves only explicitly via `Task.spawn_owning` (24b);
channels can be owned the same way (24c). Record: the grammar's
[task section][task-rules],
[§14.5](../vm/14-core-invariants.md#145-handles), and
`docs/vm/10-io-scheduler.md` §10.2.1.

[task-rules]: ../grammar/06c-tasks-and-tests.md#lightweight-tasks
