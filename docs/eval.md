# Agent evaluation

Can an agent write and repair Agentica programs? An agent gets one task, and its
program is graded against hidden cases. The runs count passing cases, tokens,
time, and interpreter and checker runs that failed.

The tasks are in `tests/eval/tasks/`. Each has a `task.md`, a reference solution
in Agentica (`reference.agc`) and in typed Python (`reference.py`), and hidden
cases. The tasks that start from a program have `start.agc` and `start.py` (and
`start.typed.py` when the typed arm needs a different start).
`tests/eval/run.py` runs the agents. `tests/eval/diagnostics.py` counts the
diagnostics the agents saw in their logs.

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

The twelve tasks t9 to t20 are the harder kinds of [roadmap phase
6c](roadmap/06-validation.md#phase-6c-agentica-against-typed-python), for the
pilot. The start programs of t9, t10 and t12 are 170 to 210 lines in both
languages (`wc -l` of `start.agc` and `start.py`); the others are 28 to 132
lines.

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
| `t20-big-log` | big data (a streaming probe) | print the slow server errors of a log of up to 29 MB and 600,000 lines, reading it line by line; in Agentica a whole-file read stops at 1 MiB, so the program has to stream (`File.each_line` or `File.read_line`) |

The arms are the context an agent gets:

- `python`: the same task in Python (untyped). The baseline of the first rounds.
- `typed-python`: the same task in Python with type annotations, checked by
  `mypy --strict` (see "The typed Python arm").
- `skill`: the `agentica-programming` skill and the `agentica` binary.
- `grammar`: `docs/grammar.md` and `examples/`, without the skill. The grammar
  arm's text changed in this PR (the `agentica help` pointer in its prompt, and
  no dead file links), so older grammar-arm results are not comparable.
  `agentica help` covers the builtins only, so this arm has no signature source
  for the `std/` modules (`HTTP`, `Queue`, `BDD`).
- `binary`: only the binary, `agentica check`, and a one-line hint. No docs.

The prompts are not equal, and they stay as they are so that rounds remain
comparable. The `binary` prompt names `agentica check` and `agentica --help`;
the `skill` prompt names only the skill, which teaches `agentica check`; the
`grammar` prompt names `agentica help NAME`; the `typed-python` prompt names
`mypy --strict solution.py`; the `python` prompt names no checker. Read a
difference between arms with that in mind.

## How to run

Docker is needed. The runner builds its default image the first time it runs.
Pass a provider key by name with `--pass-env`.

```sh
# Check the tasks: every reference solution must pass every hidden case (no model, no credentials)
python3 tests/eval/run.py --check-references

# A model run: 3 reps per task and arm
python3 tests/eval/run.py --agent pi --model fireworks/accounts/fireworks/models/deepseek-v4p1-flash --pass-env FIREWORKS_API_KEY --arms skill typed-python --reps 3 --jobs 4

# Summarize a finished run, and count the diagnostics the agents saw
python3 tests/eval/run.py --summarize tests/eval/results/<run directory>
python3 tests/eval/diagnostics.py
```

`--tasks` picks tasks (the default is all twenty). `--arms` picks arms (the
default is all five). `--sandbox firejail --chroot-root PATH` is the other
sandbox; you prepare its rootfs yourself, and it needs `mypy` for the typed arm.
Docker is the only sandbox tested with the typed arm, the drivers and the
loopback peers; Firejail is untested for them. The results go to
`tests/eval/results/`, which is not versioned. Each run directory has a
`run.json` with the commit, the commit of the last change to the skill, the
checker version, the model, the arms, and the image name and ID, next to
`results.jsonl` and `summary.md`. The runner has its own tests:
`python3 -m unittest discover -s tests/eval -p 'test_*.py'`.

`--check-references` is the same as `--agent reference` with the arms `binary`,
`python` and `typed-python` (the three Agentica arms share one reference). It
copies each `reference.*` as the solution, grades it like an agent's, prints the
table, and exits 1 when a reference fails. `make eval-references` runs it with
`--jobs 8`; it is not part of CI. Use it after any change to a task, the runner,
the image or the VM. For the Agentica references it needs `dist/runtime` (the
runner builds it unless you pass `--no-build`) and `dist/agentica-vm`.

