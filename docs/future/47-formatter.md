## 47. Code formatter (`agentica fmt`)

**Status:** built (roadmap row 7.9; phases 47a, 47b and 47c, 47.10), decided by
the owner on 2026-10-15, who answered the open questions of 47.9 on 2026-10-31.
Phase 47d waits for the language server (§43, not scheduled). The command line
contract is in [`site/content/cli.md`](../../site/content/cli.md) (`fmt`); this
section keeps the design decisions, the comment attachment and the layout rules
the goldens of `tests/fixtures/frontend/format/` check.

`agentica fmt` rewrites `.agc` files in place with one printer, written in
Agentica in `compiler/format/` (#456) on the self-hosted lexer and parser, so
there is no second grammar to keep in sync. Comments come from a side list that
the lexer keeps and are attached to nodes before layout. The layout follows the
rules the repo already followed by hand. `agentica check` enforces the width;
`fmt` does not.

### 47.1 Background

- The lexer skips a `#` line without a token; only a `##` line that starts a
  line makes a `DOC` token (§32.2). Blank lines and comment lines both give
  `NL` tokens and both count as blank for `PARSE-MISSING-BLANK-LINE`, so a
  formatter must read source spans to tell them apart.
- The tree has no grouping node: parentheses leave no trace, except that a
  `Call` records `parenthesized` (a pipe target needs it). `else` and `->` have
  no node (`IfStmt.else_body` is a list of statements). Every node has a span.
- Repo style: no tabs, trailing spaces, CRLF or `;`; two-space block indents;
  multi-line `def` headers closed by `) -> Type` on its own line, one parameter
  per line with a trailing comma; broken conditions end in `and` or `or`; split
  strings end in ` +`; method chains break with a leading dot inside
  parentheses; one entry per line with a trailing comma in map and struct
  literals; no trailing comments after code.
- The files `builtins_data.agc`, `check_tables.agc` and `unicode_table.agc` are
  ordinary source, edited by hand (AGENTS.md).
- `max_line_width = 119` is set in `compiler/agentica.toml` and
  `stdlib/agentica.toml` (PR #280); with no `[style]` there is no limit (§45.5).

### 47.2 Goal and scope

The CLI forms (`fmt [PATH...]`, `--check`, `-`, `--tree FILE`) and their exit
codes are in `site/content/cli.md`; a usage error is `FMT-USAGE`, modeled on
`QUERY-USAGE`, and a bad `[style]` value is `PKG-MANIFEST-INVALID`. Rules:

- Settings come from the nearest `agentica.toml` upward; only `[style]
  max_line_width` and `blank_line_after_end` exist (§45.5). With
  `blank_line_after_end` on, `fmt` adds the empty line after every bare `end`
  that `CHECK-BLANK-LINE-AFTER-END` asks for, and none at the end of the file.
- **Width is not fmt's job.** `fmt` never breaks an identifier, a string word
  or a URL, so output can have a long line; `agentica check` reports it as
  `CHECK-LINE-TOO-LONG` (§45.5). `fmt --check` covers layout only.
- **Idempotent:** `fmt(fmt(x)) == fmt(x)`. **Meaning-preserving:** the normal
  form of the tree before and after is equal (47.7) and every comment keeps its
  words, in source order.
- **Parse only:** the lexer and the parser, as `agentica doc` does (§32.5); a
  file with a `CHECK-` error still formats; a file that does not parse is
  refused.
- Output is UTF-8 with LF, a final newline and no trailing spaces.

### 47.3 Where it lives

`compiler/format/`: the driver takes text and returns text or a diagnostic; the
comment list and its attachment (47.4), the document type and the fit check
(47.5), and the layout (one function per node kind) are separate files.
### 47.4 Comments: the hard part

A plain comment never reaches the tree today, so the design has to put comments
back.

**What other formatters do:** Prettier attaches each comment after parsing to
its enclosing, preceding or following node (own-line: leading on the following
node, else trailing on the preceding; end-of-line: trailing on the preceding
first; else dangling on the enclosing). syntax_tree (Ruby) is simpler: inline
is trailing on the preceding node, own-line is leading on the following. gofmt
attaches nothing: its printer keeps an indexed comment list and writes the
comments before each token, so every layout decision must know where comments
fall. rustfmt keeps comments as written by default.

**Options:**

- A. Comments as tokens, skipped by the parser: changes every token and parser
  golden and puts a skip into every rule.
- B. A side list: the lexer returns the comments next to the tokens, each with
  span, text and an own-line flag; the token stream and the AST do not change.
- C. Comment nodes in the AST: the checker, lowering and bytecode would see
  them. Rejected.
- D. gofmt's method: no attachment, the printer interleaves comments by
  position.
**Recommendation: B, with the attachment rules of Prettier and syntax_tree.**

- The parser, checker, lowering and bytecode see the tree they see today. The
  doc-comment side table of §32.4 is the precedent: `##` lines already live
  beside the AST.
- Existing goldens do not move. The comment list comes from a second entry
  point, `lex_with_comments`, and plain `lex` and `parse` keep their output.
- Each comment ends on one node with one role (leading, trailing or dangling).
  The layout rules stay local, and each role gets its own test. With D, every
  width decision would depend on comment positions.
- If attachment grows too many special cases, D is the fallback. Phase 47a
  records the choice.

**Attachment (proposal).** The pass runs on the tree and the token list, before
any layout:

1. For each plain comment, find the enclosing node (the deepest node whose span
   contains it), the preceding node (the closest sibling that ends before it)
   and the following node (the closest sibling that starts after it). The
   keywords that have no node (`else`, `->`, `do`, `end`) are found in the token
   list, so their position is known.
2. An own-line comment (only blanks before it on its line) is leading on the
   following node. If there is none, it is trailing on the preceding node. If
   there is none, it is dangling on the enclosing node.
3. An end-of-line comment (code before it on its line) is trailing on the
   preceding node. If there is none, it is leading on the following node. If
   there is none, it is dangling on the enclosing node.
4. A dangling comment is printed inside the enclosing brackets or body, on its
   own line, as in an empty list or an empty `def` body. A dangling comment
   before `else` or `end` carries the keyword it precedes.

The positions that rules 2 and 3 get wrong are fixed by the list below, one
position per line: where the comment sits; how it is attached; how it is
printed.

- before the module doc; leading on the module doc; above the `##` block.
- after the module doc, before the next item; trailing on the module doc (own
  line); the blank line the grammar needs stays, and a `#` line right after the
  doc is valid only after that blank line (`PARSE-DETACHED-DOC` otherwise).
- a comment-only file, or after the last item; dangling on the program, or
  trailing on the last item; in order, at column 0, after the last item.
- before `elsif` or `else` of an `if`; dangling on the `IfStmt`, tagged with
  that keyword; at the `if` indent, just before the keyword.
- before `end` of an `if`, or of a block; trailing on the last statement of the
  last body (own line); on its own line, at the body indent.
- after `else`, with an empty `else` body; dangling on the `IfStmt`, tagged
  `else`; after `else`, indented.
- between `case` arms; leading on the next `CaseArm`; above the arm, at the arm
  indent.
- after `->` on an arm line; trailing on the arm pattern (end of line); at the
  end of the arm's first line.
- after `do |x|`; trailing on the last `BlockParam` (end of line), or leading on
  the first statement when there is no parameter; at the end of the `do` line,
  or above the first statement.
- between `def` parameters; leading on the next `Param`, or trailing on the
  previous; one parameter per line.
- after `) -> Type`; trailing on the result `TypeRef` (end of line); at the end
  of the header line.
- between struct fields or enum variants; leading on the `FieldDecl` or
  `EnumVariant`; above it, and a doc block stays directly above its
  declaration.
- after a `struct` or `enum` header (`struct S # note`); leading on the first
  `FieldDecl` or `EnumVariant` (rules 2 and 3 give it); above that member, at
  the member indent.
- before a closing bracket of a call, list, map or struct literal; trailing on
  the last element (own line); on its own line after it, and the comma goes
  before the comment.
- after a map key, before the value; trailing on the `MapEntry`'s key (end of
  line); at the end of the entry's line.
- between the lines of a method chain; trailing on the previous call (own
  line); on its own line after it, and a golden of 47b checks it.
- inside an empty `[]`, `{}` or `()`; dangling on the literal; on own lines
  inside.

Own-line trailing comments are printed at the indent of the node they follow,
not at their source column. That is the one place where the output does not
keep the author's indent.

**Placement is decided before layout.** A trailing comment has a width. The pass
measures the smallest node that contains the comment and starts on its line
(flat width, indent and comment). If that fits the comment stays trailing; if
not it becomes own-line and leading on that node. The measure reads only the
tree, so a second pass makes the same choice. Comments print in source order
(47.7).

**Blank lines.** Between two consecutive items (a node or a comment) the output
keeps a blank line if the source had one, at most one, and never adds one. After
a module doc, the blank line the grammar requires is kept.

### 47.5 Layout rules and the printer

The rules take the hand-made style of 47.1 and make it exact. Each one is a
proposal, to be confirmed by the goldens of phase 47b.

1. **Statements and indent.** One statement per line. The newline separates
   statements (`docs/grammar/04-lexical.md`). Two spaces per block level. A
   continuation line is indented two spaces more than the line that starts it.
   Tabs and trailing spaces are removed.
2. **Calls and lists.** On one line if the whole item fits, counting the indent
   and the text that follows it on the line (such as `)` or `,`). Otherwise one
   item goes on each line, indented two spaces, with a trailing comma. The
   closing bracket goes on its own line at the indent of the opening line.
3. **`def` headers.** On one line if they fit. Otherwise one parameter goes on
   each line, indented two spaces, with a trailing comma after the last one, and
   `) -> Type` goes on the closing line.
4. **Parentheses.** The printer chooses grouping parentheses from the tree. It
   adds them where precedence needs them, such as `(x |> f()).unwrap!`, where
   the precedence follows `docs/grammar/05-syntax.md`. It adds them around a
   long boolean or arithmetic expression that is broken (rule 7). It drops the
   author's other grouping parentheses, because the tree does not record them.
   It never adds or removes the parentheses of a call: `f()` and `puts x` keep
   their form, and a pipe target keeps the parentheses it needs. A pipe chain
   broken over lines goes in parentheses, with each `|>` at the start of its
   line, as the repo writes it. 47b also keeps clarity parentheses that
   precedence does not need: an `and` inside an `or`, a comparison inside
   another (`(a > b) == (b > n)`), two different operators of `*`, `/`, `%`,
   and a binary operand of a range (`0...(n - 1)`).
5. **Long strings.** A string that fits stays whole. Otherwise it becomes `(`,
   then pieces, one per line, joined by ` +` at the line ends, then `)`. The
   pieces come from a `fill` (below): whole words, packed up to the width. The
   printer copies the source text of the string, so the escapes stay as the
   author wrote them. It splits only at spaces of text parts, never inside an
   escape or an interpolation, and nested quotes stay (`"#{xs.join(", ")}"`,
   PR #284). Never one piece per line. 47b does not split strings yet: a lone
   string that does not fit after `x =` or `return` moves into `(` ... `)` on
   its own line, and a longer one stays one word.
6. **Blank lines and comments.** The rule of 47.4 for blank lines. A plain
   comment is kept word for word. A `#` line longer than the width is wrapped at
   words into more `#` lines (question 6 in 47.9).
7. **Long boolean and arithmetic.** Wrap the expression in parentheses and break
   after each operator, with the operator at the end of the line. The next
   operand goes on the next line, indented two spaces. Inside brackets (a
   positional argument, a list element) there are no added parentheses and no
   extra indent; a named argument or a map value counts as outside brackets.
8. **Doc comments.** A `##` block keeps its lines as written. Only a paragraph
   that has a line over the width is re-flowed, and only that paragraph.
   Paragraphs are separated by empty `##` lines. The room is `max_line_width`
   minus 3 minus the indent of the declaration, because a field or variant doc
   sits inside its struct or enum. Headings, list items, quotes, tables and
   fenced code (including ```` ```agentica ```` blocks) keep their lines as
   written. `agentica doc` and `help` print the text with the `##` markers
   removed (§32.3, §32.5), so keeping the lines as written keeps that output
   unchanged.
9. **Order.** Imports, declarations and functions keep their order. Declaration
   order is a checker rule (`CHECK-DECL-ORDER`), so fmt never moves a
   declaration.
10. **Method chains.** A chain that fits stays on one line. Otherwise the whole
    chain goes in parentheses, the first receiver on the first line, and each
    following call on its own line, starting with `.` and indented two spaces.
    That form is the one the repo uses. A chain breaks so only with two calls
    or more, and the first call stays on the first line when the receiver is a
    plain name (`text.replace(...)`). A trailing `do` block goes on the last
    call's line.
11. **Calls with a `do` block.** The block is the last argument. The header
    `call(args) do |params|` is one line when it fits, and the header counts in
    the fit. When the arguments break, the closing line is `) do |params|`. The
    body is indented two spaces, and `end` sits at the indent of the line where
    the call starts. A body of one simple statement that fits stays on the
    header line (`do |x| x + 1 end`), and so does the body of a case arm
    (`pattern -> statement`, 47.6).
12. **`if`, `elsif` and `while` conditions.** On one line if they fit. Otherwise
    `if (` on its own line, one operand per line with each operator at the end
    of its line, `)` on its own line at the indent of `if`, and the body
    indented two spaces. `while` takes the same form.
13. **Assignment right-hand sides.** A right-hand side that fits stays on the
    line. Otherwise it breaks inside its own brackets: a call or a list as in
    rule 2, a map or struct literal as in rule 14, and a bare boolean or
    arithmetic expression in parentheses as in rule 7.
14. **Map and struct literals.** `{` or `Type(` ends the line. Each entry or
    argument goes on its own line, indented two spaces, with a trailing comma.
    The closing `}` or `)` sits at the indent of the line that starts the
    literal. A list or map that is the only argument of a call hugs its
    parentheses (`Set.new([` ... `])`). A table of atoms (literals, names,
    dotted names) that the author packed several to a line is refilled up to
    the width; one written one item per line stays so.
15. **Struct and enum declarations.** The header is one line. Each field or
    variant goes on its own line, indented two spaces, with no comma, since the
    grammar has none there. A doc block sits directly above its field or
    variant, and a blank line separates declarations.

**What the formatter does not do:** reorder or rename imports, declarations or
functions; remove unused code (checker errors, §26); change literal text
(quotes, escapes, number spelling; question 2 of 47.9); rewrite expressions
(only the grouping parentheses that the tree does not record are chosen, rule
4); split a word (a long identifier, string word or URL stays long and `check`
reports it); change a string or heredoc body (kept byte for byte).

**The printer.** A Wadler-style "prettier printer" ("A prettier printer", *The
Fun of Programming*, 2003). The layout builds a document from the tree: text; a
soft break (a space when its group is flat, else a newline, with indentation);
a group, flat when its flat text fits the rest of the line, including the text
after it such as `)` and `,`; a hard break, for blank lines; a line suffix,
which holds a trailing comment and writes it at the next newline (so `(x # c`
followed by `+ 1)` prints as `x + # c` and the operator stays in the code); a
break-parent, which a comment or hard break adds and which forces every group
around it to break; and a `fill`, which packs items greedily up to the width
(the pieces of a long string, rule 5, and the words of a re-flowed doc
paragraph). The output depends only on the tree, its comments and the placement
of 47.4, so it parses back to the same tree and a second pass gives the same
text (47.7).
### 47.6 Later syntax

Each syntax change after the bootstrap changes the printer in the same PR: a
node without a layout rule makes fmt refuse the file with `FMT-UNSUPPORTED` (a
proposal) and never guess. Heredocs `<<~NAME` are printed byte for byte,
including their indent, and are a hard break, so the enclosing call is laid out
as a broken one; the width counts only the `<<~NAME` line. A case guard stays on
the pattern's line (the parser looks for it up to the first `->` of that line),
so a guard that does not fit is solved with a shorter condition, not a break.
Case arms with one simple statement on the arrow line stay on one line when
they fit.

### 47.7 Tests

- **The normal form.** `agentica fmt --tree FILE` prints the tree with ids,
  spans and grouping parentheses removed, a `+` chain of string pieces
  flattened, and one line per comment with its words. The **round trip**
  compares the normal form of input and output on every golden.
- **Goldens:** one case for each rule of 47.5 and each comment position of
  47.4, plus CRLF input, a comment-only file, unbreakable long strings and
  names, and heredocs.
- **Idempotence** on every golden (fast tier) and on every parsing `.agc` file
  of the repo (slow tier).
- **Independent peer** (standard library only): no tabs, no trailing spaces, LF,
  a final newline, and no line over the width except one word too long to break.
### 47.8 Phases

- **47a: comments and the side list.** `lex_with_comments`, the attachment pass
  (47.4); plain `lex` and `parse` and their goldens do not change.
- **47b: printer and `--check`.** The document type, the fit check, the layout
  rules, the driver, the goldens and `--tree`, `fmt --check` and `make
  fmt-check` in CI over `compiler/` and `stdlib/`, with the one-time reformat.
- **47c: CLI, `[style]` and the width check.** Write mode, `-`, the default
  width (question 1), the nearest manifest read with `std/toml`, exit codes,
  `FMT-USAGE`, and `CHECK-LINE-TOO-LONG` in `agentica check`, which replaces the
  layout part of `tests/test_style_line_width.py` (question 9).
- **47d: LSP "format document" (§43).** One request that returns the whole-file
  edit of `format_text`; outside the order of row 7.9, it waits for the language
  server (§43.1).

### 47.9 Decisions

Answered by the owner on 2026-10-31: every recommendation. Options not taken
are named.

1. **Width with no `[style]`:** 119 (one number across the repo, PR #280); not
   100 or 80. The check keeps "no limit" without `[style]` (§45.5), so `fmt`
   wraps at 119 where `check` does not limit: accepted.
2. **Literal text:** kept exactly as written; normalizing quotes, escapes, hex
   case or separators adds diffs no width rule asks for.
3. **Which files:** the paths named, the current folder by default, with
   `agc_libs/` skipped unless named (a vendored package is another project's
   code and the lock pins its bytes, §45.5, §45.6). `std/` is embedded, so there
   is no file to format.
4. **Trailing commas:** always after the last item of a broken list, call, map
   or `def` header (the repo's habit); the grammar note says so in 47b.
5. **A file that does not parse:** refused (exit 1, file untouched). Formatting
   the part before the error is impossible (the parser stops at the first
   error) and printing the input with a warning is not allowed (§26).
6. **Plain `#` lines longer than the width:** wrapped at words with the same
   marker. The width counts comments (§45.5), so otherwise a file `fmt` could
   wrap would fail `check`. Not re-flowed into paragraphs: that joins lines the
   author wrote apart.
7. **Generators:** settled; the Racket generators went with the Racket front
   end and the generated files are edited by hand and formatted.
8. **Printer style:** a document type with groups, line suffixes and the fit
   check (47.5); the rules nest and comments need line suffixes, which direct
   string building cannot give.
9. **Who enforces the width:** `agentica check` (`CHECK-LINE-TOO-LONG`), the one
   enforcer, which also covers the lines `fmt` cannot break; `fmt --check` covers
   layout only.

### 47.10 Implementation (row 7.9)

- [x] 47a: `Lexer.lex_with_comments` and the attachment pass
  (`compiler/format/comments.agc`), option B; goldens in
  `tests/fixtures/frontend/format/`.
- [x] 47b: the printer, `fmt --check` and `make fmt-check`
  (`compiler/format/`: `doc.agc`, `layout.agc`, `format.agc`), with the one-time
  reformat. It differs from the first text of 47.5 in: `|>` at the start of the
  line, clarity parentheses, lone strings in parentheses instead of split
  strings, refilled tables, hugged sole arguments, and one-line `do` blocks and
  case arms.
- [x] 47c: write mode, standard input, `[style]` and `CHECK-LINE-TOO-LONG`;
  with `blank_line_after_end`, the empty line after every `end`, including one
  the printer creates when it breaks a one-line `do ... end`. CI runs `make
  check-compiler`; the width of `stdlib/` stays a test
  (`tests/test_style_line_width.py`), since its files load as `std/` library
  files, which no style rule covers.

Done when: `agentica fmt` rewrites a file in place, `fmt --check` passes in CI
over `compiler/` and `stdlib/`, `agentica check` reports the width, and the
round-trip, idempotence and peer tests pass.
