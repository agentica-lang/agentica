# Agentica: grammar and language design

Status: implemented by the interpreter: a Racket front end (`src/`) that compiles to bytecode for the C VM (`vm/`), which runs every program. This document describes what the interpreter accepts; remaining proposals live in [`future/`](../future/README.md). The text is split by section: the index is [`../grammar.md`](../grammar.md), and each file keeps the section numbers of the whole.

## 1. What we want to validate

Agentica is a language designed so AI agents can write, read, and fix programs easily. The priority is to experiment with the syntax, the rules, and the diagnostics. Performance, concurrency, and the final runtime come later.

The direction is KISS: Ruby-like syntax, static types, local inference, and few ways to express each operation. This specification does not depend on the language the interpreter is written in.