The Docker sandbox works like this:

- Grading runs each hidden case in a fresh container with `--network=none`, no
  provider credentials, and the solution mounted read-only. The container has a
  loopback interface, so a grader can run a server next to the solution (see
  "Hidden cases").
- Agent containers mount only the task workspace, and they can reach the
  provider. They run with `--read-only`, `--cap-drop=ALL` and
  `no-new-privileges`. Credentials come only from `--pass-env`.
- `TMPDIR` is `/tmp` in every container, because the root file system is
  read-only and the launcher writes its bytecode to the temporary directory. The
  image has `libgc1` and `libssl3t64`, which `dist/agentica-vm` links (the
  default Linux build uses the system libraries).
- `--no-build` reuses `dist/runtime`, the bundle that a normal run makes with
  `make exe`, `raco distribute` and a copy of `agentica-vm` into its `bin/`. The
  runner exits when it is missing.
- `--agent claude` needs `--image` with the Claude CLI and Python. The default
  image has Pi only.

If you change `tests/eval/Dockerfile`, remove the old image
(`docker rmi agentica-eval:local`). The runner also rebuilds the default image
by itself, and prints a line saying so, in two cases: `mypy --version` exits 126
or 127 in it (typed arm), or it cannot run a hello program with
`dist/runtime/bin/agentica` (any Agentica arm; an image from before `libgc1` and
`libssl3t64` were added fails this way). Any other failure of the probes stops
the run with a message, and an image given with `--image` is never rebuilt: the
runner stops and asks you to rebuild it.

### The typed Python arm

The `typed-python` arm is the Python side of the comparison of phase 6c. The
agent writes `solution.py` with type annotations and gets `mypy` on its `PATH`,
like the Agentica arms get `agentica check`. The prompt gives the command,
`mypy --strict solution.py`, and says not to silence it with `# type: ignore` or
by weakening its options.

- Checker: mypy 2.3.1 (compiled), run with `--strict`. The version and its five
  dependencies are pinned in `tests/eval/Dockerfile`; `run.json` records the
  version the image reports. mypy is the checker the roadmap names. It installs
  from PyPI as compiled wheels, with no download at run time; the `pyright`
  package on PyPI fetches its npm package on first use, which the grader (no
  network) cannot do.
- Grading: the grader first runs
  `mypy --strict --cache-dir=/dev/null solution.py` in a fresh container, in the
  same mount and with the same limits as the hidden cases. A solution that fails
  the checker is a failing run with 0 cases passed, like an Agentica program
  that fails `agentica check` and never runs. The row has `failure: check` and
  the first mypy error code (`arg-type`, `assignment`, `return`...) as `code`,
  or `syntax` for a parse error, and `check_errors`, the number of errors. A
  checker that runs for more than 90 seconds is `failure: check-timeout`. A
  passing solution then runs against the hidden cases like any other.
- Silencing the checker fails the run. A solution with a `# type: ignore` or a
  `# mypy:` comment (such as `# mypy: ignore-errors`, which makes
  `mypy --strict` pass) fails before mypy runs, with `failure: check`,
  `code: ignore` and 0 cases passed. The prompt forbids `# type: ignore` and
  weakening the options; it does not name `# mypy:` (the prompt stays as it is
  so that rounds remain comparable), but the grader rejects those comments too.
  Every typed row has `type_ignores`, the number of those comments, so a failing
  row shows it, and `type_escapes`, the number of `Any`, `cast(`,
  `no_type_check` and `TYPE_CHECKING` in the source. `type_escapes` is a
  heuristic text count: words in strings and comments count, and an alias
  (`import typing as t`, `from typing import Any as A`) hides one. Escapes do
  not fail a run, and the checker still runs, but check them before you compare
  the arms: `summary.md` shows their mean in the `type escapes` column.
