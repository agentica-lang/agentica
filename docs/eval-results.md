# Evaluation results so far

These are historical runs of `tests/eval/run.py` with `pi` and Fireworks DeepSeek V4.1 flash, one session per run, 10 minute limit, hidden cases graded at the end. They used earlier sandbox setups and do not validate the current prepared-chroot boundary. Method and caveats are in [`eval-6a.md`](eval-6a.md). Raw logs are in `tests/eval/results/` (not versioned).

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

## What the results do not show

- Whether `--ai` or `--json` helps: not measured.
- Which part of the richer diagnostics (labels, help, suggestions) helped: not measured separately.
- Other models: the Sonnet 5.5 round is postponed (isolating `claude -p` from the global configuration is unsolved).
- Harder tasks: none of these tasks needs sorting or list building, which the language cannot do yet (phase 5n).
- A `skill` or `grammar` round with the richer diagnostics: not run.

## How to reproduce

```text
python3 tests/eval/run.py --chroot-root /path/to/prepared-rootfs --pass-env FIREWORKS_API_KEY --agent pi --arms python skill grammar --reps 3 --jobs 4
python3 tests/eval/run.py --chroot-root /path/to/prepared-rootfs --pass-env FIREWORKS_API_KEY --agent pi --arms binary --reps 3 --jobs 4
python3 tests/eval/run.py --summarize tests/eval/results/<run directory>
```

The root filesystem must contain `pi`, its runtime dependencies, and `python3` under `/usr/local/bin`, `/usr/bin`, or `/bin`; the runner stages Agentica at `/workspace/bin/agentica`. Use `--no-sandbox` only when intentionally running the agent with host filesystem access; the grader stays chrooted with networking disabled.
