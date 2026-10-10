# Evaluation results so far

The JSON tasks and their reference validation are documented in [eval-json.md](eval-json.md); the enum/pattern-matching task is in [eval-pattern-matching.md](eval-pattern-matching.md). The diagnostics agents saw across these rounds are summarized in [eval-diagnostics.md](eval-diagnostics.md). Their model evaluations are tracked separately from the historical rounds below.

These are historical runs of `tests/eval/run.py` with `pi` and Fireworks DeepSeek V4.1 flash, one session per run, 10 minute limit, hidden cases graded at the end. They used earlier sandbox setups and do not validate the current Docker boundary. Method and caveats are in [`eval-6a.md`](eval-6a.md). Raw logs are in `tests/eval/results/` (not versioned).

Arms: `python` (same task in Python), `skill` (the `agentica-programming` skill), `grammar` (`docs/grammar.md` and `examples/`, no skill), `binary` (only the `agentica` binary, `agentica check`, and a one-line hint).

Tokens are input plus output per run. Failing runs are interpreter runs in the agent's session that ended with an error. Cost is the model cost reported by `pi`.

## Summary

| Round | Date | What | Runs | Pass | Tokens/run | Seconds/run | Failing runs/run | Cost/run |
|---|---|---|---|---|---|---|---|---|
| 0 | 2026-10-01 | Reference solutions through the runner (harness check) | 28 | 28/28 | – | – | – | – |
| 1 | 2026-10-01 | `python` | 15 | 15/15 | 3,506 | 13.9 | 0.0 | $0.001 |
| 1 | 2026-10-01 | `skill` | 15 | 15/15 | 13,681 | 27.3 | 0.27 | $0.004 |
| 1 | 2026-10-01 | `grammar` | 15 | 15/15 | 15,944 | 32.2 | 0.40 | $0.005 |
| 2 | 2026-10-01 | `binary`, plain diagnostics (Firejail) | 15 | 15/15 | 38,740 | 120 | 3.2 | $0.014 |
| 3 | 2026-10-01 | `binary`, labels, `help`, and suggestions | 15 | 15/15 | 25,733 | 58 | 2.5 | $0.009 |
| 4 | 2026-10-02 | Same as round 3, prompt also says `agentica --help` lists the options | 15 | 15/15 | 24,574 | 70 | 1.33 | $0.008 |
| 5 | 2026-10-10 | `binary`, Ruby-style language (methods, blocks, interpolation, hints), tasks t1–t5 | 15 | 15/15 | 24,526 | 89 | 4.2 | $0.009 |
| 5 | 2026-10-10 | Same run, tasks t6–t8 (JSON and enums) | 9 | 9/9 | 76,363 | 261 | 12.7 | $0.035 |
| 6 | 2026-10-10 | `binary`, round 5 plus the Ruby forms and hints it showed, tasks t1–t5 | 15 | 14/15 | 31,691 | 99 | 3.07 | $0.011 |
| 6 | 2026-10-10 | Same run, tasks t6–t8 | 9 | 9/9 | 78,694 | 253 | 7.89 | $0.033 |
| 7a | 2026-10-10 | `skill`, one `language.md` read up front (old layout), all 8 tasks | 24 | 24/24 | 28,857 | 31 | 0.13 | $0.008 |
| 7b | 2026-10-10 | `skill`, core in `SKILL.md` and references read on demand (new layout), all 8 tasks | 24 | 24/24 | 15,800 | 26 | 0.21 | $0.005 |
| 8 | 2026-10-10 | `binary`, **GLM 5.3 flash**, PR #33 head, tasks t1–t5 | 15 | 15/15 | 11,821 | 33 | 4.80 | $0.004 |
| 8 | 2026-10-10 | Same run, tasks t6–t8 | 9 | 8/9 | 79,286 | 189 | 22.8 | $0.040 |