- Measures: `interpreter_runs` counts every bash call that runs `agentica`,
  `python` or `mypy`; `check_runs` counts the calls to `mypy` and
  `agentica check` (a lower bound: a command is recognised at the start of a
  shell segment, after `env`, `time`, `timeout N` and `NAME=value` prefixes, so
  a checker run through another wrapper or a script is not counted);
  `check_failures` counts those that failed (a mypy `error:` line, an
  `error[...]` diagnostic); `failing_runs` counts every failing call, checks
  included, so repairs are compared with the checker calls on both sides.
  Tokens, turns, cost and seconds are the same as in the Agentica arms.
  `diagnostics.py` still counts Agentica diagnostics only. Only `--agent pi`
  reports calls: `--agent claude` gives totals, so its interpreter, check and
  failing runs read 0, which means not measured.
- Starts: `start.py` of t9 to t19 is typed and passes `mypy --strict`. For t2,
  t3 and t5 (written for the untyped arm) `start.typed.py` is the same program
  with annotations, and the typed arm gets it as `start.py`; for t2 and t5 it
  fails the checker for the same reasons the Agentica start fails
  `agentica check`.
- The untyped `python` arm stays for comparison with the early rounds. It is not
  part of the pilot of phase 6c. Its workspace no longer gets the Agentica
  binaries.

### Hidden cases

A case is `hidden/NN.in` (standard input) and `hidden/NN.out` (the expected
standard output, compared after trimming the final newlines); the run passes the
case when the output is equal and the exit code is 0. A task directory may add
two optional files, which the integration and big-data tasks use:

- `hidden/driver.py` makes a case a small scenario. The runner starts
  `python3 -I -` in the grader container with the driver source on its standard
  input, the content of `NN.in` as its first argument (`sys.argv[1]`, read as
  bytes and decoded as UTF-8, so a CRLF stays CRLF) and the solution command
  after it (`sys.argv[2:]`), and compares what the driver prints. The driver is
  Python standard library only and the independent peer: it runs the solution
  with an absolute path (`/workspace/bin/agentica /workspace/solution.agc`, or
  `python3 -I /workspace/solution.py`), serves or calls it on `127.0.0.1` port
  0, creates its fixtures in a temporary directory, and prints a transcript. The
  driver source is never mounted and is read from the standard input, so it is
  in no file and in no `/proc/*/cmdline`; the harness does not defend against a
  solution that reads the memory of its parent process. The case content is in
  the command line, and a plain case gives it to the solution as its input
  anyway. The drivers: t17 is an HTTP server (`http.server`) that checks the
  request and prints the requests it got; t18 starts the solution as a server,
  reads its `listening PORT` line and calls it with `http.client`; t19 writes
  the CSV, runs the program with relative paths and prints the file it wrote;
  t20 generates a log and checks the answer itself.
- `hidden/timeout` is the time limit of one case in seconds (the default is 10).
  t20 has 60.

t20 generates its logs (a fixed pseudo-random sequence, 50,000 and 600,000
lines, with invalid, blank, CRLF and 3,000-character lines), so the repository
holds no big file. The harness does not limit the memory of the solution. The
Racket launcher alone uses about 140 MB, so a limit that a streaming Agentica
program passes and a whole-file Python program fails would need a file much
bigger than the 128 MB `/tmp` of the container. The task statement says the file
is big and gives no memory limit. The task statement tells every arm the same
thing: do not read the whole file into memory, process it line by line, and no
line is longer than 4000 bytes (the longest generated line is 3,056 bytes). The
measure is whether the agent streams: in Agentica a whole-file read of more than
1 MiB fails, and in Python it is allowed and passes. Report t20 apart from the
cross-arm aggregate, as a streaming probe: it shows whether an agent finds the
streaming calls of its language, not how well it programs in general, and a
Python solution that ignores the instruction still passes.

### Before a round

- Network access for the agents. Agent containers can reach the provider, so
  they can reach the whole internet, and the programming skill links
  `https://sonic182.github.io/agentica/llms.txt`, so an agent with a shell can
  read the public site. Decide before a round whether that is allowed, and
  record it with the results: `run.json` has `agent_network` (`true` for a model
  run, `false` for `--check-references`), and `net_commands` counts the commands
  that mention `wget`, `git clone`, `github.com`, `pip install`, `npm`, `apt`,
  or `curl` or `urllib` to a host other than `localhost` and `127.0.0.1`. The
  runner has no allow-list for the provider host, so closing the network for the
  agents needs a proxy or firewall that you provide.
