# Agentica

Minimal Racket bootstrap for the interpreter described in
[`docs/Agentica-gramatica.md`](docs/Agentica-gramatica.md).

Run the current scaffold with:

```sh
racket src/main.rkt examples/hello.agc
```

It reads the source file and reports that the interpreter is not implemented
yet. Build the core in the order from the grammar: lexer, parser and AST, type
checker, then evaluator and the `main() -> Nil` entry point. Enums and matching
are future extensions.
