# Agent evaluation

Can an agent write and repair Agentica programs? An agent gets one task, and its
program is graded against hidden cases. The runs count passing cases, tokens,
time, and interpreter and checker runs that failed.

The tasks are in `tests/eval/tasks/`. Each has a `task.md`, a reference solution
in Agentica (`reference.agc`) and in typed Python (`reference.py`), and hidden
cases. The tasks that start from a program have `start.agc` and `start.py` (and
`start.typed.py` when the typed arm needs a different start). A starter program
can hold an intentional bug: when you edit a task, do not repair it and do not
change the hidden cases.
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
| `t9-inventory-orders` | modify a program | add bulk discounts, `remove` and a `low` mark to a shop program |
| `t10-calc-extend` | modify a program | add `%`, right-associative `^` and unary minus to a calculator |
| `t11-gradebook` | modify a program | add weights, ranking with ties and letter grades; the data model changes |
| `t12-member-ids` | type change | member and book ids from `Int` to `String` through the whole program |
| `t13-transfer-variant` | type change | add an enum variant that every `case` (Python: `assert_never`) handles |
| `t14-price-lookup` | type change | `find_price` returns `Result[Int]` (`int \| None`) instead of `-1`; four callers |
| `t15-robust-ledger` | error handling | report `line N: problem`, skip the bad line, go on |
| `t16-robust-csv` | error handling | the same for a CSV summary, with five checks in a fixed order |
| `t17-quote-client` | repair an integration | an HTTP client with the wrong path, JSON shape and header |
| `t18-stats-server` | repair an integration | an `std/http` server with wrong JSON, status codes and port line |
| `t19-orders-report` | repair an integration | a CSV to JSON pipeline with the wrong delimiter, header and path |
| `t20-big-log` | streaming probe | slow errors of a log up to 29 MB; a whole-file read stops at 1 MiB, so stream (`File.each_line`, `File.read_line`) |

The arms are the context an agent gets:

- `python`: the same task in Python (untyped). The baseline of the first rounds.
- `typed-python`: the same task in Python with type annotations, checked by
  `mypy --strict` (see "The typed Python arm").
- `skill`: the `agentica-programming` skill and the `agentica` binary.
- `skill-nocli`: the `skill` arm without the four query commands (`agentica
  outline`, `type-at`, `symbol`, `refs`), for the measurement of [§39.12](
  future/39-semantic-cli.md). It is opt-in: `--arms` must name it. See "The
  no-CLI arm".
- `grammar`: `docs/grammar.md` and `examples/`, without the skill. Its prompt
  gained the `agentica help` pointer (commit efba1a0b), so older grammar-arm
  results are not comparable.
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

# The 6c round: one command per model, from a worktree pinned to the release
# tag (git worktree add ../agentica-6c TAG) so that master can move on; TAG is
# the first release with the query-command counts, the skill-nocli arm and
# --max-cost
python3 tests/eval/run.py --agent pi --model fireworks/accounts/fireworks/models/deepseek-v4p1-flash --pass-env FIREWORKS_API_KEY --arms skill typed-python skill-nocli --arm-tasks skill-nocli=t9-inventory-orders,t11-gradebook,t12-member-ids,t13-transfer-variant,t14-price-lookup --reps 3 --jobs 2 --max-cost 1.1
python3 tests/eval/run.py --agent pi --model fireworks/accounts/fireworks/models/glm-5p3-flash --pass-env FIREWORKS_API_KEY --arms skill typed-python skill-nocli --arm-tasks skill-nocli=t9-inventory-orders,t11-gradebook,t12-member-ids,t13-transfer-variant,t14-price-lookup --reps 3 --jobs 2 --max-cost 0.75