- Rebuild the image if the Dockerfile changed, and run `--check-references`.
- Do not merge anything or change the skill while a round runs.
- If `/tmp` is a small `tmpfs`, point `TMPDIR` at a directory on disk before you
  start the runner. Each run copies the runtime bundle (about 580 MB) into a
  temporary directory, and t20 writes big logs there, so four runs at a time can
  fill a 6 GB `/tmp` and stop the round with `No space left on device`.

## Results

Tokens are input plus output per run. A failing interpreter run is an `agentica`
call that ended with an error. Rounds 1 to 4 used earlier sandboxes (round 1 had
none), so they do not validate the current Docker boundary. Round 5 is the first
run in Docker. Compare rows within a table, not across tables.

### Round 1: the arms (2026-10-01)

Five tasks, 3 reps each, DeepSeek V4.1 flash.

| Arm | Passed | Tokens/run | Seconds/run | Failing runs/run |
|---|---|---|---|---|
| `python` | 15/15 | 3,506 | 14 | 0 |
| `skill` | 15/15 | 13,681 | 27 | 0.27 |
| `grammar` | 15/15 | 15,944 | 32 | 0.40 |

- Every run passed, so these tasks do not separate the arms by accuracy.
- Agentica used about 4 times the tokens of Python. The skill used 14% fewer
  than the grammar and examples.

### Rounds 2 to 4: the `binary` arm and the diagnostics (2026-10-01 and 10-02)

| Round | Change | Passed | Tokens/run | Seconds/run | Failing/run |
|---|---|---|---|---|---|
| 2 | plain one-caret diagnostics | 15/15 | 38,740 | 120 | 3.2 |
| 3 | labels, `help` and suggestions | 15/15 | 25,733 | 58 | 2.5 |
| 4 | round 3, and the prompt names `--help` | 15/15 | 24,574 | 70 | 1.3 |

- Richer diagnostics cut the tokens by about a third and the time by half, with
  no docs.
- The `--help` sentence made no visible difference. With 3 reps, the spread
  inside one cell is as large as these gaps, so treat them as a direction.

### Rounds 5 and 6: the Ruby-style language, `binary` arm (2026-10-10)

Round 6 runs after the parser accepted the forms that round 5 showed agents
writing (an optional `do`, one-line `case` arms, calls without parentheses) and
hinted the rest.

| Round | Tasks | Passed | Tokens/run | Seconds/run | Failing/run |
|---|---|---|---|---|---|
| 5 | t1 to t5 (15 runs) | 15/15 | 24,526 | 89 | 4.2 |
| 5 | t6 to t8 (9 runs) | 9/9 | 76,363 | 261 | 12.7 |
| 6 | t1 to t5 (15 runs) | 14/15 | 31,691 | 99 | 3.1 |
| 6 | t6 to t8 (9 runs) | 9/9 | 78,694 | 253 | 7.9 |

- Failing interpreter runs fell by about a quarter on t1 to t5 and by about 40%
  on t6 to t8. Tokens did not fall; with 3 reps, the token means move a lot
  between rounds.
- Agents with no docs write what the diagnostics call Ruby: `while cond do`,
  `case x`, `IO.gets!`, `var x = ...`, `when`. Round 5 showed these as parse
  errors, and round 6 stopped failing on the accepted ones.
- One run hit the 10-minute limit: it searched the binary for builtin
  descriptions instead of writing code.

### Round 7: splitting the skill (2026-10-10)

An A/B of the `skill` arm on all eight tasks, 24 runs each. 7a read one
17k-token `language.md` up front. 7b read a 5k-token core in `SKILL.md`, and the
references only when a table said so.

| Round | Passed | Tokens/run | Seconds/run | Failing/run | Cost/run |
|---|---|---|---|---|---|
| 7a, old layout | 24/24 | 28,857 | 31 | 0.13 | $0.008 |
| 7b, split skill | 24/24 | 15,800 | 26 | 0.21 | $0.005 |

The split cut the tokens by 45% and the cost by 39%, with the same accuracy. The
agents read only the references their task needed.

### Round 8: a second model, GLM 5.3 flash (2026-10-10)

The `binary` arm on the head of PR #33.

