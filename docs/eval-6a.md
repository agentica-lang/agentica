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
| python | 15/15 | 3,506 | $0.001 |
| skill | 15/15 | 13,681 | $0.004 |
| grammar | 15/15 | 15,944 | $0.005 |

All results so far, with per-task tables, are in [`eval-results.md`](eval-results.md).

Agentica runs took about 15–45 s, Python 8–27 s. In `t2-fix-types` the Agentica arms had about 1.0–1.3 failing interpreter runs per run.

## Smoke run (`binary` and `skill`, `t1-stats`, 1 rep, Firejail)

| Arm | Pass | Tokens | Seconds | Interpreter runs |
|---|---|---|---|---|
| skill | 6/6 | 8,128 | 11.4 | 1 |
| binary | 6/6 | 8,739 | 24.3 | 6 |

One run each; not a result, only proof that the arm and the sandbox work.

## `binary` arm, before and after the richer diagnostics

Two full rounds of the `binary` arm (3 reps per task, Firejail, `pi`). Round A used plain one-caret diagnostics. Round B used labels, `help`, and grounded suggestions (phase 5d3, steps 1–4); the prompt did not mention `--ai`, but `agentica --help` lists it, and one run (`t5-scope-return` rep 2) used it. Both passed 15/15. One run of A (`t4-word-count` rep 2) read a leftover planning file from `~/.claude`; that path is hidden since.

| Task | Tokens A → B | Seconds A → B | Failing runs A → B |
|---|---|---|---|
| t1-stats | 81,449 → 53,829 | 292 → 105 | 8.3 → 6.7 |
| t2-fix-types | 37,162 → 10,937 | 152 → 41 | 5.3 → 2.0 |
| t3-struct-change | 3,740 → 4,082 | 14 → 12 | 0.0 → 0.0 |
| t4-word-count | 61,995 → 40,438 | 100 → 98 | 0.7 → 1.7 |
| t5-scope-return | 9,354 → 19,379 | 43 → 34 | 1.7 → 2.3 |
| All (mean per run) | 38,740 → 25,733 | 120 → 58 | 3.2 → 2.5 |

The mean fell by about a third in tokens and by half in time, and `t2-fix-types` (the type error the help text targets) fell by 70%. `t4` and `t5` got worse in failing runs and `t5` in tokens. Three runs per cell and one model are too few to call this a result: the spread between reps of one cell is as large as the differences here. Treat it as a direction, and repeat with more reps before relying on it.

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
