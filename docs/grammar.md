# Agentica: grammar and language design

Implemented language behavior is defined by the Agentica front end and C VM.
This index links to the grammar files, which keep global section numbers and
headings; proposals live in [`future/`](future/README.md). The site displays
these files in order as one page.

- **§1:** [Overview](grammar/01-overview.md#1-what-we-want-to-validate)
- **§2:** [Design decisions](grammar/01-overview.md#2-design-decisions)
- **§3:** [Core program](grammar/01-overview.md#3-a-core-program)
- **§4:** [Lexical conventions](grammar/04-lexical.md)
- **§5:** [Syntax](grammar/05-syntax.md) and
  [modules/imports](grammar/05b-modules.md)
- **§6:** [Semantics](grammar/06-semantics.md)
- **§6:** [Builtins](grammar/06b-builtins.md)
- **§6:** [Tasks and tests](grammar/06c-tasks-and-tests.md)
- **§6:** [I/O and network](grammar/06d-io-and-network.md)
- **§7:** [Diagnostics for agents](grammar/07-diagnostics.md)
- **§8:** [Examples](grammar/08-examples.md)

When a user-facing language or builtin change is made, update the matching
grammar file, the programming skill, and the corresponding site page together
(see [`AGENTS.md`](../AGENTS.md)).
