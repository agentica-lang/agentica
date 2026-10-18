## Phase 21: BDD in Agentica

Specified in [`docs/bdd.md`](../bdd.md): the user docs, the runner protocol
under "How a run works", and the rejected alternatives under "Decided against".
This is a catch-up item of 7h (order step 7.1): BDD on the VM, written in
Agentica as `std/bdd` and a runner program, after TLS and HTTP 20a and before
HTTP 20b to 20d, then 7i (order decided by the user on 2026-10-13). It needs
only 20a, which is done. Six PRs in order, all done.

**Done (21a–21f):** `Process.spawn_captured`/`output`,
`Task.pending_count`, the Gherkin parser, step matching, the report, and
the switch: `std/bdd` plus a runner program, a child VM per scenario,
`agentica test` on the VM. Record: [`docs/bdd.md`](../bdd.md).
  in the 0.2.0 section of `CHANGELOG.md` and the table "Changes from the Racket
  BDD" in `docs/bdd.md`.

**Done:** `agentica test tests/bdd/specs/ --steps tests/bdd/handlers.agc`
passes with no Racket evaluator involved, a handler that crashes, exits or loops
fails only its scenario, and no file requires `src/bdd.rkt`,
`src/bdd-runner.rkt` or `src/gherkin.rkt`. Then 7i deletes the evaluator.

**Later options (not scheduled):**

- [ ] Run scenarios in parallel (a `--jobs N` flag); they run one at a time
  today.
- [ ] Cache the compiled runner (about 1,500 lines of Agentica, compiled on
  every `agentica test`), if a measurement shows the start-up cost.
- [ ] Once optional JSON fields land (10e), replace the `has_doc` and
  `has_table` stand-ins of the step line (`docs/bdd.md`, "How a run works") with
  optional fields.
