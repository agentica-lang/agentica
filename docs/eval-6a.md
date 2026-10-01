# Phase 6a: first agent evaluation

Question: can an agent write and repair Agentica programs with the language as it is? Run with `python3 tests/eval/run.py` (see `tests/eval/`).

## Setup

- Agent: `pi` with Fireworks DeepSeek V4.1 flash, one session per run, 10 minute limit, no external retry loop.
- Tasks (`tests/eval/tasks/`): `t1-stats`, `t2-fix-types`, `t3-struct-change`, `t4-word-count`, `t5-scope-return`. Whole programs over stdin/stdout, 6 hidden cases each. Reference solutions in Agentica and Python prove each task is solvable.
- Arms:
  - `skill`: the `agentica-programming` skill and the `agentica` binary.
  - `grammar`: `docs/grammar.md` and `examples/`, no skill.
  - `binary`: only the binary, `agentica check`, and a one-line hint.
  - `python`: the same task in Python.
- Each run gets a fresh temp directory with no hidden tests. Later rounds run inside Firejail with the repo hidden (network open); round 1 did not, but a log check found no reads of the repo and no gmem or MCP calls.

## Round 1 (3 reps per task and arm, 45 runs; arms `skill`, `grammar`, `python`)

| Arm | Pass | Mean tokens (in+out) per run | Mean cost per run |
|---|---|---|---|
| python | 15/15 | 3,506 | $0.016 |
| skill | 15/15 | 13,681 | $0.060 |
| grammar | 15/15 | 15,944 | $0.069 |

Agentica runs took about 15–45 s, Python 8–27 s. In `t2-fix-types` the Agentica arms had about 1.0–1.3 failing interpreter runs per run.

## Smoke run (`binary` and `skill`, `t1-stats`, 1 rep, Firejail)

| Arm | Pass | Tokens | Seconds | Interpreter runs |
|---|---|---|---|---|
| skill | 6/6 | 8,128 | 11.4 | 1 |
| binary | 6/6 | 8,739 | 24.3 | 6 |

One run each; not a result, only proof that the arm and the sandbox work.

## Findings

- The tasks are too easy to separate the arms by accuracy: everything passed. Only token cost differs. The skill used about 14% fewer tokens than grammar plus examples, with the same quality.
- Agentica costs about 4x the tokens of Python on the same task.
- A program cannot build or sort a list: there is no append, concat, or sort, and no function values. `t4-word-count` was written around maps for that reason. Harder tasks (sort, map, reduce) need phase 5n, which depends on 5j.
- Diagnostics worked as a repair signal: failing runs were fixed after reading the code and span. Compact `--ai` output (5d3) is not yet measured.

## Limits

- Python is a strong baseline: a typed language the model knows well, and the injected bugs are not identical across languages.
- One model. The Sonnet 5.5 round is postponed (isolating `claude -p` from the global config is unsolved).
- Python arm is untyped; a Python + mypy or Ruby arm could be added.

## Next

- Full `binary` round (3 reps) to see how much the skill and grammar add over diagnostics alone.
- Harder tasks after phase 5n; repeat as 6b after 5e and 5f.
- `check --ai` and `--json` (5d3), then compare against plain text.