# Summarize a finished run, and count the diagnostics the agents saw
python3 tests/eval/run.py --summarize tests/eval/results/<run directory>
python3 tests/eval/diagnostics.py
```

`--tasks` picks tasks (the default is all twenty). `--arms` picks arms (the
default is the first five; `skill-nocli` is opt-in). `--arm-tasks
ARM=TASK,TASK` limits one arm to some of the tasks (full task names, all in
`--tasks`; repeat the option for another arm). `--max-cost USD` is a soft cap on
the cost of the round (see "The budget cap"). `--sandbox firejail
--chroot-root PATH` is the other sandbox; you prepare its rootfs yourself, and
it needs `mypy` for the typed arm. Docker is the only sandbox tested with the
typed arm, the drivers and the loopback peers; Firejail is untested for them.
The results go to `tests/eval/results/`, which is not versioned. Each run
directory has a `run.json` with the commit, the commit of the last change to the
skill, the checker version, the Pi version, the model, the arms, and the image
name and ID, next to `results.jsonl` and `summary.md`. The runner has its own
tests: `python3 -m unittest discover -s tests/eval -p 'test_*.py'`. These unit
tests are not part of `make test` or CI.

`--check-references` is the same as `--agent reference` with the arms `binary`,
`python` and `typed-python` (the three Agentica arms share one reference). It
copies each `reference.*` as the solution, grades it like an agent's, prints the
table, and exits 1 when a reference fails. `make eval-references` runs it with
`--jobs 8`; it is not part of CI. Use it after any change to a task, the runner,
the image or the VM. For the Agentica references it needs `dist/runtime` (the
runner builds it unless you pass `--no-build`), which holds the `dist/agentica`
binary.

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
  image has `libgc1` and `libssl3t64`, which `dist/agentica` links (the
  default Linux build uses the system libraries).
- `--no-build` reuses `dist/runtime`, the bundle that a normal run makes with
  `make` and a copy of `dist/agentica` into its `bin/`. The runner exits when it
  is missing.
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

### Query-command counts

For `--agent pi`, every row and `summary.md` count, next to the checks:

- `query_runs`: bash calls that run `agentica outline`, `type-at`, `symbol` or
  `refs`, with or without `--json`, through a path (`dist/agentica`) or after
  `cd x &&`, `time` or a pipe. Like `check_runs`, it is a lower bound (no
  `bash -c`, no script).
- `read_runs`: calls that read files: a shell segment that starts with `cat`,
  `rg`, `sed`, `head`, `grep` or `tail` (a `| head` filter does not count), and
  every call of Pi's `read` tool.
- `refused_queries`: calls the `skill-nocli` wrapper refused (0 in the other
  arms).

`--agent claude` reports 0 for the counts, which means not measured.

### The no-CLI arm

`skill-nocli` is the `skill` arm with two changes, made in the copy the agent
gets (the skill in the repository is never edited):

- The skill copy has no `references/queries.md` and no `references/analysis.md`,
  and none of the lines that point to them: their two table rows in
  `SKILL.md`, and the `QUERY-` codes of `references/diagnostics.md`. The
  runner stops when any file of the copy still names a query command, so a
  change to the skill cannot leak one unnoticed.
- `bin/agentica` is a shell wrapper and the real binary is `bin/agentica-real`.
  The wrapper answers `outline`, `type-at`, `symbol` and `refs` with exit 2 and
  one stderr line (`agentica: 'refs' is not available in this evaluation arm`),
  appends a line to `bin/.refused-queries`, and passes every other command to
  the real binary. The grader uses the real binary, not the wrapper.

What the arm does not hide, and the results must say: `agentica --help` and
`agentica help` still list the four commands (`run.json` has `arm_notes` with
this), and an agent can call `bin/agentica-real` or read the wrapper. A
`query_runs` above `refused_queries` shows such a bypass. A refused call still
costs the agent a turn; read `refused_queries` with that in mind.

The arm runs on the tasks that cross a program: a change that follows a type
through many uses, where `refs` and `type-at` should help. Proposed subset, from
the task statements (the start programs are 100 to 194 lines):

| Task | Why it crosses the program |
|---|---|
| `t9-inventory-orders` | new fields and a new command through six commands |
| `t11-gradebook` | the data model changes (weights, ranks, grades) |
| `t12-member-ids` | the id type changes through structs, maps, sorting, parsing |
| `t13-transfer-variant` | a new enum variant that every `case` must handle |
| `t14-price-lookup` | a plain value becomes a `Result[Int]` in four callers |

Left out: t3 (a 19-line start, one field), t10 (new operators, not a type
change), and the small programs, where reading the file costs less than a query.
With 3 reps, that is 15 extra runs per model.

### The budget cap

The queue goes rep by rep: rep 1 of every task and arm (task by task, then arm
by arm), then rep 2, and so on; `--jobs` starts runs in that order. A stop then
leaves every task and arm with the same number of reps, give or take one, and
when the cap stops the round, `summary.md` lists the reps each one finished.

`--max-cost USD` is a soft cap, not a hard limit; without it there is no cap.
Before each run starts, the runner adds the cost so far, plus the estimate of
that run and of every run in flight; if the sum passes the cap, it stops
starting new runs (the runs in flight finish) and `summary.md` and `run.json`
get `stopped_for_budget` (true) and `runs_skipped`. Runs already going and
outlier runs can go past the cap by up to `--jobs` times the costliest run. The
6c commands use `--jobs 2`, which keeps that overshoot to about $0.06 at the
costs of rounds 10 and 12 (the costliest run was about $0.03).

The estimate is the highest cost seen so far (never below the mean), and never
below `--run-cost-estimate` (default $0.01). A run that reports no cost (no
usage at all, or `cost.total` of 0: a timeout, a 429, an auth error) is charged
the estimate, stays out of that figure, and prints a `warning:` line. Cost is
what Pi reports (`cost.total`), so the cap is as good as the price table of the
model. The runner prints `cost so far: $X of the $Y cap` after every run, and
`run.json` and `summary.md` end with the total. The cap is per command: for two
models, give each its share of the total (one command each, as in the example
above); a shared total across commands would need a way to read earlier run
folders, which the runner does not have.

For round 13 the owner's hard limit was $2 for both models, so the soft caps
were $1.1 and $0.75: at `--jobs 2` a command can pass its cap by about $0.06.

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
holds no big file. The harness does not limit the memory of the solution, and
the task statement gives no memory limit; it tells every arm the same thing: do
not read the whole file into memory, process it line by line, and no line is
longer than 4000 bytes (the longest generated line is 3,056 bytes). The measure
is whether the agent streams: in Agentica a whole-file read of more than 1 MiB
fails, and in Python it is allowed and passes. Report t20 apart from the
cross-arm aggregate, as a streaming probe: it shows whether an agent finds the
streaming calls of its language, not how well it programs in general, and a
Python solution that ignores the instruction still passes.

### Before a round

- Network access for the agents. Agent containers can reach the provider, so
  they can reach the whole internet, and the programming skill links
  `https://agentica-lang.github.io/agentica/llms.txt`, so an agent with a shell
  can read the public site. Decide before a round whether that is allowed, and
  record it with the results: `run.json` has `agent_network` (`true` for a model
  run, `false` for `--check-references`), and `net_commands` counts the commands
  that mention `wget`, `git clone`, `github.com`, `pip install`, `npm`, `apt`,
  or `curl` or `urllib` to a host other than `localhost` and `127.0.0.1`. The
  runner has no allow-list for the provider host, so closing the network for the
  agents needs a proxy or firewall that you provide.
