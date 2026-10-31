## 47. Code formatter (`agentica fmt`)

**Status:** In progress: roadmap row 7.9, decided by the owner on 2026-10-15,
who also asked for this plan on the same day. Phase 47a is done (47.10). The
owner answered the open questions of 47.9 on 2026-10-31. Phase 47d waits for
the language server (§43), which is not scheduled.

In short: `agentica fmt` rewrites `.agc` files in place with one printer. It is
written in Agentica in `compiler/`, on the self-hosted lexer and parser.
Comments come from a side list that the lexer keeps, and they are attached to
nodes before layout. The layout follows the rules the repo already follows by
hand. `agentica check` enforces the width, and `fmt` does not.

### 47.1 Today

- **No formatter.** No tool reads an `.agc` file and writes it back.
- **Width.** `compiler/agentica.toml` and `stdlib/agentica.toml` each hold
  `[style] max_line_width = 119` (PR #280).
  `tests/test_style_line_width.py` enforces it. No other folder has a manifest.
  With no `[style]` there is no limit (§45.5).
- **Plain comments are dropped.** The lexer skips a `#` line without making a
  token. Only a `##` line that starts a line makes a `DOC` token. A `##` after
  code is an ordinary comment (§32.2).
- **Blank and comment lines look alike to the tokens.** The lexer emits one `NL`
  for each newline outside brackets, "including blank and comment lines"
  (`docs/grammar/04-lexical.md`). A blank line and a comment line both count as
  blank for `PARSE-MISSING-BLANK-LINE` (`docs/grammar/05-syntax.md`). A
  formatter that must tell them apart has to read source spans, not the `NL`
  tokens.
- **The tree has no grouping node.** Parentheses around an expression leave no
  trace in the AST. A call does record whether it had parentheses (`Call`,
  `parenthesized`), because a pipe target needs them. `else` and `->` have no
  node either: `IfStmt` has `else_body` as a list of statements, and `CaseArm`
  has a pattern and a body. Map entries (`MapEntry`), block parameters
  (`BlockParam`), fields and variants have nodes. The module doc is not a node
  (§32.4). Every node has a span.
- **Repo style** (`compiler/`, `stdlib/`, `examples/`): no tabs, trailing
  spaces, CRLF lines or `;`; two-space block indents; multi-line `def` headers
  closed by `) -> Type` on its own line with one parameter per line and a
  trailing comma; broken conditions end in `and` or `or`; split strings end in
  ` +`; method chains break with a leading dot inside parentheses; map and
  struct literals have one entry per line and a trailing comma; no trailing
  comments after code.
- **Generated files** are ordinary source: `compiler/catalog/builtins_data.agc`,
  `compiler/check/check_tables.agc` and `compiler/syntax/unicode_table.agc` are
  edited by hand (AGENTS.md).
- **`std/toml` has landed** (`stdlib/toml.agc`). A formatter can read `[style]`
  with it, as §45.5 plans for `agentica check`.

### 47.2 Goal and scope

- `agentica fmt [PATH...]` rewrites each `.agc` file in place. A PATH is a file
  or a folder, which is searched for `.agc` files. With no PATH, the current
  folder is used.
- `agentica fmt --check [PATH...]` writes nothing. It prints the files that
  would change, one per line, and exits 1 if there are any, or 0 if there are
  none. A file whose bytes differ from the output counts as changed, so a CRLF
  file is listed. It replaces the layout part of
  `tests/test_style_line_width.py` in CI (47c).
- `agentica fmt -` reads one file from standard input and writes the result to
  standard output. This is for editors and for the LSP (§43, phase 47d).
- `agentica fmt --tree FILE` prints the normal form of 47.7. It is a debugging
  flag, used by the tests.
- Settings come from the nearest `agentica.toml`, searched upward from the
  file's folder. Only `[style] max_line_width` and `blank_line_after_end` exist
  today (§45.5). Later style keys go in the same table. When
  `blank_line_after_end` is on, `fmt` must add the empty line after every bare
  `end` that `CHECK-BLANK-LINE-AFTER-END` asks for, and add none at the end of
  the file.
- **Width is not fmt's job.** `fmt` never breaks an identifier, a string word or
  a URL, so its output can still have a long line. `agentica check` reports
  such a line as `CHECK-LINE-TOO-LONG` (§45.5, phase 47c). `fmt --check` covers
  layout only.
- **Idempotent:** `fmt(fmt(x)) == fmt(x)` for every input the printer accepts.
- **Meaning-preserving:** the normal form of the tree before and after is equal
  (47.7), and every comment keeps its words, in source order.
- **Parse only.** It runs the lexer and the parser, not the linker or the
  checker, as `agentica doc` does (§32.5). A file with a `CHECK-` error still
  formats. A file that does not parse is refused (question 5 in 47.9).
- Output is UTF-8, with LF newlines, a final newline and no trailing spaces.
  CRLF input becomes LF.
- Exit codes follow §39: 1 means "fix the file" (a parse error, or `--check`
  found changes), and 2 means "fix the call" (an unknown path or a bad option).
  A usage error is `FMT-USAGE`, a proposal modeled on `QUERY-USAGE`. No other
  new code is needed. A bad `[style]` value is `PKG-MANIFEST-INVALID`
  ([05b](../grammar/05b-modules.md), Packages).

### 47.3 Where it lives

It is written in Agentica in its own context folder `compiler/format/` (#456),
reusing the self-hosted lexer and parser, so there is no second grammar to keep
in sync. The driver takes text in and returns text or a diagnostic; the comment
list and its attachment (47.4), the document type and the fit check (47.5), and
the layout (one function per node kind) are separate files of that folder.

### 47.4 Comments: the hard part

A plain comment never reaches the tree today, so the design has to put comments
back.

**What other formatters do:**

- **Prettier** attaches comments to nodes after parsing. For each comment it
  finds the enclosing, preceding and following node, then classifies the comment
  as own-line, end-of-line or other. An own-line comment becomes a leading
  comment of the following node, or else a trailing comment of the preceding
  node. An end-of-line comment becomes trailing on the preceding node first. A
  comment with nothing to attach to is dangling on the enclosing node.
- **syntax_tree** (Ruby) does the same more simply: an inline comment is
  trailing on the preceding node, and an own-line comment is leading on the
  following node. The program is the last resort.
- **gofmt** attaches nothing. Its printer keeps the comment list with an index,
  and before each token it writes the comments that come before it, using their
  positions for line breaks and blank lines. It is simple, but every layout
  decision has to know where the comments fall.
- **rustfmt** keeps comments as written by default: `wrap_comments`,
  `normalize_comments` and `format_code_in_doc_comments` all default to false,
  and wrapping skips Markdown header comments and comments with a URL.

**Options:**

- A. Comments as tokens. The lexer emits them and the parser skips them, as it
  skips stray `NL` tokens. This changes every token and parser golden, and puts
  a skip into every rule.
- B. A side list. The lexer returns the comments in a list next to the tokens,
  each with its span, its text and an own-line flag. The token stream and the
  AST do not change, and the formatter attaches each comment to a node by span.
- C. Comment nodes in the AST. The checker, lowering and bytecode would see
  them. Rejected.
- D. gofmt's method. No attachment; the printer interleaves comments by
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

**Placement is decided before layout.** A trailing comment has a width. The
pass measures the smallest node that contains the comment and starts on the
comment's line: its flat width, the indent of its line and the comment. If that
fits in the width, the comment stays trailing. If it does not, the comment
becomes own-line and leading on that node. The measure reads only the tree, so
it does not depend on the layout it feeds, and a second pass makes the same
choice. Comments are printed in source order, so the order of their words is
kept (47.7).

**Blank lines.** One rule covers every position: between two consecutive items,
where an item is a node or a comment, the output keeps a blank line if the
source had one, at most one, and never adds one. A blank line before a comment
block stays before that block. After a module doc, the blank line that the
grammar requires is kept.

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
   broken over lines goes in parentheses, with the `|>` at the end of the line,
   as the grammar requires (`docs/grammar/04-lexical.md`).
5. **Long strings.** A string that fits stays whole. Otherwise it becomes `(`,
   then pieces, one per line, joined by ` +` at the line ends, then `)`. The
   pieces come from a `fill` (below): whole words, packed up to the width. The
   printer copies the source text of the string, so the escapes stay as the
   author wrote them. It splits only at spaces of text parts, never inside an
   escape or an interpolation, and nested quotes stay (`"#{xs.join(", ")}"`,
   PR #284). Never one piece per line.
6. **Blank lines and comments.** The rule of 47.4 for blank lines. A plain
   comment is kept word for word. A `#` line longer than the width is wrapped at
   words into more `#` lines (question 6 in 47.9).
7. **Long boolean and arithmetic.** Wrap the expression in parentheses and break
   after each operator, with the operator at the end of the line. The next
   operand goes on the next line, indented two spaces.
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
    That form is the one the repo uses. 47b checks it against the parser before
    the golden is fixed.
11. **Calls with a `do` block.** The block is the last argument. The header
    `call(args) do |params|` is one line when it fits, and the header counts in
    the fit. When the arguments break, the closing line is `) do |params|`. The
    body is indented two spaces, and `end` sits at the indent of the line where
    the call starts.
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
    literal.
15. **Struct and enum declarations.** The header is one line. Each field or
    variant goes on its own line, indented two spaces, with no comma, since the
    grammar has none there. A doc block sits directly above its field or
    variant, and a blank line separates declarations.

**What the formatter does not do:**

- no reordering of imports, declarations or functions, and no renaming;
- no removal of unused code or imports, which are checker errors (§26);
- no change to literal text: quotes, escapes and number spelling stay (question
  2 in 47.9);
- no rewriting of expressions. The tree stays the same. Only the grouping
  parentheses that the tree does not record are chosen by the printer (rule 4);
- no splitting of a word. A long identifier, a string word or a URL stays long,
  and `agentica check` reports it (47.2);
- no change inside a string or a heredoc body. The text is kept byte for byte.

**The printer.** A Wadler-style "prettier printer" (Wadler, "A prettier
printer", in *The Fun of Programming*, 2003), in the same family as Oppen's
pretty printing and the doc builders of Prettier. The layout builds a document
from the tree. Its pieces are:

- text, and a soft break that is a space when its group is flat and a newline
  when it is not, with indentation;
- a group, which is flat when its flat text fits in the rest of the line. The
  rest includes the text after the group, such as the `)` and `,` of an item;
- a hard break, for blank lines;
- a line suffix, which holds a trailing comment and writes it at the next
  newline. A naive print would write `x # c` and then the `+ 1` after it, which
  is inside the comment. With a line suffix, `(x # c` followed by `+ 1)` prints
  as `x + # c`, and the operator stays in the code;
- a break-parent, which a comment or a hard break adds. It forces every group
  around it to break, so a line suffix always ends a line;
- a `fill`, which packs items greedily up to the width. Rule 5 needs it for the
  pieces of a string: the width of each piece counts its quotes, the ` +` and
  the indent. The same `fill` packs the words of a re-flowed doc paragraph.

The output depends only on the tree, its comments and the placement of 47.4. So
it parses back to the same tree, and a second pass gives the same text (47.7).

### 47.6 Later syntax

Each syntax change after the bootstrap changes the printer in the same PR. That
is the rule for this plan: a node without a layout rule makes fmt refuse the
file with `FMT-UNSUPPORTED` (a proposal), and it never guesses.

- **Heredocs `<<~NAME`** are in the language, so 47b covers them. The body is
  printed byte for byte, including its indent, and the end line stays where it
  is. A heredoc is a hard break, so the enclosing call is laid out as a broken
  one. The width counts only the `<<~NAME` line. A heredoc token has the span of
  its opener and a lexeme that starts with `<<~`; the body stays in the file
  text.
- **Case guards and nested patterns** (`pattern if condition ->`,
  `docs/grammar/06-semantics.md`) are in the language. The guard stays on the
  line of the pattern, because the parser looks for it up to the first `->` of
  that line; a guard that does not fit is a layout the formatter has to solve
  with a shorter condition (a local name), not a line break. A nested pattern is
  printed on one line. 47b adds the layout rule and a golden.
- **`case` arms** with one simple statement on the arrow line stay on one line
  when they fit (`docs/grammar/06-semantics.md`).

### 47.7 Tests

The checks that decide the design (the case list is decided in the PRs):

- **The normal form.** `agentica fmt --tree FILE` prints the tree with ids,
  spans and grouping parentheses removed, a `+` chain of string pieces
  flattened, and one line per comment with its words. The **round trip**
  compares the normal form of the input with that of the output on every golden,
  so a printer that drops a parenthesis, changes an operator or splits a word is
  caught.
- **Goldens:** one case for each rule of 47.5 and each comment position of
  47.4, plus CRLF input, a comment-only file, unbreakable long strings and
  names, and heredocs.
- **Idempotence:** `fmt(fmt(x)) == fmt(x)` on every golden (fast tier) and on
  every `.agc` file of the repo that parses (slow tier).
- **Independent peer** (standard library only): no tabs, no trailing spaces, LF
  newlines, a final newline, and no line over the width except one word too long
  to break.

### 47.8 Phases

The checklist lives in [§47.10 Implementation](#4710-implementation-row-79)
below; there is no separate roadmap phase file.

- **47a: comments and the side list.** `lex_with_comments`, the attachment pass
  with the list of 47.4, and tests of the (node, role) pairs for a set of
  inputs. Plain `lex` and `parse` do not change, so their goldens do not move.
  No user-visible change.
- **47b: printer and `--check`.** The document type with the pieces of 47.5, the
  fit check, the layout rules, and the driver. It covers every syntax landed by
  then, heredocs included (47.6). It adds the goldens, the normal form
  (`--tree`) and the tests of 47.7 (fast tier), the `fmt` subcommand with
  `--check` only, and `make fmt-check`, which CI runs over `compiler/` and
  `stdlib/`. The one-time reformat of what it changes goes in the same PR. It
  needs 47a.
- **47c: CLI, `[style]` and the width check.** Write mode, `-` for standard
  input, the default width of question 1, the nearest manifest read with
  `std/toml`, the exit codes of 47.2, `FMT-USAGE`, and the refusal of a file
  that does not parse. The width rule of §45.5 is added to `agentica check` as
  `CHECK-LINE-TOO-LONG`, which replaces `tests/test_style_line_width.py`
  (question 9 in 47.9). The only `[style]` key is `max_line_width`.
- **47d: LSP "format document" (§43).** One request that returns the whole-file
  edit of `format_text`. It is outside the order of row 7.9, and it waits for
  the language server, which is not scheduled (§43.1).

47b needs 47a, and 47c needs 47b.

### 47.9 Open questions

Each question has options and a recommendation.

**Answered** by the owner on 2026-10-31: every recommendation, so 1(a), 2(a),
3(a), 4(a) with the grammar note in 47b, 5(a), 6(b), 8(a) and 9(a). The printer
also honors `[style] blank_line_after_end` (47.2).

1. **Width when there is no `[style]`.** Options: (a) 119, the width of
   `compiler/` and `stdlib/`; (b) 100, the rustfmt default; (c) 80, the Prettier
   default. **Recommendation:** (a), one number across the repo and the owner's
   choice in PR #280. The check keeps "no limit" without `[style]` (§45.5), so a
   project with no manifest would be wrapped at 119 by `fmt` but not limited by
   `agentica check`. The owner should accept that difference, or ask for the
   check to use 119 too.
2. **Literal text.** Options: (a) keep each literal exactly as written; (b)
   normalize quotes, escapes, hex case or digit separators.
   **Recommendation:** (a). Literals have no layout, and changing them adds
   diffs that no width rule asks for. The normal form stays exact.
3. **Which files.** Options: (a) only the paths named, the current folder by
   default, with `agc_libs/` skipped unless it is named; (b) also format the
   vendored code under `agc_libs/`. `std/` is embedded in the binary, so there
   is no file to format. **Recommendation:** (a). A vendored package is another
   project's code, and the lock pins its bytes (§45.5, §45.6). The repo's own
   `stdlib/` is checked by CI, not formatted by users.
4. **Trailing commas.** Options: (a) always after the last item of a broken
   list, call, map or `def` header; (b) never; (c) only where the grammar text
   says so. **Recommendation:** (a), the repo's habit. The grammar text mentions
   trailing commas only for lists and calls (`docs/grammar/04-lexical.md`). A
   `def` header in `compiler/syntax/parse_text.agc` has one, and the bootstrap
   compiles that file. The grammar note should say so in 47b.
5. **A file that does not parse.** Options: (a) refuse: exit 1 with the lexer or
   parser diagnostic, the file untouched, and `--check` the same; (b) format the
   part before the error, which is not possible, because the parser stops at the
   first error; (c) print the input unchanged with a warning, which §26 does not
   allow. **Recommendation:** (a).
6. **Plain comment lines longer than the width.** Options: (a) keep them, as
   rustfmt does by default; (b) wrap them at words, with the same `#` marker, as
   doc comments are wrapped; (c) re-flow runs of comment lines into paragraphs.
   **Recommendation:** (b). The width counts comments (§45.5), so a file that
   the printer could wrap would fail `agentica check`. Option (c) joins lines
   the author wrote apart, which a formatter should not do.
7. **What replaces the two generators.** Settled: the Racket generators went
   with the Racket front end, and the two generated files are ordinary source,
   edited by hand and formatted by fmt (AGENTS.md). A generator written in
   Agentica stays an option only if the catalog changes often enough to need a
   tool.
8. **Printer style.** Options: (a) a document type with groups, line suffixes
   and the fit check (47.5); (b) direct string building per node.
   **Recommendation:** (a). The rules of 47.5 nest (a call inside a string
   inside a `def`), comments need line suffixes, and the fit check must see the
   text that follows a group. Option (b) is enough only for a tool with two
   output shapes.
9. **Who enforces the width.** Options: (a) `agentica check` reports
   `CHECK-LINE-TOO-LONG`, and `fmt --check` covers layout only; (b) `fmt
   --check` also fails on an output line that is still over the width; (c) keep
   the Python test beside the checker. **Recommendation:** (a). It is the one
   enforcer, it covers the lines `fmt` cannot break (a long identifier, a URL),
   and §45.5 says the same. The owner confirms the code when 47c lands.

### 47.10 Implementation (row 7.9)

One PR per phase of 47.8, each with its own tests and docs. The §47.9 open
questions are answered; 47d waits for the language server (§43, not scheduled)
and is outside this order.

- [x] 47a: `Lexer.lex_with_comments` and the attachment pass of 47.4 in
  `compiler/format/comments.agc`, with option B (a side list); the goldens of
  `tests/fixtures/frontend/format/` print each comment's node and role. The
  width test that turns a trailing comment into a leading one needs the flat
  width of a node, so it comes with the printer in 47b.
- [ ] 47b: the printer, `fmt --check` and `make fmt-check`.
- [ ] 47c: write mode, standard input, `[style]` and `CHECK-LINE-TOO-LONG`.

Done when: `agentica fmt` rewrites a file in place, `fmt --check` passes in CI
over `compiler/` and `stdlib/`, `agentica check` reports the width, and the
round-trip, idempotence and peer tests pass.
