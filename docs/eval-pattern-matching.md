# Enum and pattern-matching evaluation

`t8-enum-ledger` evaluates writing an Agentica program with generic enum constructors and exhaustive `case` matching. The task parses commands into `Command[T]`, matches `Result` values, dispatches enum variants, and continues after invalid input. Eight hidden cases cover empty input, updates, malformed commands, invalid amounts, insufficient balance, reset, whitespace, and limits.

## Reference validation

On 2026-10-04, both reference solutions passed all eight cases through the Docker grader:

```text
python3 tests/eval/run.py --agent reference --tasks t8-enum-ledger --arms binary python --jobs 2
```

This validates task solvability and grading, not model performance.

## Model run

Use the usual model and explicitly pass its provider credential as described in [eval-6a.md](eval-6a.md). A one-repetition smoke run is:

```sh
python3 tests/eval/run.py --agent pi --model fireworks/accounts/fireworks/models/deepseek-v4p1-flash \
  --tasks t8-enum-ledger --arms skill grammar binary python --reps 1 --jobs 4 \
  --pass-env FIREWORKS_API_KEY
```

Do not combine this single-task result with historical accuracy totals. One repetition is a smoke check, not a reliable comparison.