- Rebuild the image if the Dockerfile changed (`docker rmi
  agentica-eval:local`), and run `--check-references`. The Dockerfile pins Pi
  1.3.0 (the rounds up to 12 used Pi 1.0.0), so token counts of the 6c round
  are not strictly comparable with those of earlier rounds; the arms inside the
  round are. A model run probes `pi --version` in the default image and stops
  when it differs from the Dockerfile's pin (a stale image); `run.json` has
  `pi_version`.
- Do not merge anything or change the skill while a round runs.
- If `/tmp` is a small `tmpfs`, point `TMPDIR` at a directory on disk before you
  start the runner. Each run copies the runtime bundle (about 580 MB) into a
  temporary directory, and t20 writes big logs there, so four runs at a time can
  fill a 6 GB `/tmp` and stop the round with `No space left on device`.

## Results

Tokens are input plus output per run. A failing interpreter run is an `agentica`
call that ended with an error. Rounds 1 to 4 used earlier sandboxes (round 1 had
none); round 5 is the first run in Docker. Compare rows within a round, not
across rounds. With 3 reps per cell, every finding is a direction, not a claim.
The full tables of rounds 1 to 12 are in git history.

### Rounds 1 to 12: findings

| Round | Setup | Finding |
|---|---|---|
| 1 (2026-10-01) | five tasks, DeepSeek V4.1 flash | every arm 15/15: easy tasks do not separate arms. Agentica about 4x Python tokens (`skill` 13,681 per run, `python` 3,506); the skill 14% under grammar and examples |
| 2 to 4 | `binary` arm | richer diagnostics (labels, `help`, suggestions) cut tokens by a third and time by half, with no docs. Naming `--help` in the prompt made no visible difference |
| 5 and 6 (2026-10-10) | `binary`, no docs | agents write Ruby (`while cond do`, `case x`, `var x = ...`, `when`). Accepting those forms cut failing runs by a quarter to 40%; tokens did not fall |
| 7 (2026-10-10) | `skill` A/B | a 5k-token core with on-demand references cut tokens by 45% and cost by 39%, with the same accuracy |
| 8 | GLM 5.3 flash, `binary` | a second model wrote the same Ruby and Python forms, so the habits are not one model's quirk |
| 9 (2026-10-14) | `binary` on the VM, row 7.2.2 | no regression; tokens fell for both models. The repeated `CHECK-CAPTURED-ASSIGNMENT` on t4 got a help naming the `for` rewrite (PR #195) |
| 10 (2026-10-14) | the 6c pilot, `skill` against `typed-python`, 20 tasks | DeepSeek 59/60 against 57/60, GLM 58/60 against 52/60, gpt-oss-120b 31/60 against 45/60. Agentica cost 1.5 to 3.3 times more per run, mostly reading the skill. gpt-oss writes C-style code and sometimes no `solution.agc`; Nemotron rarely wrote Agentica and was dropped. Typed Python escaped the checker 0.5 to 0.9 times per run (`Any`, `cast(`) |
| 11 | `binary`, PR #198 | `agentica --help` with four core rules and the builtin namespaces cut tokens by a third to a half for DeepSeek and 10% to 20% for GLM, with fewer failing runs |
| 12 | `skill`, PRs #200, #201, #204 | hints for `;`, braces and other foreign habits, and `SKILL.md` cut from about 5,300 to 1,600 tokens: tokens per run fell 14% to 23%, pass rates held. gpt-oss still fails half its runs |

### Round 13: the 6c round (2026-10-22)

The first full 6c round, from the worktree pinned to tag 0.8.1 (`5a65383`,
skill commit `95b86f4`), with the `skill`, `typed-python` and `skill-nocli`
arms, 3 reps. Pi 1.3.0, `mypy` 2.3.1, agent network allowed (`agent_network`
true; 12 `net_commands`, all on t18). `--check-references` passed all 60 runs.
The runs went in parallel (`--jobs 2` for both models), so seconds are rough. Pi
1.3.0 means tokens are not comparable with rounds 1 to 12; the arms in this
round are. The round cost $1.52 of the $2.

- **DeepSeek V4.1 flash** (`--max-cost 1.1`, $1.039): the cap stopped it with
  45 runs not started, so it has t1, t2 and t10 to t20 only (13 tasks, 39 runs
  per arm), and `skill-nocli` on t11 to t14 (12 runs).
- **GLM 5.3 flash** (`--max-cost 0.75`, $0.481): complete, 20 tasks, 60 runs per
  arm, and `skill-nocli` on its 5 tasks (15 runs).

Per run, `skill` against `typed-python` on the tasks both ran:

| Model | Arm | Passed | Tokens in | Context | Tokens out | Cost | Turns | Seconds | Failing runs |
|---|---|---|---|---|---|---|---|---|---|
| DeepSeek | `skill` | 38/39 | 22,170 | 152,073 | 5,792 | $0.0144 | 9.6 | 59 | 0.10 |
| DeepSeek | `typed-python` | 39/39 | 8,176 | 32,412 | 4,426 | $0.0079 | 5.7 | 41 | 0.05 |
| GLM | `skill` | 58/60 | 9,302 | 91,885 | 2,858 | $0.0053 | 11.8 | 40 | 0.92 |
| GLM | `typed-python` | 53/60 | 2,824 | 19,227 | 1,474 | $0.0017 | 6.0 | 22 | 0.28 |

"Tokens in" is the uncached input only. "Context" is what the agent read: the
input plus the cache reads (Pi reported no cache writes). The cache reads are
most of it, so "tokens in" understates the gap between the arms.

Cost over the same runs (39 per arm for DeepSeek, 60 for GLM), split as Pi
reports it:

| Model | Arm | Input | Cache read | Output | Total |
|---|---|---|---|---|---|
| DeepSeek | `skill` | $0.259 | $0.030 | $0.271 | $0.561 |
| DeepSeek | `typed-python` | $0.096 | $0.006 | $0.207 | $0.308 |
| GLM | `skill` | $0.084 | $0.149 | $0.086 | $0.318 |
| GLM | `typed-python` | $0.025 | $0.030 | $0.044 | $0.099 |

- **The commands were not used.** `query_runs` is 0 in all 225 Pi runs. In the
  raw logs (`agent.jsonl`), none of the 1,040 bash calls runs `outline`,
  `type-at`, `symbol` or `refs`, no call names `queries.md` or `analysis.md`,
  and `skill-nocli` refused 0 calls (`refused_queries` 0). The round cannot
  show the value of the semantic CLI (§39.12): the measure is inconclusive.
  The skill names them (`SKILL.md` step 5 and the `references/queries.md`
  row), so how it presents them is what to change before the next round.
- **`skill` against `skill-nocli`** (shared tasks: DeepSeek t11 to t14, GLM t9
  and t11 to t14): 12/12 and 15/15 pass in both arms. Since no run used the
  commands, the arms differ only by noise. DeepSeek `skill-nocli` took 25,251
  tokens, 9.5 turns, 5.6 reads and 77 s per run against 22,748, 8.2, 5.0 and
  50 s; GLM took 11,416 tokens, 9.2 turns, 5.1 reads and 34 s against 11,438,
  9.1, 4.4 and 37 s.
- **Pass rates are close.** DeepSeek missed one `skill` run and no
  `typed-python` run; GLM passed more in Agentica (58 against 53). All failures
  are logic errors on hidden cases; none is a syntax, check or run-time
  failure. Agentica: DeepSeek t19 once (0/8); GLM t6 twice (7/8). Typed Python:
  none for DeepSeek; GLM seven (t6 three times, t2, t16, t18 and t19 once).
- **Agentica costs more per run:** 1.8 times (DeepSeek) and 3.1 times (GLM),
  with 4.7 and 4.8 times the context, 1.3 and 1.9 times the output tokens,
  1.7 and 2.0 times the turns, and 1.4 and 1.8 times the seconds. The failing
  check or run calls per run are also higher (GLM 0.92 against 0.28). Counted
  as input plus output without the cache reads, the gap looks like 2.2 and 2.8
  times the tokens; that figure leaves most of the context out.
- **Most of the extra cost is on the input side.** Input and cache reads are
  75% (DeepSeek) and 81% (GLM) of what `skill` costs more than `typed-python`.
  The context, not the output, is what to cut.
- **DeepSeek stopped for budget:** runs go in task-name order (t1, t10 to t19,
  t2, t20, then t3 to t9), so the larger tasks ran first and t3 to t9 have no
  DeepSeek run.
- With 3 reps, and 13 tasks for DeepSeek, these are directions, not claims.

## Diagnostics

`tests/eval/diagnostics.py` counts the codes the agents saw. In the `binary`
rounds 5 to 8 the top codes were `PARSE-UNEXPECTED-TOKEN`, `CHECK-UNKNOWN-NAME`,
`CHECK-TYPE-MISMATCH`, `CHECK-MISSING-RETURN` and `CHECK-UNKNOWN-METHOD`, mostly
Python and Ruby habits, not logic errors (`len(s)`, `s.length`, `x.to_i`,
`print(x)`, `x += 1`; check the grammar for what the language accepts now). In
rounds 2 to 4, agents fixed failing runs after reading the code and the span, so
the diagnostics worked as a repair signal.

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
- Whether the semantic CLI helps. In round 13 no agent called it.
