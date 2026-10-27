## Phase 21: BDD in Agentica

Specified in [`docs/bdd.md`](../bdd.md): the user docs, the runner protocol
under "How a run works", and the rejected alternatives under "Decided against".
A catch-up item of 7h (order step 7.1).

**Done (21a–21f):** `Process.spawn_captured`/`output`, `Task.pending_count`, the
Gherkin parser, step matching, the report, and the switch: `std/bdd` plus a
runner program, a child VM per scenario, `agentica test` on the VM. A handler
that crashes, exits or loops fails only its scenario. Record:
[`docs/bdd.md`](../bdd.md).

**Later options (not scheduled):**

- [ ] Run scenarios in parallel (a `--jobs N` flag); they run one at a time
  today.
- [ ] Cache the compiled runner (about 1,500 lines of Agentica, compiled on
  every `agentica test`), if a measurement shows the start-up cost.
- [ ] Replace the `has_doc` and `has_table` stand-ins of the step line
  (`stdlib/bdd.agc`) with `JsonField` fields (10e).
