---
title: Testing
weight: 6
description: Unit tests and Gherkin feature files, both run by agentica test, and the profile.
---

`agentica test` runs both kinds of test in one report.

- Use [Test](/library/testing/test/) for unit tests: a `*_test.agc` file with assertions that return a `Result`.
- Use [BDD](/library/testing/bdd/) for feature files in Gherkin. Each scenario starts your program as a separate process, sends it input and checks its output.
- Use [Profile](/library/testing/profile/) to measure sections of a program, hold code to a step budget, and write input for flame graphs.
