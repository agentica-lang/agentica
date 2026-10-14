# Agent evaluation

Can an agent write and repair Agentica programs? An agent gets one task, and its program is graded against hidden cases. The runs count passing cases, tokens, time, and interpreter and checker runs that failed.

The tasks are in `tests/eval/tasks/`. Each has a `task.md`, a reference solution in Agentica (`reference.agc`) and in typed Python (`reference.py`), and hidden cases. The tasks that start from a program have `start.agc` and `start.py` (and `start.typed.py` when the typed arm needs a different start). `tests/eval/run.py` runs the agents. `tests/eval/diagnostics.py` counts the diagnostics the agents saw in their logs.

The first eight tasks are small programs on stdin and stdout.

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

The twelve tasks t9 to t20 are the harder kinds of [roadmap phase 6c](roadmap/06-validation.md#phase-6c-agentica-against-typed-python), for the pilot. The start programs of t9, t10 and t12 are 170 to 210 lines in both languages (`wc -l` of `start.agc` and `start.py`); the others are 30 to 110 lines.

| Task | Kind | The agent does |
|---|---|---|
| `t9-inventory-orders` | modify a program | add bulk discounts, a `remove` command and a `low` mark to a shop program with six commands |
| `t10-calc-extend` | modify a program | add `%`, `^` (right-associative) and a unary minus to a calculator with variables, with the right precedence |
| `t11-gradebook` | modify a program | add subject weights, ranking with ties and letter grades to a gradebook; the data model has to change |
| `t12-member-ids` | type change | change member and book ids from `Int` to `String` (`M-007`, `B-12`) through structs, maps, sorting, parsing and messages |
| `t13-transfer-variant` | type change | add an enum variant (`Transfer`) that every `case` handles (in Python, every `match` ends in `assert_never`) and a new field in the stats |
| `t14-price-lookup` | type change | `find_price` stops returning `-1` and returns `Result[Int]` (`int \| None` in Python); follow it through four callers and count the unknown lookups |
| `t15-robust-ledger` | error handling | a ledger program that halts on a bad line reports `line N: problem`, skips the line and goes on |
| `t16-robust-csv` | error handling | the same for a CSV salary summary, with five checks in a fixed order |
| `t17-quote-client` | repair an integration | an HTTP client with the wrong path, JSON shape, header and no error handling, against a Python server |
| `t18-stats-server` | repair an integration | an HTTP server (`std/http`, `http.server`) with wrong JSON, content type, status codes and port line, driven by a Python client |
| `t19-orders-report` | repair an integration | a CSV to JSON file pipeline with the wrong delimiter, header, output path and format |
| `t20-big-log` | big data | print the slow server errors of a log of up to 29 MB and 600,000 lines; in Agentica a whole-file read stops at 1 MiB, so the program has to stream (`File.each_line` or `File.read_line`) |

The arms are the context an agent gets:

- `python`: the same task in Python (untyped). The baseline of the first rounds.
- `typed-python`: the same task in Python with type annotations, checked by `mypy --strict` (see "The typed Python arm").
- `skill`: the `agentica-programming` skill and the `agentica` binary.
- `grammar`: `docs/grammar.md` and `examples/`, without the skill.
  The grammar arm's text changed in this PR (the `agentica help` pointer in its prompt, and no dead file links), so older grammar-arm results are not comparable. `agentica help` covers the builtins only, so this arm has no signature source for the `std/` modules (`HTTP`, `Queue`, `BDD`).
- `binary`: only the binary, `agentica check`, and a one-line hint. No docs.

## How to run

Docker is needed. The runner builds its default image the first time it runs. Pass a provider key by name with `--pass-env`.

```sh
# Check the tasks: every reference solution must pass every hidden case (no model, no credentials)
python3 tests/eval/run.py --check-references

# A model run: 3 reps per task and arm
python3 tests/eval/run.py --agent pi --model fireworks/accounts/fireworks/models/deepseek-v4p1-flash --pass-env FIREWORKS_API_KEY --arms skill typed-python --reps 3 --jobs 4

# Summarize a finished run, and count the diagnostics the agents saw
python3 tests/eval/run.py --summarize tests/eval/results/<run directory>
python3 tests/eval/diagnostics.py
```

`--tasks` picks tasks (the default is all twenty). `--arms` picks arms (the default is all five). `--sandbox firejail --chroot-root PATH` is the other sandbox; you prepare its rootfs yourself, and it needs `mypy` for the typed arm. The results go to `tests/eval/results/`, which is not versioned. Each run directory has a `run.json` with the commit, the commit of the last change to the skill, the checker version, the model, the arms and the image, next to `results.jsonl` and `summary.md`. The runner has its own tests: `python3 -m unittest discover -s tests/eval -p 'test_*.py'`.

`--check-references` is the same as `--agent reference` with the arms `binary`, `python` and `typed-python` (the three Agentica arms share one reference). It copies each `reference.*` as the solution, grades it like an agent's, prints the table, and exits 1 when a reference fails. Use it after any change to a task, the runner, the image or the VM. For the Agentica references it needs `dist/runtime` (the runner builds it unless you pass `--no-build`) and `dist/agentica-vm`.

The Docker sandbox works like this:

- Grading runs each hidden case in a fresh container with `--network=none`, no provider credentials, and the solution mounted read-only. The container has a loopback interface, so a grader can run a server next to the solution (see "Hidden cases").
- Agent containers mount only the task workspace, and they can reach the provider. They run with `--read-only`, `--cap-drop=ALL` and `no-new-privileges`. Credentials come only from `--pass-env`.
- `TMPDIR` is `/tmp` in every container, because the root file system is read-only and the launcher writes its bytecode to the temporary directory. The image has `libgc1` and `libssl3t64`, which `dist/agentica-vm` links (the default Linux build uses the system libraries).
- `--no-build` reuses `dist/runtime`, the bundle that a normal run makes with `make exe`, `raco distribute` and a copy of `agentica-vm` into its `bin/`. The runner exits when it is missing.
- `--agent claude` needs `--image` with the Claude CLI and Python. The default image has Pi only.

If you change `tests/eval/Dockerfile`, remove the old image (`docker rmi agentica-eval:local`) or run the typed arm: the runner rebuilds the default image when it has no `mypy`.

### The typed Python arm

The `typed-python` arm is the Python side of the comparison of phase 6c. The agent writes `solution.py` with type annotations and gets `mypy` on its `PATH`, like the Agentica arms get `agentica check`. The prompt gives the command, `mypy --strict solution.py`, and says not to silence it with `# type: ignore` or by weakening its options.

- Checker: mypy 2.3.1 (compiled), run with `--strict`. The version and its five dependencies are pinned in `tests/eval/Dockerfile`; `run.json` records the version the image reports. mypy is the checker the roadmap names. It installs from PyPI as compiled wheels, with no download at run time; the `pyright` package on PyPI fetches its npm package on first use, which the grader (no network) cannot do.
- Grading: the grader first runs `mypy --strict --cache-dir=/dev/null solution.py` in a fresh container, in the same mount and with the same limits as the hidden cases. A solution that fails the checker is a failing run with 0 cases passed, like an Agentica program that fails `agentica check` and never runs. The row has `failure: check` and the first mypy error code (`arg-type`, `assignment`, `return`...) as `code`, or `syntax` for a parse error, and `check_errors`, the number of errors. A passing solution then runs against the hidden cases like any other.
- The row also has `type_ignores`, the number of `# type: ignore` comments in the solution. They do not fail a run; check the count before you compare the arms.
- Measures: `interpreter_runs` counts every bash call that runs `agentica`, `python` or `mypy`; `check_runs` counts the calls to `mypy` and `agentica check`; `check_failures` counts those that failed (a mypy `error:` line, an `error[...]` diagnostic); `failing_runs` counts every failing call, checks included, so repairs are compared with the checker calls on both sides. Tokens, turns, cost and seconds are the same as in the Agentica arms. `diagnostics.py` still counts Agentica diagnostics only.
- Starts: `start.py` of t9 to t19 is typed and passes `mypy --strict`. For t2, t3 and t5 (written for the untyped arm) `start.typed.py` is the same program with annotations, and the typed arm gets it as `start.py`; for t2 and t5 it fails the checker for the same reasons the Agentica start fails `agentica check`.
- The untyped `python` arm stays for comparison with the early rounds. It is not part of the pilot of phase 6c. Its workspace no longer gets the Agentica binaries.

### Hidden cases

A case is `hidden/NN.in` (standard input) and `hidden/NN.out` (the expected standard output, compared after trimming the final newlines); the run passes the case when the output is equal and the exit code is 0. A task directory may add two optional files, which the integration and big-data tasks use:

- `hidden/driver.py` makes a case a small scenario. The runner starts `python3 -I -c <driver source> <solution command>` in the grader container with `NN.in` on its standard input, and compares what the driver prints. The driver is Python standard library only and the independent peer: it runs the solution with an absolute path (`/workspace/bin/agentica /workspace/solution.agc`, or `python3 -I /workspace/solution.py`), serves or calls it on `127.0.0.1` port 0, creates its fixtures in a temporary directory, and prints a transcript. The hidden material is passed in the command line and never mounted, so the solution does not find it as a file. A solution that reads `/proc` can find the driver; the harness does not defend against that. The drivers: t17 is an HTTP server (`http.server`) that checks the request and prints the requests it got; t18 starts the solution as a server, reads its `listening PORT` line and calls it with `http.client`; t19 writes the CSV, runs the program with relative paths and prints the file it wrote; t20 generates a log and checks the answer itself.
- `hidden/timeout` is the time limit of one case in seconds (the default is 10). t20 has 60.

t20 generates its logs (a fixed pseudo-random sequence, 50,000 and 600,000 lines, with invalid, blank, CRLF and 3,000-character lines), so the repository holds no big file. The harness does not limit the memory of the solution. The Racket launcher alone uses about 140 MB, so a limit that a streaming Agentica program passes and a whole-file Python program fails would need a file much bigger than the 128 MB `/tmp` of the container. The task statement says the file is big and gives no memory limit. The measure is whether the agent streams: in Agentica a whole-file read of more than 1 MiB fails, and in Python it is allowed and passes.

### Before a round

- Network access for the agents. Agent containers can reach the provider, so they can reach the whole internet, and the programming skill links `https://sonic182.github.io/agentica/llms.txt`, so an agent with a shell can read the public site. Decide before a round whether that is allowed, and record it with the results: `run.json` has `agent_network: true`, and `net_commands` counts the commands that mention `curl`, `wget`, `git clone` or `github.com`. The runner has no allow-list for the provider host, so closing the network for the agents needs a proxy or firewall that you provide.
- Rebuild the image if the Dockerfile changed, and run `--check-references`.
- Do not merge anything or change the skill while a round runs.

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
- In rounds 2 to 4, failing runs were fixed after the agent read the code and the span, so the diagnostics worked as a repair signal.

## What the results do not show

- Accuracy on harder tasks. These tasks do not need sorting or building a list, and most of them pass.
- Other models than DeepSeek and GLM. A Sonnet round is postponed, because isolating `claude -p` from the global configuration is not solved.
- Whether `--ai` or `--json` help. They were not measured.
- Whether the Agentica arms beat a typed Python. The Python arm of the rounds above is untyped. The typed arm and the twelve harder tasks are ready (see "How to run"), but the pilot has not run, so there are no results yet. The full comparison is [roadmap phase 6c](roadmap/06-validation.md#phase-6c-agentica-against-typed-python).