The round-0 count joins two partial runs. A `binary` round run before the sandbox was fixed (15 runs, 15/15) is discarded: the agents found leftover work directories in `/tmp` that contained the skill (`tests/eval/results/20261001-230301-pi-INVALID`). A smoke run of 2 runs (`binary` and `skill`, `t1-stats`) is not counted.

## Round 1: `python`, `skill`, `grammar` (3 reps per task)

Round 1 ran without Firejail. A log check found no reads of the repo, no network commands, and no gmem or MCP calls.

| Task | `python` tokens / s | `skill` tokens / s | `grammar` tokens / s |
|---|---|---|---|
| t1-stats | 3,291 / 8.3 | 11,602 / 16.9 | 22,143 / 27.2 |
| t2-fix-types | 5,212 / 17.7 | 15,222 / 39.5 | 14,529 / 44.4 |
| t3-struct-change | 3,167 / 9.2 | 13,463 / 15.0 | 10,695 / 21.9 |
| t4-word-count | 2,638 / 7.7 | 12,661 / 24.4 | 10,962 / 28.2 |
| t5-scope-return | 3,220 / 26.8 | 15,458 / 40.6 | 21,389 / 39.4 |

Failing interpreter runs per run: `python` 0 everywhere; `skill` 1.3 in `t2-fix-types`, 0 elsewhere; `grammar` 1.0 in `t2-fix-types`, 0.7 in `t5-scope-return`, 0.3 in `t1-stats`, 0 elsewhere.

- Every run passed every hidden case, so these tasks do not separate the arms by accuracy.
- The skill used about 14% fewer tokens than `grammar` plus examples, with the same results.
- Agentica took about 4 times the tokens of Python on the same task.

## Rounds 2 and 3: the `binary` arm, before and after richer diagnostics

Both rounds ran in Firejail with the repo hidden and the network open, but before the current prepared-chroot boundary. In round 2 one run (`t4-word-count` rep 2) read a leftover planning file from `~/.claude`; that path is hidden since. Round 3 used the checker after phase 5d3 steps 1–4 (labels on operands, the enclosing signature, and grounded `help`). The prompt did not mention `--ai`, but `agentica --help` lists it and `--json`, so an agent could find them; in the logs only `t5-scope-return` rep 2 clearly ran `--ai`.

| Task | Tokens (2 → 3) | Seconds (2 → 3) | Failing runs (2 → 3) |
|---|---|---|---|
| t1-stats | 81,449 → 53,829 | 292 → 105 | 8.3 → 6.7 |
| t2-fix-types | 37,162 → 10,937 | 152 → 41 | 5.3 → 2.0 |
| t3-struct-change | 3,740 → 4,082 | 14 → 12 | 0.0 → 0.0 |
| t4-word-count | 61,995 → 40,438 | 100 → 98 | 0.7 → 1.7 |
| t5-scope-return | 9,354 → 19,379 | 43 → 34 | 1.7 → 2.3 |

- With no skill and no grammar, the agent learned the language from diagnostics and used about 2.8 times the tokens of the `skill` arm in round 2 (38.7k against 13.7k).
- The richer diagnostics lowered the mean by about a third in tokens and by half in time, and `t2-fix-types` by 70% in tokens. `t4-word-count` and `t5-scope-return` got worse in failing runs, and `t5` in tokens.
- Why `t5` rose: one run (rep 2) spent 38k tokens, 30k of them in a single turn after a `find` over its work directory printed 41k characters while the agent looked for documentation. Without that run the tokens of `t5` stay near 10k. The extra failing runs in `t4` and `t5` come from the agents probing language rules (scoping, `while` variables) with small test programs, which the diagnostics do not explain. Neither is a sign that the new diagnostics misled the agent.
- Three runs per cell and one model: the spread between reps of one cell is as large as these differences. Treat the change as a direction, not a result.

## Round 4: the prompt mentions `--help`

Same checker and arm as round 3. The only change is one sentence in the `binary` prompt: "`agentica --help` lists the options."