| Tasks | Passed | Tokens/run | Seconds/run | Failing/run |
|---|---|---|---|---|
| t1 to t5 (15 runs) | 15/15 | 11,821 | 33 | 4.8 |
| t6 to t8 (9 runs) | 8/9 | 79,286 | 189 | 22.8 |

- GLM used fewer tokens than DeepSeek on t1 to t5, and it hit more errors.
- Both models wrote the same Ruby and Python forms, so the habits are not one
  model's quirk. GLM also wrote `puts` with a non-String value and `to_s` on
  `Bool`. Ruby allows both, and the checker rejected both in those rounds.
- One t6 run failed a hidden case with a logic error.

### Round 9: regression on the VM (2026-10-14)

The `binary` arm on master `e24fac9` (the C VM runs every program; the evaluator
is gone), t1 to t8, 3 reps per task, with the models of rounds 6 and 8. It asks
whether the VM-only language regressed for agents (roadmap row 7.2.2). Tokens
are input plus output, without cached tokens, as in the rounds above. Both
models together cost $0.58.

| Model | Tasks | Passed | Tokens/run | Seconds/run | Failing/run | Before (round 6 or 8) |
|---|---|---|---|---|---|---|
| DeepSeek V4.1 flash | t1 to t5 (15 runs) | 14/15 | 21,184 | 98 | 2.7 | 14/15, 31,691, 99, 3.1 |
| DeepSeek V4.1 flash | t6 to t8 (9 runs) | 9/9 | 62,955 | 309 | 7.8 | 9/9, 78,694, 253, 7.9 |
| GLM 5.3 flash | t1 to t5 (15 runs) | 14/15 | 8,456 | 39 | 4.1 | 15/15, 11,821, 33, 4.8 |
| GLM 5.3 flash | t6 to t8 (9 runs) | 7/9 | 25,777 | 135 | 18.2 | 8/9, 79,286, 189, 22.8 |

- No regression. Accuracy is the same within one run, and tokens fell for both
  models. With 3 reps, the token means move a lot between rounds, so treat the
  size of the drop as a direction.
- The three GLM failures are logic errors, checked by grading the solutions
  again by hand: a t6 run that does not reject an invalid catalog, a t6 run that
  filters the wrong items, and a t4 run that fails one of six cases.
- The DeepSeek failure is a t1 run that hit the 10-minute limit. It searched the
  binary for builtin descriptions instead of writing code, like the round 6 run.
- t4 (word count) cost DeepSeek about 60,000 tokens per run, three times the
  other easy tasks. The most repeated error was `CHECK-CAPTURED-ASSIGNMENT`,
  about 17 times per run: the agents assign a counter inside an `each` block,
  Ruby style. PR #195 made its help name the rewrite (`for w in words ... end`).
- The `binary` arm is not docs-free. Its workspace holds the `raco distribute`
  bundle, which includes the Racket source of the front end
  (`lib/plt/agentica/.../main.rkt`), and the agents read it and grep the binary
  for builtin descriptions. This was true in the earlier rounds too, so the
  comparison holds.

### Round 10: the 6c pilot, Agentica against typed Python (2026-10-14)

The `skill` arm against the `typed-python` arm (`mypy --strict`) on all twenty
tasks, 3 reps per cell, master `38fe556`, 60 runs per arm and model. Seconds are
left out: to finish sooner, the runs went 4 to 6 at a time, next to other
rounds, so they are not comparable. Rounds 9 to 11 together cost $3.75.

| Model | `skill` passed | `typed-python` passed | `skill` tokens/run | `typed-python` tokens/run | `skill` cost/run | `typed-python` cost/run |
|---|---|---|---|---|---|---|
| DeepSeek V4.1 flash | 59/60 | 57/60 | 24,444 | 12,969 | $0.0082 | $0.0053 |
| GLM 5.3 flash | 58/60 | 52/60 | 15,607 | 5,035 | $0.0056 | $0.0017 |
| gpt-oss-120b | 31/60 | 45/60 | 21,980 | 8,303 | $0.0087 | $0.0028 |

- With DeepSeek and GLM, Agentica passed as often as typed Python or more.
  Almost every failure on both sides is a logic error on a hidden case (GLM's
  eight typed-Python failures are all logic errors); one GLM Agentica run
  crashed at run time.
