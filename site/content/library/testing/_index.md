---
title: Testing
weight: 6
description: Unit tests and Gherkin feature files, both run by agentica test, and the profile.
---

`agentica test` runs both kinds of test in one report.

- Use [Test](/library/testing/test/) for unit tests: a `*_test.agc` file with assertions that return a `Result`.
- Use [BDD](/library/testing/bdd/) for feature files in Gherkin. Each scenario starts your program as a separate process, sends it input and checks its output.
- Use [Profile](/library/testing/profile/) to measure sections of a program, hold code to a step budget, and write input for flame graphs.

## Coverage

```sh
agentica test --coverage
```

`--coverage` writes the line coverage of the run to `coverage/lcov.info` as LCOV, which Codecov, Coveralls, genhtml and editor extensions read. After the totals it prints the report's path, one line for each file with the lines that ran, and the total:

```text
coverage: coverage/lcov.info
  src/shapes.agc 4/6 lines (66.6%)
  total 4/6 lines (66.6%)
```

Each test file and each scenario runs with [`--coverage FILE`](/cli/#options), and the runner adds their counts up. So the report counts what that option counts: your files and the packages read in place, not `std/` or fetched packages.

- The test files and step programs that the run ran are left out. A program that a step starts, such as the one of "the Agentica program", is not counted.
- Files are in name order and lines in line order, so `--jobs` does not change the report.
- A run with failing tests still writes the report, and keeps the exit code of the tests.
- A test file stopped at its timeout adds nothing. A part that is not LCOV is left out and named after the summary. Neither changes the exit code.
- The new report replaces an old `coverage/lcov.info` in one step, so a reader never sees half of it.

With `--json`, the report has a `coverage` object. `lines` counts the lines with code and `hit` those that ran; `broken` names the parts left out, and `problem` says why the report could not be written (`null` when it was):

```json
{"path": "coverage/lcov.info", "lines": 6, "hit": 4, "files": [{"file": "src/shapes.agc", "lines": 6, "hit": 4}], "broken": [], "problem": null}
```