| Task | Tokens (3 → 4) | Seconds (3 → 4) | Failing runs (3 → 4) |
|---|---|---|---|
| t1-stats | 53,829 → 39,631 | 105 → 89 | 6.7 → 0.3 |
| t2-fix-types | 10,937 → 18,732 | 41 → 84 | 2.0 → 3.0 |
| t3-struct-change | 4,082 → 3,871 | 12 → 13 | 0.0 → 0.0 |
| t4-word-count | 40,438 → 52,239 | 98 → 128 | 1.7 → 1.3 |
| t5-scope-return | 19,379 → 8,397 | 34 → 37 | 2.3 → 2.0 |

- Every run read `--help` once or twice (in round 3 they did it unprompted too), but only one run (`t2-fix-types` rep 3) went on to use `--ai` or `--json`. The sentence made no visible difference; the means of rounds 3 and 4 are within the noise of this design.
- Network: the sandbox leaves the network open, and two `t4-word-count` runs tried to download the language docs from the project's GitHub (`raw.githubusercontent.com/.../grammar.md` and the README) and to list the owner's repositories. The repository is private, so both downloads returned 404 and nothing leaked. If the repository is made public, the `binary` arm needs the network closed for its host (or a different check) before another round. The runs that did this also counted 22 attempts to read the repo path across the round (all blocked).

## Round 5: the Ruby-style language

The `binary` arm on the Ruby-style language (operators, methods on builtins, interpolation, blocks, foreign-habit hints, blank line after `end`), before the follow-up below. Docker sandbox, 3 reps of all 8 tasks, 24/24 runs passed every hidden case. Run directory `tests/eval/results/20261010-102333-pi`.

| Task | Tokens (4 → 5) | Seconds (4 → 5) | Failing runs (4 → 5) |
|---|---|---|---|
| t1-stats | 39,631 → 30,482 | 89 → 128 | 0.3 → 6.0 |
| t2-fix-types | 18,732 → 18,733 | 84 → 43 | 3.0 → 3.7 |
| t3-struct-change | 3,871 → 7,677 | 13 → 22 | 0.0 → 0.0 |
| t4-word-count | 52,239 → 46,319 | 128 → 182 | 1.3 → 9.3 |
| t5-scope-return | 8,397 → 19,418 | 37 → 72 | 2.0 → 2.0 |
| t6-json-catalog | – → 81,495 | – → 308 | – → 16.7 |
| t7-json-stream | – → 86,025 | – → 224 | – → 5.0 |
| t8-enum-ledger | – → 61,568 | – → 252 | – → 16.3 |

