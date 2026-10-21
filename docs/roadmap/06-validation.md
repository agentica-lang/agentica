## Phase 6: Validate the language design

**Done (phases 6a/6b):** agent rounds 1–8 with the task set under
`tests/eval/`, recorded in `docs/eval.md`, revising the grammar before
adding implementation exceptions (the acceptance rule,
[§25](../future/25-ruby-typed-idioms.md#25-ruby-typed-idioms)). Details
under Phase 5d3 and 6a in [`01-foundations.md`](01-foundations.md).

### Phase 6c: Agentica against typed Python

Round 1 (`docs/eval.md`) found that Agentica used about 4x the tokens of Python,
on tasks too easy to separate the arms by accuracy, against an untyped Python
arm. It is not yet shown that agents do better in Agentica than in Python.
Repeat the comparison with the current language, harder tasks and a typed Python
arm. A pilot comes first, at order step 7.2.2 (decided by the owner on
2026-10-13); the full round is order step 10: after the server measurement (7j)
and the JIT (9.1), and order step 11 (multicore) does not wait for it.

- [x] Pilot (order step 7.2.2), done on 2026-10-14 (rounds 9 to 11 of
  `docs/eval.md`): a regression round of the `binary` arm on the VM, and the
  Agentica `skill` arm against the typed Python arm on 20 tasks (t1–t8 and the
  harder t9–t20 below), the same agent and budget, 3 reps per cell. The results
  decide the order of the roadmap rows after 7.2.2 (the owner's order of
  2026-10-14 is in [`README.md`](README.md)). The pilot does not tick the run
  and record items below: the full round does, with enough reps.
- [x] Typed Python arm in `tests/eval/run.py`: the agent writes Python with type
  hints and checks them with `mypy --strict` (pinned in `tests/eval/Dockerfile`;
  `docs/eval.md`, "The typed Python arm"). A solution that fails the checker
  counts as a failing run.
- [x] Harder tasks t9 to t20 under `tests/eval/tasks/`, each with hidden tests
  and reference solutions in Agentica and typed Python (both pass the hidden
  tests and their checker): modify an existing program of a few hundred lines;
  introduce a type change that crosses a program (a field type, an enum variant,
  or a Result in place of a plain value, followed through every use); add error
  handling to a program that halts on bad input; repair a broken integration
  (for example an HTTP client or server with the wrong JSON shape, or a file
  pipeline with a wrong path or format). Integration tasks stay hermetic:
  localhost, port 0, fixtures in the task directory.
  `python3 tests/eval/run.py --check-references` grades every reference in
  Docker (`docs/eval.md`).
- [ ] Run the Agentica skill arm and the typed Python arm with the same model
  and budget, with enough reps per cell that the spread between reps is smaller
  than the differences reported (round 1 had too few). Measure hidden tests
  passed, tokens, repair attempts (failing check or run calls) and time, as in
  6a, and separate type errors from logic errors. Runs of the Python checker
  count as check calls, like `agentica check`: a failing checker run is a repair
  attempt, and tokens and repairs are compared with the checker calls included
  on both sides.
- [ ] In the full round, measure the semantic CLI of phase 26 as
  `docs/future/39-semantic-cli.md` §39.12 says: count its calls, and run one
  Agentica arm without it on the tasks that cross a program.
- [ ] Record the results in a new section of `docs/eval.md`, with the skill
  commit, the checker version and the model.

**Done when:** the results show, per task kind, whether agents pass more hidden
tests or spend fewer tokens and repairs in Agentica than in typed Python, and
the findings are listed as follow-up work (language, diagnostics or skill).
Order step 11 (multicore) does not wait for them.