- Agentica costs 1.5 to 3.3 times more per run. Most of the gap is reading the
  skill: the tokens per run are two to three times those of Python, and on the
  easy tasks the skill is most of the cost.
- Typed Python escaped the checker about 0.5 to 0.9 times per run (`Any`,
  `cast(`, `no_type_check`, `TYPE_CHECKING`). No DeepSeek or GLM run used
  `# type: ignore`; gpt-oss tried it 8 times, and those runs failed as `ignore`.
- gpt-oss did worse in Agentica. It writes C-style code (`;` at the end of a
  line, braces for blocks), gets `LEX-UNEXPECTED-CHAR` and
  `LEX-UNMATCHED-DELIMITER`, and in five runs wrote no `solution.agc` (the runs
  checked by hand wrote `solution.py` instead). Its Agentica failures: 13 logic,
  7 syntax, 5 no file, 3 check, 1 run time.
- t20, the streaming probe, reported apart: DeepSeek and GLM passed it 3/3 in
  both arms; gpt-oss passed 0/3 in Agentica and 3/3 in typed Python.
- Nemotron Lightning 3.5 (30B, about 3B active) was dropped part way: 1 of 23
  Agentica runs passed, against 14 of 24 typed-Python runs. It rarely wrote
  Agentica: it wrote `solution.py` and stopped.
- With 3 reps per cell, these are directions, not claims. The full round
  (step 10) needs more reps.

### Round 11: the new `agentica --help` (2026-10-14)

The `binary` arm, t1 to t8, 3 reps, on master `38fe556` plus PR #198, which made
`agentica --help` and `agentica help` list the subcommands, four core rules
(calls need parentheses; values are immutable, so assign the result; a block
cannot assign an outer variable, use `for` or `reduce`; `Result` and `try`) and
the builtin namespaces. The prompt is the same as in round 9. Run next to round
10, so seconds are left out.

| Model | Tasks | Round 9 (old help) | Round 11 (new help) |
|---|---|---|---|
| DeepSeek V4.1 flash | t1 to t5 | 14/15, 21,184 tokens, 2.7 failing, $0.0073 | 15/15, 13,997, 1.2, $0.0048 |
| DeepSeek V4.1 flash | t6 to t8 | 9/9, 62,955, 7.8, $0.0271 | 9/9, 37,996, 5.4, $0.0156 |
| GLM 5.3 flash | t1 to t5 | 14/15, 8,456, 4.1, $0.0042 | 15/15, 6,662, 2.7, $0.0035 |
| GLM 5.3 flash | t6 to t8 | 7/9, 25,777, 18.2, $0.0181 | 8/9, 22,821, 13.7, $0.0156 |
| gpt-oss-120b | t1 to t5 | – | 10/15, 8,314, 2.8, $0.0032 |
| gpt-oss-120b | t6 to t8 | – | 0/9, 18,319, 4.4, $0.0072 |

- The new help cut tokens by a third to a half for DeepSeek and by 10 to 20% for
  GLM, with fewer failing runs and the same or better accuracy. The agents read
  `agentica --help` early and use its rules.
- gpt-oss reads the help but still writes `;` and braces, which the help does
  not mention, and the lexer diagnostics for them give no hint. It then asks
  `agentica help while`, which only covers builtins.
- Nemotron passed 8 of 19 before it was dropped.

### Round 12: the smaller skill and the new hints (2026-10-14)

The `skill` arm on all twenty tasks, 3 reps per cell, with the same prompt and
tasks as round 10. It ran on master `34ab698`, which has three changes that
round 10 did not have:

- PR #200: hints for `;` and braces.
- PR #201: hints for other common errors: `//` comments, single quotes, `Int`
  and `Float`, foreign `String` methods, `Map.new`, empty literals, a missing
  return, and top-level statements.
- PR #204: the `agentica-programming` skill cut from about 5,300 to about 1,600
  tokens in `SKILL.md`. The core-language detail moved to
  `references/language.md`.

Seconds are left out, because the runs went in parallel. Round 12 cost $1.10.
Rounds 9 to 12 together cost $4.85 of the $10 budget.