- Tokens for t1–t5 did not change (24.6k → 24.5k per run); failing interpreter runs went up from 1.33 to 4.2 per run. With 3 reps per task this is within the noise for tokens, but not for failing runs.
- The agent has no documentation in this arm. Told the language is like Ruby by the diagnostics and hints, it writes more Ruby: `while cond do`, `case x` without `do`, one-line arms (`1 -> puts("one")`), `IO.gets!` without parentheses, `var x = ...`, `when`. These were parse errors, and about half of the parse errors were repeated on the next call (see [eval-diagnostics.md](eval-diagnostics.md#round-5-2026-10-10)).
- Follow-up, after this round: the parser accepts the optional `do`, one-line arms and module calls without parentheses, and gives a hint for the other forms (`let`/`var`, `match`, `when`, `then`, `fn`/`lambda`, `break`, `Result.Ok(x)` as a value, `Command.Show` without parentheses). Not measured yet.
- Network: in t6 and t7 some runs tried `curl` against a guessed `agentica.dev` site and listed installed packages (6 commands). No reads outside the work directory.

## Round 6: the Ruby forms from round 5

Same arm, tasks and setup as round 5, after the parser accepted the optional `do`, one-line case arms and module calls without parentheses, and hinted the other forms (PR #31). Run directory `tests/eval/results/20261010-113647-pi`.

| Task | Tokens (5 → 6) | Seconds (5 → 6) | Failing runs (5 → 6) |
|---|---|---|---|
| t1-stats | 30,482 → 38,270 | 128 → 275 | 6.0 → 2.3 |
| t2-fix-types | 18,733 → 29,718 | 43 → 33 | 3.7 → 3.7 |
| t3-struct-change | 7,677 → 15,261 | 22 → 18 | 0.0 → 0.0 |
| t4-word-count | 46,319 → 55,263 | 182 → 131 | 9.3 → 8.0 |
| t5-scope-return | 19,418 → 19,944 | 72 → 38 | 2.0 → 1.3 |
| t6-json-catalog | 81,495 → 70,916 | 308 → 323 | 16.7 → 4.7 |
| t7-json-stream | 86,025 → 109,596 | 224 → 253 | 5.0 → 5.3 |
| t8-enum-ledger | 61,568 → 55,571 | 252 → 184 | 16.3 → 13.7 |

- Failing interpreter runs went down: 4.2 → 3.07 per run on t1–t5, and 12.7 → 7.9 on t6–t8. Invocations with a diagnostic went from 183 to 117, and parse errors from 98 (48 repeated) to 47 (13 repeated); see [eval-diagnostics.md](eval-diagnostics.md#round-6-2026-10-10).
- Tokens did not go down (24.5k → 31.7k on t1–t5, 76k → 79k on t6–t8). With 3 reps the per-task token means move a lot between rounds (t2 and t3 doubled with no relevant change), so this is mostly noise.
- One run failed: `t1-stats` rep 3 hit the 10 minute limit without writing a file. It spent the run searching the `agentica` binary for builtin descriptions with `grep -a` instead of writing code. Its 600 s explain most of the t1 time.
- Network: one `curl` in t1–t5 and five in t6–t8, as in round 5. No reads outside the work directory.

## Round 7: splitting the programming skill

An A/B of the `skill` arm on the same language and tasks, run in parallel. 7a used `master` with the old layout, where `SKILL.md` sends the agent to read `references/language.md` (about 17k tokens) first. 7b used PR #32, where the core language is in `SKILL.md` (about 5k tokens) and ten references are read when a table says so. 7b ran before the PR's small review fixes. Run directories: `tests/eval/results/20261010-120553-pi-7a-old-layout` and `tests/eval/results/20261010-120546-pi`.

| Task | Tokens (7a → 7b) | Seconds (7a → 7b) | Failing runs (7a → 7b) | Cost (7a → 7b) |
|---|---|---|---|---|
| t1-stats | 22,433 → 13,878 | 20 → 18 | 0.0 → 0.0 | $0.0059 → $0.0039 |
| t2-fix-types | 21,473 → 13,473 | 23 → 17 | 0.0 → 0.7 | $0.0057 → $0.0038 |
| t3-struct-change | 19,265 → 9,934 | 14 → 11 | 0.0 → 0.0 | $0.0050 → $0.0027 |
| t4-word-count | 28,329 → 13,182 | 18 → 16 | 0.0 → 0.0 | $0.0072 → $0.0037 |
| t5-scope-return | 23,653 → 14,355 | 20 → 19 | 0.7 → 0.3 | $0.0064 → $0.0041 |
| t6-json-catalog | 28,729 → 19,829 | 52 → 45 | 0.0 → 0.0 | $0.0088 → $0.0063 |
| t7-json-stream | 36,577 → 20,835 | 57 → 39 | 0.3 → 0.0 | $0.0114 → $0.0070 |
| t8-enum-ledger | 50,397 → 20,911 | 46 → 47 | 0.0 → 0.7 | $0.0139 → $0.0074 |

- Tokens per run fell 45% (28.9k → 15.8k) and cost 39%, with every task lower. Accuracy stayed at 24/24. Failing runs moved from 3 to 5 in total, within noise.
- The agents read only what the task needed: `builtins.md` in 21 of 24 runs, `examples.md` in 16, `json.md` only in the JSON tasks (t6, t7). The t3 runs read no reference at all. No run opened the network, process, task, file, BDD or diagnostics references.
- Both arms beat the round-1 `skill` numbers on t1–t5 (13.7k tokens then, 23.0k in 7a, 13.0k in 7b), but the language and the skill have grown since round 1, so only 7a vs 7b is a fair comparison.

## Round 8: a second model (GLM 5.3 flash)

The `binary` arm with `fireworks/accounts/fireworks/models/glm-5p3-flash` on the head of PR #33, to check that the forms accepted from DeepSeek's logs are not habits of one model. Run directory `tests/eval/results/20261010-125259-pi`.

| Task | Tokens | Seconds | Failing runs | Pass |
|---|---|---|---|---|
| t1-stats | 13,167 | 64 | 7.3 | 3/3 |
| t2-fix-types | 13,338 | 19 | 2.7 | 3/3 |
| t3-struct-change | 4,639 | 10 | 0.0 | 3/3 |
| t4-word-count | 22,532 | 59 | 13.7 | 3/3 |
| t5-scope-return | 5,429 | 13 | 0.3 | 3/3 |
| t6-json-catalog | 91,152 | 215 | 29.3 | 2/3 |
| t7-json-stream | 69,464 | 187 | 23.0 | 3/3 |
| t8-enum-ledger | 77,244 | 165 | 16.0 | 3/3 |

- GLM used fewer tokens than DeepSeek on t1–t5 (11.8k vs 31.7k in round 6) but ran into more errors (4.8 vs 3.1 failing runs per run, 22.8 vs 7.9 on t6–t8). One t6 run failed one hidden case (a logic error).
- The forms accepted from DeepSeek's logs also appear in GLM's code: `Result.Ok(...)` as a value, top-level `print`, `case x` without `do`, `for ... do`, `Enum.Variant` without parentheses, and `break` (6 runs). `ok(v)` as a pattern did not appear; it is accepted for consistency, not because of GLM.
- What GLM adds, see [eval-diagnostics.md](eval-diagnostics.md#round-8-glm-53-flash-2026-10-10): `puts` with a non-String value (16 of 24 runs) and `to_s` on `Bool` (10 hits). Both are real Ruby and DeepSeek also hit the first one.

## What the results do not show

- Whether `--ai` or `--json` helps: not measured.
- Which part of the richer diagnostics (labels, help, suggestions) helped: not measured separately.
- Other models: the Sonnet 5.5 round is postponed (isolating `claude -p` from the global configuration is unsolved).
- Harder tasks: none of these tasks needs sorting or list building, which the language cannot do yet (phase 5n).
- A `skill` or `grammar` round with the richer diagnostics: not run.

## How to reproduce

```text
python3 tests/eval/run.py --pass-env FIREWORKS_API_KEY --model fireworks/accounts/fireworks/models/deepseek-v4p1-flash --agent pi --arms python skill grammar --reps 3 --jobs 4
python3 tests/eval/run.py --pass-env FIREWORKS_API_KEY --model fireworks/accounts/fireworks/models/deepseek-v4p1-flash --agent pi --arms binary --reps 3 --jobs 4
python3 tests/eval/run.py --summarize tests/eval/results/<run directory>
```

To select only the historical five tasks, add `--tasks t1-stats t2-fix-types t3-struct-change t4-word-count t5-scope-return`; the default task set now includes the JSON tasks.

Docker must be available. The default image is built automatically; `--image NAME` selects a prepared custom image, which is also needed for `--agent claude` because the default image contains Pi only. Firejail is optional: add `--sandbox firejail --chroot-root /path/to/prepared-rootfs`. Its rootfs must contain the selected agent CLI and Python under `/usr/local/bin`, `/usr/bin`, or `/bin`; users enable and configure Firejail themselves.
