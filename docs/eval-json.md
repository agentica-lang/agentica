# JSON evaluation tasks

The JSON tasks exercise the phase 5f API with the same `skill`, `grammar`, `binary`, and `python` arms as the earlier evaluation. Reference programs use only core language features; there is no typed JSON decoder or list builder dependency.

| Task | Behavior | Hidden cases |
|---|---|---|
| `t6-json-catalog` | Validate an entire catalog before emitting selected products as JSON lines | 8 |
| `t7-json-stream` | Handle sum/count requests independently, preserving responses after bad records | 6 |

Catalog cases cover threshold inclusion, empty arrays, repeated names, Unicode and escaping, wrong types, missing fields, negative bounds, and trailing input. Stream cases cover heterogeneous arrays (including false/null), empty sums, malformed and blank lines, Bool/Float rejection for Int, unknown operations, missing fields, duplicate keys, and integer overflow during extraction.

Output objects have a fixed field order and compact encoding because the runner compares stdout text. Parsed JSON object order is not used as an output contract. The existing batch grader checks final stdout and error recovery; it does not measure whether responses arrive before stdin closes. The stream task also asks for explicit flushing.

## Initial validation, 2026-10-03

Both Agentica and Python reference solutions passed every hidden case: 28/28 executions across the two languages. These were local functional checks using the rebuilt Agentica executable, without an agent session or the Firejail grader. They establish the expected outputs and task solvability; they are not model accuracy results.

The three new examples (`json-config.agc`, `json-expenses.agc`, and `json-lines.agc`) also run successfully. `tests/examples-test.rkt` checks valid input, application validation errors, wrong JSON kinds, and recovery after malformed stream records. All 87 project tests pass. A separate live-pipe check held stdin open and verified flushed replies after valid and invalid records for `json-lines.agc` and both stream reference implementations.

Docker is now the default sandbox, so the evaluation does not require Firejail or a manually prepared rootfs. Firejail remains optional for users who configure it themselves. Provider variables are passed explicitly, as described in [eval-6a.md](eval-6a.md).

The same reference solutions also passed 28/28 hidden-case executions in Docker. The runner's nine Python tests pass, including actual container checks for workspace access, environment filtering, grading without networking, and read-only solution mounts. Run them with `python3 -m unittest discover -s tests/eval -p test_run.py`; the Docker checks skip when Docker or the evaluation image is unavailable.

## Model smoke comparison, 2026-10-03

Pi 1.0.0 with `fireworks/accounts/fireworks/models/deepseek-v4p1-flash`, Docker image `agentica-eval:local`, one repetition per task and arm, four concurrent runs, and a 600-second agent limit. The image uses Node 22 and Python 3.13; Agentica was bundled from Racket CS 9.3. Raw logs remain unversioned under `tests/eval/results/20261003-095402-pi`.

| Task | Arm | Hidden cases passed | Tokens (in + out) | Agent seconds | Failing interpreter runs |
|---|---|---|---|---|---|
| catalog | skill | 8/8 | 17,565 | 73.8 | 0 |
| catalog | grammar | 8/8 | 22,370 | 82.3 | 0 |
| catalog | binary | 8/8 | 57,458 | 262.4 | 6 |
| catalog | python | 8/8 | 10,075 | 60.5 | 0 |
| stream | skill | 6/6 | 20,212 | 83.5 | 0 |
| stream | grammar | 6/6 | 21,633 | 82.3 | 0 |
| stream | binary | 6/6 | 40,301 | 269.1 | 8 |
| stream | python | 6/6 | 5,286 | 22.6 | 0 |

All eight solutions passed, totaling 56/56 hidden cases, with no agent timeouts. Total reported provider cost was $0.0744. The binary-only runs needed more time and repaired interpreter errors; the documented arms did not record failed interpreter invocations. Tokens exclude cached input. This is one repetition per cell with one model, sufficient to check the evaluation path and task solvability, but too small to estimate accuracy or a stable performance difference. The batch grader does not validate response flushing for generated solutions.

## Run

First check both reference languages inside Docker:

```sh
python3 tests/eval/run.py --agent reference --tasks t6-json-catalog t7-json-stream --arms binary python
```

Then run the model comparison, explicitly selecting an installed provider/model because the agent home is fresh:

```sh
python3 tests/eval/run.py --agent pi --model fireworks/accounts/fireworks/models/deepseek-v4p1-flash --pass-env FIREWORKS_API_KEY --tasks t6-json-catalog t7-json-stream --arms skill grammar binary python --reps 3 --jobs 4
```

Use the environment variable for the selected provider. This command schedules 24 independent agent runs. `--reps 1` gives an eight-run smoke comparison. Do not combine these new-task measurements with the historical five-task accuracy figures.
