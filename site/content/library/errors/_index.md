---
title: Errors
weight: 3
description: Report failures as Result values and read them.
---

Agentica has no exceptions. A function that can fail returns a `Result`, and the caller reads it.

- Use [Result](/library/errors/result/) to build `ok(value)` and `error(message)` and to read them.
- A failed Result holds an [Error](/library/errors/error/): its message, kind, code, details, cause and location.
- Use `try` inside a function that returns a `Result` to pass an error on to its caller. The tour page [Result and try](/tour/results-and-try/) explains it.