| Model | Round 10 passed | Round 12 passed | Round 10 tokens/run | Round 12 tokens/run | Round 10 cost/run | Round 12 cost/run |
|---|---|---|---|---|---|---|
| DeepSeek V4.1 flash | 59/60 | 59/60 | 24,444 | 21,090 | $0.0082 | $0.0074 |
| GLM 5.3 flash | 58/60 | 55/60 | 15,607 | 12,060 | $0.0056 | $0.0045 |
| gpt-oss-120b | 31/60 | 30/60 | 21,980 | 17,581 | $0.0087 | $0.0065 |

- Tokens per run fell 14% (DeepSeek), 23% (GLM) and 20% (gpt-oss). Cost per run
  fell 10%, 19% and 26%.
- Pass rates held within noise for 3 reps. DeepSeek's one failure and all five
  of GLM's are logic errors on hidden cases: no syntax, check or run-time
  failure.
- gpt-oss still fails half of its runs. Its 30 failures are 11 logic, 8 syntax
  (5 `PARSE-UNEXPECTED-TOKEN`, 2 `LEX-UNEXPECTED-CHAR`, 1
  `LEX-UNMATCHED-DELIMITER`), 3 check (`CHECK-TYPE-MISMATCH`,
  `CHECK-REDEFINED-NAME`, `CHECK-EMPTY-MAP-TYPE`), 1 run time
  (`RUNTIME-INVALID-NUMBER`), and 7 runs that wrote no solution file. It failed
  t20 3/3 again; DeepSeek and GLM passed t20 3/3 each.
- The gap to typed Python on cost narrows but stays. Typed Python cost $0.0053,
  $0.0017 and $0.0028 per run in round 10.
- With 3 reps, these are directions, not claims.

Round 12 is the last evaluation round until after the bootstrap of the
self-hosted front end ([§35](future/35-self-hosting.md), roadmap row 7.2.7) and
any improvements that follow it. The owner decided this on 2026-10-14. The full
6c round (roadmap row 10) waits for that too. See the
[roadmap](roadmap/README.md).

### JSON tasks: smoke run (2026-10-03)

One rep per cell, DeepSeek V4.1 flash, 4 runs at a time, 600 s limit. The
reference solutions passed all 28 hidden-case runs in Docker.

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

A one-rep smoke run shows that the tasks can be solved and the runner works. It
does not measure accuracy. The `binary` runs took about three to four times as
long as the `skill` runs and repaired their interpreter errors.

The `t8-enum-ledger` reference solutions passed all 8 hidden cases in Docker on
2026-10-04. Its model results are in the t6 to t8 rows above.

## Diagnostics

Hits of the top codes in the `binary` arm, from `tests/eval/diagnostics.py`, in
the 2026-10 rounds. A dash means the code was not in that round's top list.

| Code | Round 5 | Round 6 | Round 8 (GLM) |
|---|---|---|---|
| `PARSE-UNEXPECTED-TOKEN` | 98 | 47 | 49 |
| `CHECK-UNKNOWN-NAME` | 23 | 22 | 49 |
| `CHECK-TYPE-MISMATCH` | 14 | 16 | 72 |
| `CHECK-MISSING-RETURN` | 11 | 9 | 11 |
| `CHECK-UNKNOWN-METHOD` | – | – | 42 |

- In those rounds most hits were Python and Ruby habits, not logic errors:
  `len(s)`, `s.length`, `x.to_i`, `print(x)`, `!a`, `x += 1`. The checker
  rejected them then, so check the grammar for what the language accepts now.
- In rounds 2 to 4, failing runs were fixed after the agent read the code and
  the span, so the diagnostics worked as a repair signal.

## What the results do not show

- Accuracy on harder tasks. These tasks do not need sorting or building a list,
  and most of them pass.
- Strong models. Only small and cheap ones ran (DeepSeek, GLM, gpt-oss, and
  Nemotron in part). A Sonnet round is postponed, because isolating `claude -p`
  from the global configuration is not solved.
- Whether `--ai` or `--json` help. They were not measured.
- Whether Agentica beats typed Python with confidence. The round 10 pilot points
  that way for two of three models, with 3 reps per cell. The full comparison is
  [roadmap phase
  6c](roadmap/06-validation.md#phase-6c-agentica-against-typed-python).
- Time in rounds 10 and 11, which ran next to each other with more runs at a
  time.
