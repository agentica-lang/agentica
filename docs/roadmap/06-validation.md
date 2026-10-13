## Phase 6: Validate the language design

Phase 6a (first evaluation, before 5e) and 6b (second evaluation, after `Result` + `try` and JSON) are described under Phase 5d3 and use the same task set, so the results compare.

- [x] Ask agents to write and repair small programs using only the grammar and examples (evaluation rounds 1–8, `tests/eval/`).
- [x] Record correct programs, repair attempts, and whether diagnostics helped identify the fix (`eval-results.md`, `eval-diagnostics.md`).
- [x] Use the results to revise the grammar and examples explicitly before adding exceptions to the implementation (the acceptance rule in `docs/future/11-ruby-ergonomics.md` §11).

**Complete when:** the prototype provides evidence about whether Agentica's syntax and diagnostics help agents write and repair programs.

### Phase 6c: Agentica against typed Python

Round 1 (`docs/eval-6a.md`) found that Agentica used about 4x the tokens of Python, on tasks too easy to separate the arms by accuracy, against an untyped Python arm. It is not yet shown that agents do better in Agentica than in Python. Repeat the comparison with the current language, harder tasks and a typed Python arm. A pilot comes first, at order step 7.2.2 (decided by the owner on 2026-10-13); the full round is order step 10: after the server measurement (7j), before the decisions of step 11.

- [ ] Pilot (order step 7.2.2): first a regression round on the VM (the `binary` arm, two models, compared with rounds 7–8 in `docs/eval-results.md`); then about 20 tasks with the same agent, model and budget for Agentica and typed Python, measuring functional success, tokens, attempts, compile errors and time to a correct solution. Its results decide the order of the roadmap rows that follow it.
- [ ] Typed Python arm in `tests/eval/run.py`: the agent writes Python with type hints, and a static checker in the eval image checks them; the agent can run it, as it runs `agentica check`. The checker (for example mypy) and its version are chosen in the eval PR and pinned in `tests/eval/Dockerfile`. A solution that fails the checker counts as a failing run.
- [ ] Harder tasks under `tests/eval/tasks/`, each with hidden tests and reference solutions in Agentica and typed Python (both pass the hidden tests and their checker): modify an existing program of a few hundred lines; introduce a type change that crosses a program (a field type, an enum variant, or a Result in place of a plain value, followed through every use); add error handling to a program that halts on bad input; repair a broken integration (for example an HTTP client or server with the wrong JSON shape, or a file pipeline with a wrong path or format). Integration tasks stay hermetic: localhost, port 0, fixtures in the task directory.
- [ ] Run the Agentica skill arm and the typed Python arm with the same model and budget, with enough reps per cell that the spread between reps is smaller than the differences reported (round 1 had too few). Measure hidden tests passed, tokens, repair attempts (failing check or run calls) and time, as in 6a, and separate type errors from logic errors. Runs of the Python checker count as check calls, like `agentica check`: a failing checker run is a repair attempt, and tokens and repairs are compared with the checker calls included on both sides.
- [ ] In the full round, measure the semantic CLI of phase 26 as `docs/future/39-semantic-cli.md` §39.12 says: count its calls, and run one Agentica arm without it on the tasks that cross a program.
- [ ] Record the results in a new section of `docs/eval-results.md`, with the skill commit, the checker version and the model.

**Done when:** the results show, per task kind, whether agents pass more hidden tests or spend fewer tokens and repairs in Agentica than in typed Python, and the findings are listed as follow-up work (language, diagnostics or skill) before order step 11 decides.

