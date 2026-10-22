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
2026-10-13); the full round has no fixed order (owner, 2026-10-21), and order
step 11 (multicore) does not wait for it.

- [x] Pilot (order step 7.2.2, rounds 9 to 11 of `docs/eval.md`), the typed
  Python arm (`mypy --strict`, "The typed Python arm" of `docs/eval.md`; a
  solution that fails the checker counts as a failing run), and the harder tasks
  t9 to t20 (modify a program, a type change across a program, error handling,
  a broken integration; hermetic), each with hidden tests and reference
  solutions in both languages (`--check-references`).
- [ ] Run the Agentica skill arm and the typed Python arm with the same model
  and budget, with enough reps per cell that the spread between reps is smaller
  than the differences reported (round 1 had too few). Measure hidden tests
  passed, tokens, repair attempts (failing check or run calls) and time, as in
  6a, and separate type errors from logic errors. Runs of the Python checker
  count as check calls, like `agentica check`: a failing checker run is a repair
  attempt, and tokens and repairs are compared with the checker calls included
  on both sides. Round 13 ran it with 3 reps (DeepSeek 13 of 20 tasks, stopped
  for budget; GLM all 20), so it stays open: the pass-rate gap is within the
  noise of 3 reps for DeepSeek.
- [ ] In the full round, measure the semantic CLI (row 7.2b) as
  `docs/future/39-semantic-cli.md` §39.12 says: count its calls, and run one
  Agentica arm without it on the tasks that cross a program. Round 13 ran both
  but is inconclusive: `query_runs` was 0 in all 225 runs, so `skill` and
  `skill-nocli` did not differ; repeat after the skill presents the commands
  differently.
- [x] Record the results in `docs/eval.md` (round 13, 2026-10-22).

**Done when:** the results show, per task kind, whether agents pass more hidden
tests or spend fewer tokens and repairs in Agentica than in typed Python, and
the findings are listed as follow-up work (language, diagnostics or skill).
Order step 11 (multicore) does not wait for them.
