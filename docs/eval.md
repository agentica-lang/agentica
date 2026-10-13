# Agent evaluation

Can an agent write and repair Agentica programs? An agent gets one of eight tasks, and its program is graded against hidden cases. The runs count passing cases, tokens, time, and interpreter runs that failed.

The tasks are in `tests/eval/tasks/`. Each has a `task.md`, a reference solution in Agentica and in Python, and hidden cases. `tests/eval/run.py` runs the agents. `tests/eval/diagnostics.py` counts the diagnostics the agents saw in their logs.

| Task | The agent writes |
|---|---|
| `t1-stats` | count, sum and max of integers from stdin |
| `t2-fix-types` | fix the types in a price calculator |
| `t3-struct-change` | add a field to a struct and update its uses |
| `t4-word-count` | count words, ignoring case, in first-seen order |
| `t5-scope-return` | fix scope and return errors in `classify` |
| `t6-json-catalog` | filter a JSON catalog, validating all of it first |
| `t7-json-stream` | answer JSON-lines requests, and go on after bad ones |
| `t8-enum-ledger` | run a ledger of commands with enums and `case` |

The arms are the context an agent gets:

- `python`: the same task in Python (untyped). The baseline.
- `skill`: the `agentica-programming` skill and the `agentica` binary.
- `grammar`: `docs/grammar.md` and `examples/`, without the skill.
- `binary`: only the binary, `agentica check`, and a one-line hint. No docs.

## How to run

Docker is needed. The runner builds its default image the first time it runs. Pass a provider key by name with `--pass-env`.

```sh
# Check the tasks: the reference solutions must pass every hidden case
python3 tests/eval/run.py --agent reference --arms binary python

# A model run: 3 reps per task and arm
python3 tests/eval/run.py --agent pi --model fireworks/accounts/fireworks/models/deepseek-v4p1-flash --pass-env FIREWORKS_API_KEY --arms skill grammar binary python --reps 3 --jobs 4

# Summarize a finished run, and count the diagnostics the agents saw
python3 tests/eval/run.py --summarize tests/eval/results/<run directory>
python3 tests/eval/diagnostics.py
```

`--tasks` picks tasks (the default is all eight). `--sandbox firejail --chroot-root PATH` is the other sandbox; you prepare its rootfs yourself. The results go to `tests/eval/results/`, which is not versioned. The runner has its own tests: `python3 -m unittest discover -s tests/eval -p test_run.py`.

The Docker sandbox works like this:

- Grading runs each hidden case in a fresh container with `--network=none`, no provider credentials, and the solution mounted read-only.
- Agent containers mount only the task workspace, and they can reach the provider. They run with `--read-only`, `--cap-drop=ALL` and `no-new-privileges`. Credentials come only from `--pass-env`.
- `--no-build` reuses `dist/runtime`, the bundle that a normal run makes with `make exe`, `raco distribute` and a copy of `agentica-vm` into its `bin/`. The runner exits when it is missing.
- `--agent claude` needs `--image` with the Claude CLI and Python. The default image has Pi only.

In round 4 some `binary` runs tried to download the docs from GitHub. The repository was private, so the downloads failed. Close the network for the `binary` arm before the repository goes public.

## Results

Tokens are input plus output per run. A failing interpreter run is an `agentica` call that ended with an error. Rounds 1 to 4 used earlier sandboxes (round 1 had none), so they do not validate the current Docker boundary. Round 5 is the first run in Docker. Compare rows within a table, not across tables.

### Round 1: the arms (2026-10-01)

Five tasks, 3 reps each, DeepSeek V4.1 flash.

| Arm | Passed | Tokens/run | Seconds/run | Failing runs/run |
|---|---|---|---|---|
| `python` | 15/15 | 3,506 | 14 | 0 |
| `skill` | 15/15 | 13,681 | 27 | 0.27 |
| `grammar` | 15/15 | 15,944 | 32 | 0.40 |

- Every run passed, so these tasks do not separate the arms by accuracy.
- Agentica used about 4 times the tokens of Python. The skill used 14% fewer than the grammar and examples.

### Rounds 2 to 4: the `binary` arm and the diagnostics (2026-10-01 and 10-02)

| Round | Change | Passed | Tokens/run | Seconds/run | Failing/run |
|---|---|---|---|---|---|
| 2 | plain one-caret diagnostics | 15/15 | 38,740 | 120 | 3.2 |
| 3 | labels, `help` and suggestions | 15/15 | 25,733 | 58 | 2.5 |
| 4 | round 3, and the prompt names `--help` | 15/15 | 24,574 | 70 | 1.3 |

- Richer diagnostics cut the tokens by about a third and the time by half, with no docs.
- The `--help` sentence made no visible difference. With 3 reps, the spread inside one cell is as large as these gaps, so treat them as a direction.

### Rounds 5 and 6: the Ruby-style language, `binary` arm (2026-10-10)

Round 6 runs after the parser accepted the forms that round 5 showed agents writing (an optional `do`, one-line `case` arms, calls without parentheses) and hinted the rest.

