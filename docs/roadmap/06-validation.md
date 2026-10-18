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
  `docs/eval.md`). Its two prerequisites, the next two items, were done first:
  the typed Python arm and the pilot's tasks (20 in all: t1–t8 with typed Python
  reference solutions, plus t9–t20 of the harder kinds below). It ran:
  - a regression round of the `binary` arm on the VM, with the models and tasks
    of rounds 6 (DeepSeek) and 8 (GLM 5.3 flash), t1–t8, 3 reps per task,
    compared with those rounds;
  - the pilot: the Agentica `skill` arm against the typed Python arm on the ~20
    tasks, the same agent and budget, both models (and gpt-oss-120b, added by
    the owner; Nemotron Lightning 3.5 was dropped part way), 3 reps per cell;
    measure functional success (hidden tests), tokens, attempts, compile and
    check errors, and time to a correct solution;
  - record both in `docs/eval.md`. The results decide the order of the roadmap
    rows after 7.2.2; the owner's order of 2026-10-14 is in
    [`README.md`](README.md). The pilot does not tick the run and record items
    below: the full round does, with enough reps.
- [x] Typed Python arm in `tests/eval/run.py`: the agent writes Python with type
  hints, and a static checker in the eval image checks them; the agent can run
  it, as it runs `agentica check`. The checker (for example mypy) and its
  version are chosen in the eval PR and pinned in `tests/eval/Dockerfile`. A
  solution that fails the checker counts as a failing run. Done: the
  `typed-python` arm with `mypy --strict` 2.3.1, pinned in the Dockerfile
  (`docs/eval.md`, "The typed Python arm").
- [x] Harder tasks under `tests/eval/tasks/`, each with hidden tests and
  reference solutions in Agentica and typed Python (both pass the hidden tests
  and their checker): modify an existing program of a few hundred lines;
  introduce a type change that crosses a program (a field type, an enum variant,
  or a Result in place of a plain value, followed through every use); add error
  handling to a program that halts on bad input; repair a broken integration
  (for example an HTTP client or server with the wrong JSON shape, or a file
  pipeline with a wrong path or format). Integration tasks stay hermetic:
  localhost, port 0, fixtures in the task directory. Done: t9 to t20 (12 tasks)
  with typed Python references that pass `mypy --strict`;
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

