## Phase 23: Digit separators

**Done (order step 7.2a):** `_` between digits in number literals, in the lexer
and the docs only. The token value does not change, so the AST, the checker,
lowering and the VM stay as they are. Record: the grammar's
[literal section](../grammar/04-lexical.md#literals).