| Round | Tasks | Passed | Tokens/run | Seconds/run | Failing/run |
|---|---|---|---|---|---|
| 5 | t1 to t5 (15 runs) | 15/15 | 24,526 | 89 | 4.2 |
| 5 | t6 to t8 (9 runs) | 9/9 | 76,363 | 261 | 12.7 |
| 6 | t1 to t5 (15 runs) | 14/15 | 31,691 | 99 | 3.1 |
| 6 | t6 to t8 (9 runs) | 9/9 | 78,694 | 253 | 7.9 |

- Failing interpreter runs fell by about a quarter on t1 to t5 and by about 40% on t6 to t8. Tokens did not fall; with 3 reps, the token means move a lot between rounds.
- Agents with no docs write what the diagnostics call Ruby: `while cond do`, `case x`, `IO.gets!`, `var x = ...`, `when`. Round 5 showed these as parse errors, and round 6 stopped failing on the accepted ones.
- One run hit the 10-minute limit: it searched the binary for builtin descriptions instead of writing code.

### Round 7: splitting the skill (2026-10-10)

An A/B of the `skill` arm on all eight tasks, 24 runs each. 7a read one 17k-token `language.md` up front. 7b read a 5k-token core in `SKILL.md`, and the references only when a table said so.

| Round | Passed | Tokens/run | Seconds/run | Failing/run | Cost/run |
|---|---|---|---|---|---|
| 7a, old layout | 24/24 | 28,857 | 31 | 0.13 | $0.008 |
| 7b, split skill | 24/24 | 15,800 | 26 | 0.21 | $0.005 |

The split cut the tokens by 45% and the cost by 39%, with the same accuracy. The agents read only the references their task needed.

### Round 8: a second model, GLM 5.3 flash (2026-10-10)

The `binary` arm on the head of PR #33.

| Tasks | Passed | Tokens/run | Seconds/run | Failing/run |
|---|---|---|---|---|
| t1 to t5 (15 runs) | 15/15 | 11,821 | 33 | 4.8 |
| t6 to t8 (9 runs) | 8/9 | 79,286 | 189 | 22.8 |

- GLM used fewer tokens than DeepSeek on t1 to t5, and it hit more errors.
- Both models wrote the same Ruby and Python forms, so the habits are not one model's quirk. GLM also wrote `puts` with a non-String value and `to_s` on `Bool`. Ruby allows both, and the checker rejected both in those rounds.
- One t6 run failed a hidden case with a logic error.

### JSON tasks: smoke run (2026-10-03)

One rep per cell, DeepSeek V4.1 flash, 4 runs at a time, 600 s limit. The reference solutions passed all 28 hidden-case runs in Docker.

| Task | Arm | Passed | Tokens | Seconds | Failing runs |
|---|---|---|---|---|---|
| t6 | `skill` | 8/8 | 17,565 | 74 | 0 |
| t6 | `grammar` | 8/8 | 22,370 | 82 | 0 |
| t6 | `binary` | 8/8 | 57,458 | 262 | 6 |
| t6 | `python` | 8/8 | 10,075 | 61 | 0 |
| t7 | `skill` | 6/6 | 20,212 | 84 | 0 |
| t7 | `grammar` | 6/6 | 21,633 | 82 | 0 |
| t7 | `binary` | 6/6 | 40,301 | 269 | 8 |
| t7 | `python` | 6/6 | 5,286 | 23 | 0 |

A one-rep smoke run shows that the tasks can be solved and the runner works. It does not measure accuracy. The `binary` runs took about three to four times as long as the `skill` runs and repaired their interpreter errors.

The `t8-enum-ledger` reference solutions passed all 8 hidden cases in Docker on 2026-10-04. Its model results are in the t6 to t8 rows above.

## Diagnostics

Hits of the top codes in the `binary` arm, from `tests/eval/diagnostics.py`, in the 2026-10 rounds. A dash means the code was not in that round's top list.

| Code | Round 5 | Round 6 | Round 8 (GLM) |
|---|---|---|---|
| `PARSE-UNEXPECTED-TOKEN` | 98 | 47 | 49 |
| `CHECK-UNKNOWN-NAME` | 23 | 22 | 49 |
| `CHECK-TYPE-MISMATCH` | 14 | 16 | 72 |
| `CHECK-MISSING-RETURN` | 11 | 9 | 11 |
| `CHECK-UNKNOWN-METHOD` | – | – | 42 |

- In those rounds most hits were Python and Ruby habits, not logic errors: `len(s)`, `s.length`, `x.to_i`, `print(x)`, `!a`, `x += 1`. The checker rejected them then, so check the grammar for what the language accepts now.
- In round 1, failing runs were fixed after the agent read the code and the span, so the diagnostics worked as a repair signal.

## What the results do not show

- Accuracy on harder tasks. These tasks do not need sorting or building a list, and most of them pass.
- Other models than DeepSeek and GLM. A Sonnet round is postponed, because isolating `claude -p` from the global configuration is not solved.
- Whether `--ai` or `--json` help. They were not measured.
- Whether the Agentica arms beat a typed Python. The Python arm here is untyped. The full comparison is [roadmap phase 6c](roadmap/06-validation.md#phase-6c-agentica-against-typed-python).
