## Phase 23: Digit separators

The lexer rules are in the grammar's
[literal section](../grammar/04-lexical.md#literals). Phase 23 is front end
only: the lexer and the docs. The token value does not change, so the AST, the
checker, lowering and the VM stay as they are. It took one PR (order step 7.2a).

**Done:** `_` between digits in number literals (lexer and docs only).
Record: the grammar's
[literal section](../grammar/04-lexical.md#literals).
