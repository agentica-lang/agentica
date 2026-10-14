---
title: Errors
weight: 3
description: Report failures as Result values and read them.
---

Agentica has no exceptions. A function that can fail returns a `Result`, and the caller reads it.

- Use [Result](/library/errors/result/) to build `ok(value)` and `error(message)`, and to read them with `Result.ok?`, `Result.unwrap!`, `Result.unwrap_or` and `Result.message`.
- Use `try` inside a function that returns a `Result` to pass an error on to its caller. The tour page [Result and try](/tour/results-and-try/) explains it.
