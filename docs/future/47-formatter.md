## 47. Code formatter (`agentica fmt`)

**Status:** Design, not scheduled. Deferred until after the bootstrap (§35
step 8): roadmap row 7.9 and phase 28
([`docs/roadmap/28-formatter.md`](../roadmap/28-formatter.md)). The owner asked
for a plan on 2026-10-15. Everything here is a proposal except the facts in
47.1, which were checked on `origin/master` at `4baf84ec`. The open questions in
47.9 need the owner's answers before phase 47b starts.

In short: `agentica fmt` rewrites `.agc` files in place with one printer. It is
written in Agentica in `compiler/`, on the self-hosted lexer and parser.
Comments come from a side list that the lexer keeps, and they are attached to
nodes after parsing. The layout follows the rules the repo already follows by
hand.

### 47.1 Today

Checked at `4baf84ec`:

- **No formatter.** No tool reads an `.agc` file and writes it back.
  `tools/agc-format.rkt` (80 lines, `max-width` at line 16) prints the values
  that `tools/gen-builtins-data.rkt` and `tools/gen-check-tables.rkt` build for
  two generated files. A value goes on one line when it fits, and otherwise one
  item goes on each line with a trailing comma. Doc comments are wrapped at the
  same width. The tool never reads source text.
- **Width.** `compiler/agentica.toml` and `stdlib/agentica.toml` each hold
  `[style] max_line_width = 119` (PR #280, merged 2026-10-15).
  `tests/test_style_line_width.py` enforces it, and checks that the generator
  width matches the compiler manifest. No other folder has a manifest. With no
  `[style]` there is no limit (§45.5).
- **Plain comments are dropped.** The lexer skips a `#` line without making a
  token: `src/lexer.rkt:232` and `compiler/lexer.agc:102-110`. Only a `##` line
  that starts a line makes a `DOC` token (`src/lexer.rkt:229`,
  `compiler/lexer.agc:103`). A `##` after code is an ordinary comment (§32.2).
- **Blank and comment lines look alike to the tokens.** The lexer emits one `NL`
  for each newline outside brackets, "including blank and comment lines"
  (`docs/grammar/04-lexical.md`). A blank line and a comment line both count as
  blank for `PARSE-MISSING-BLANK-LINE` (`docs/grammar/05-syntax.md`, checked at
  `src/parser.rkt:327`). A formatter that must tell them apart has to read
  source spans, not the `NL` tokens.
- **Every AST node has a span.** The step-2 text form of the tree
  (`tests/fixtures/frontend/parser/*.ast`) prints each node with an id and a
  span, for example `call #4 40:3:5-47:3:12 name="puts"`. Removing the id and
  the span leaves the shape, which the tests of 47.7 compare.
- **Repo style, measured** over the 115 `.agc` files of `compiler/`, `stdlib/`
  and `examples/` (counts from `rg`, so they are approximate):
  - no tabs, trailing spaces, CRLF lines or `;`. Block bodies are indented two
    spaces. The only odd indents are six aligned continuation lines in
    `stdlib/test/` (`stdlib/test/report.agc:90`), which a hanging-indent printer
    does not produce;
  - 72 multi-line `def` headers, each closed by `) -> Type` on its own line.
    Most parameters take one line each (274 lines with one parameter, against 28
    lines with several), but `compiler/lower_stmt.agc:26` packs five;
  - a trailing comma after the last parameter of a broken header, as in
    `compiler/parse_text.agc:240`;
  - 74 code lines end in `and` or `or` (`compiler/resolve.agc:90-92`), and 52
    end in ` +`, the pieces of a split string (PR #284);
  - no heredocs and no trailing comments after code. There are 484 plain `#`
    lines and 895 `##` lines in `compiler/`, and four files have two blank lines
    in a row.
- **Generated files are not edited by hand.** `compiler/builtins_data.agc` and
  `compiler/check_tables.agc` say to change `src/` and run the generator. Both
  generators require `../src/` (`tools/gen-builtins-data.rkt:12-14`), so they
  cannot run once step 8 removes the Racket front end (question 7 in 47.9).
- **`std/toml` has landed** (`stdlib/toml.agc`; the roadmap says it landed
  before the bootstrap). A formatter can read `[style]` with it, as §45.5 plans
  for `agentica check`.
- **Corpus size:** 76 `.agc` files in `compiler/` (a flat folder), 12 in
  `stdlib/`, 27 in `examples/`, and 847 under `tests/fixtures/`.

### 47.2 Goal and scope

- `agentica fmt [PATH...]` rewrites each `.agc` file in place. A PATH is a file
  or a folder, which is searched for `.agc` files. With no PATH, the current
  folder is used.
- `agentica fmt --check [PATH...]` writes nothing. It prints the files that
  would change, one per line, and exits 1 if there are any, or 0 if there are
  none. It replaces `tests/test_style_line_width.py` in CI (47c).
- `agentica fmt -` reads one file from standard input and writes the result to
  standard output. This is for editors and for the LSP (§43, phase 47d).
- Settings come from the nearest `agentica.toml`, searched upward from the
  file's folder. Only `[style] max_line_width` exists today (§45.5). Later style
  keys go in the same table.
- **Idempotent:** `fmt(fmt(x)) == fmt(x)` for every input the printer accepts.
- **Meaning-preserving:** the tree before and after is equal apart from spans
  and node ids, and every comment keeps its words in the same order (47.7).
- **Parse only.** It runs the lexer and the parser, not the linker or the
  checker, as `agentica doc` does (§32.5). A file with a `CHECK-` error still
  formats. A file that does not parse is refused (question 5 in 47.9).
- Output is UTF-8, with LF newlines, a final newline and no trailing spaces.
- Exit codes follow §39: 1 means "fix the file" (a parse error, or `--check`
  found changes), and 2 means "fix the call" (an unknown path or a bad option).
  A usage error is `FMT-USAGE`, a proposal modeled on `QUERY-USAGE`. No other
  new code is needed. A bad `[style]` value is `PKG-MANIFEST-INVALID` (§45.5).

### 47.3 Where it lives

- It is written in Agentica in `compiler/`, after step 8 of §35.4. It reuses the
  self-hosted lexer (`compiler/lexer.agc`) and parser (`compiler/parser.agc`).
  That is why it waits. With one parser there is no second grammar to keep in
  sync. Before step 8 the front end is Racket, and row 7.2.7 freezes it: `src/`
  takes no new syntax. A Racket formatter would be a second parser in that
  frozen tree.
- Step 8 ports the CLI driver (§35.4), so the subcommand goes into the Agentica
  CLI. These files are proposed, flat like the other stages in
  `compiler/`:
  - `compiler/format.agc`: the driver, text in and text or a diagnostic out;
  - `compiler/format_comments.agc`: the comment list and its attachment (47.4);
  - `compiler/format_doc.agc`: the document type and the fit check (47.5);
  - `compiler/format_layout.agc`: one function per node kind.

### 47.4 Comments: the hard part

A plain comment never reaches the tree today, so the design has to put comments
back. The rules below were checked on 2026-10-15 against each source named.

**What other formatters do:**

- **Prettier** attaches comments to nodes after parsing. For each comment it
  finds the enclosing, preceding and following node, then classifies the comment
  as own-line, end-of-line or other. An own-line comment becomes a leading
  comment of the following node, or else a trailing comment of the preceding
  node. An end-of-line comment becomes trailing on the preceding node first. A
  comment with nothing to attach to is dangling on the enclosing node
  (`src/main/comments/attach.js`).
- **syntax_tree** (Ruby) does the same more simply. `attach_comments` in
  `lib/syntax_tree/parser.rb` takes the preceding, enclosing and following
  sibling of each comment. An inline comment is trailing on the preceding node,
  and an own-line comment is leading on the following node. The program is the
  last resort.
- **gofmt** (`go/printer`) attaches nothing. Its printer keeps the comment list
  with an index, and before each token it writes the comments that come before
  it, using their positions for line breaks and blank lines
  (`intersperseComments`, `writeCommentPrefix`). It is simple, but every layout
  decision has to know where the comments fall.
- **rustfmt** keeps comments as written by default. `wrap_comments`,
  `normalize_comments` and `format_code_in_doc_comments` all default to false,
  and wrapping skips Markdown header comments and comments with a URL
  (`Configurations.md`).
- **rubyfmt** was not checked for this plan.

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

**Attachment rules (proposal, `format_comments.agc`):**

1. For each plain comment, find the enclosing node (the deepest node whose span
   contains it), the preceding node (the closest sibling that ends before it)
   and the following node (the closest sibling that starts after it).
2. An own-line comment (only blanks before it on its line) is leading on the
   following node. If there is none, it is trailing on the preceding node. If
   there is none, it is dangling on the enclosing node.
3. An end-of-line comment (code before it on its line) is trailing on the
   preceding node. If there is none, it is leading on the following node. If
   there is none, it is dangling on the enclosing node.
4. A dangling comment is printed inside the enclosing brackets or body, on its
   own line, as in an empty list or an empty `def` body.
5. A `##` block is not a plain comment. The parser already gives it to its
   declaration (§32.4), and fmt prints it from there. A plain comment cannot sit
   between a doc block and its declaration (`PARSE-DETACHED-DOC`), so a leading
   plain comment always goes above the doc block.
6. A trailing comment that does not fit on its line moves above its node, on its
   own line at the node's indent. This is stable: a re-parse attaches an
   own-line comment to the same node, so the second pass prints the same text.

**Blank lines and comments.** The author's blank lines are kept, at most one in
a row. A blank line between a comment and the node it belongs to is removed,
because the comment then belongs to that node. No blank line is added or removed
between two items. The input already satisfies the blank-line rules of
`docs/grammar/05-syntax.md`.

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
   `) -> Type` goes on the closing line (`compiler/parse_text.agc:232-241`).
4. **Long boolean and arithmetic.** Wrap the expression in parentheses and break
   after each operator, with the operator at the end of the line
   (`compiler/resolve.agc:90-92`). The next operand goes on the next line,
   indented two spaces.
5. **Long strings.** A string that fits stays whole. Otherwise it becomes `(`,
   then pieces, one per line, joined by ` +` at the line ends, then `)`. Each
   piece is whole words up to the width, split the way `pieces` in
   `tools/agc-format.rkt:35` splits text. Interpolations are never split, and
   nested quotes stay (`"#{xs.join(", ")}"`, PR #284). Never one piece per line.
6. **Blank lines.** At most one in a row. Kept where the author wrote them
   (47.4).
7. **Plain comments.** Kept word for word. A `#` line longer than the width is
   wrapped at words into more `#` lines (question 6 in 47.9).
8. **Doc comments.** Each `##` block is re-flowed to the width. Paragraphs,
   which are separated by empty `##` lines, are joined and wrapped at words to
   `max_line_width - 3` characters after `## `. That is the room `doc-comment`
   uses in `tools/agc-format.rkt:69`. Headings, list items, quotes, tables and
   fenced code (including ```` ```agentica ```` blocks) keep their lines as
   written.
9. **Order.** Imports, declarations and functions keep their order. Declaration
   order is a checker rule (`CHECK-DECL-ORDER`), so fmt never moves a
   declaration.

**What the formatter does not do:**

- no reordering of imports, declarations or functions, and no renaming;
- no removal of unused code or imports, which are checker errors (§26);
- no change to literal text, such as quotes, escapes or number spelling
  (question 2 in 47.9);
- no rewriting of expressions: `x.size == 0` stays as it is;
- no splitting of a word. A long identifier or string word stays long, and the
  width check reports it, not fmt;
- no change inside a string or a heredoc body. The text is kept byte for byte.

**The printer.** A Wadler-style "prettier printer" (Wadler, "A prettier
printer", in *The Fun of Programming*, 2003), in the same family as Oppen's
pretty printing and Prettier's doc IR. The layout builds a document from the
tree. It has text, a soft break that is a space when its group fits and a
newline when it does not, indentation, and a hard break for comments and for
blank lines. A group is flat when its flat text fits in the rest of the line.
The rest includes the text after the group, such as the `)` and `,` of an item,
which `render` in `tools/agc-format.rkt` already counts as `trailing`. A hard
break inside a group forces the group to break. The output depends only on the
tree and its comments, so it parses back to the same tree, and a second pass
gives the same text (47.7).

### 47.6 Later syntax

Each syntax change after the bootstrap changes the printer in the same PR. That
is the rule for this plan: a node without a layout rule makes fmt refuse the
file with `FMT-UNSUPPORTED` (a proposal), and it never guesses.

- **Heredocs `<<~NAME`** (§25.10, roadmap 15j, not built; there is no heredoc in
  the repo today). The body is printed byte for byte, including its indent, and
  the end line stays where it is. A heredoc is a hard break, so the enclosing
  call is laid out as a broken one. The width counts only the `<<~NAME` line.
  The printer rule ships with 15j.
- **Case guards and nested patterns** are not supported today
  (`docs/grammar/06-semantics.md:71`). They are planned only as §25.12.1, "to
  evaluate later", with no phase. A PR that adds them adds their layout rule and
  a golden.
- **Pipe chains** that run over lines stay in parentheses
  (`docs/grammar/04-lexical.md:33`). The `|>` goes at the end of the line, as
  the operator rule of 47.5 says.
- **`case` arms** with one simple statement on the arrow line stay on one line
  when they fit (`docs/grammar/06-semantics.md:71`).

### 47.7 Tests

- **Goldens** (fast tier): `tests/fixtures/fmt/NAME.input` and `NAME.output`,
  one pair for each rule of 47.5 and each comment role of 47.4. They cover a
  comment in each role, a call and a `def` that break, a long boolean, a long
  string, a doc block with a fenced code example, and blank lines. The heredoc
  goldens come with 15j.
- **Round trip** (fast tier, for every golden): `parse(fmt(x))` equals
  `parse(x)` in the step-2 text form, with the span and the node id removed
  (`tests/fixtures/frontend/parser/*.ast`). The words of every comment are also
  equal and in the same order. This catches a printer that drops a parenthesis,
  changes an operator or splits a word.
- **Idempotence:** `fmt(fmt(x)) == fmt(x)` on every golden (fast tier), and on
  every `.agc` file under `compiler/`, `stdlib/` and `examples/` (slow tier, run
  by `make test-slow` in CI, as the live corpus).
- **Independent peer** (fast tier, standard library only, Python `unittest`). It
  checks the output without the Agentica parser: no tabs, no trailing spaces,
  LF newlines, a final newline, and no line over the width except a line that is
  one word too long to break.
- **Refusal and CLI** (fast tier, hermetic: temporary folders, cleaned up). A
  lexer error and a parser error exit 1 with their code and leave the file
  alone. `--check` exits 1 and lists the changed files. `-` reads standard
  input.
- **Corpus check in CI:** `fmt --check compiler stdlib` replaces
  `tests/test_style_line_width.py` (47c). The one-time reformat of `stdlib/`
  moves line numbers in the `std/` stack-trace goldens, so that PR runs
  `make goldens`.

### 47.8 Phases

Roadmap phase 28 ([`docs/roadmap/28-formatter.md`](../roadmap/28-formatter.md))
holds the checklist.

- **47a: comments and the side list.** `lex_with_comments` in
  `compiler/lexer.agc`, the attachment pass in `compiler/format_comments.agc`,
  and tests of the (node, role) table for a set of inputs. Plain `lex` and
  `parse` do not change, so their goldens do not move. No user-visible change.
- **47b: printer and `--check`.** The document type, the fit check, the rules of
  47.5 and the driver. It adds the goldens and round-trip tests of 47.7 (fast
  tier), and the `fmt` subcommand with `--check` only, with `make fmt-check`
  run by CI over `compiler/` and `stdlib/`. The one-time reformat of what it
  changes goes in the same PR. It needs 47a. Heredocs wait for 15j.
- **47c: the CLI and `[style]`.** Write mode, `-` for standard input, the
  default width of question 1, the nearest manifest read with `std/toml`, the
  exit codes of 47.2, `FMT-USAGE`, and the refusal of a file that does not
  parse. It removes `tests/test_style_line_width.py` with its generator check.
  Question 7 decides what the two generated files become. It adds a CHANGELOG
  entry under `[Unreleased]` and a site page for the command.
- **47d: LSP "format document" (§43).** One request that returns the whole-file
  edit of `format_text`. It waits for the LSP, which is not scheduled.

Each phase has its own PR, with its own tests and docs. 47b needs 47a, and 47c
needs 47b.

### 47.9 Open questions

Each question has options and a recommendation.

1. **Width when there is no `[style]`.** Options: (a) 119, the width of
   `compiler/` and `stdlib/`; (b) 100, rustfmt's default; (c) 80, Prettier's
   default. **Recommendation:** (a), one number across the repo and the owner's
   choice in PR #280. The check keeps "no limit" without `[style]` (§45.5), so a
   project with no manifest would be wrapped at 119 by `fmt` but not limited by
   the check. The owner should accept that difference, or ask for the check to
   use 119 too.
2. **Literal text.** Options: (a) keep each literal exactly as written; (b)
   normalize quotes, escapes, hex case or digit separators (§33).
   **Recommendation:** (a). Literals have no layout, and changing them adds
   diffs that no width rule asks for. The tree test stays exact.
3. **Which files.** Options: (a) only the paths named, the current folder by
   default, with `agc_libs/` skipped unless it is named; (b) also format the
   vendored code under `agc_libs/`. `std/` is embedded in the binary, so there
   is no file to format. **Recommendation:** (a). A vendored package is another
   project's code, and the lock pins its bytes (§45.5, §45.6). The repo's own
   `stdlib/` is checked by CI, not formatted by users.
4. **Trailing commas.** Options: (a) always after the last item of a broken
   list, call, map or `def` header; (b) never; (c) only where the grammar text
   says so. **Recommendation:** (a), the repo's habit. The grammar text mentions
   trailing commas only for lists and calls (`docs/grammar/04-lexical.md:11`). A
   `def` header in `compiler/parse_text.agc:240` has one, and the bootstrap
   compiles that file. The grammar note should say so in 47b.
5. **A file that does not parse.** Options: (a) refuse: exit 1 with the lexer or
   parser diagnostic, the file untouched, and `--check` the same; (b) format the
   part before the error, which is not possible, because the parser stops at the
   first error; (c) print the input unchanged with a warning, which §26 does not
   allow. **Recommendation:** (a).
6. **Plain comment lines longer than the width.** Options: (a) keep them, as
   rustfmt does by default; (b) wrap them at words, with the same `#` marker, as
   doc comments are wrapped; (c) re-flow runs of comment lines into paragraphs.
   **Recommendation:** (b). The width counts comments (§45.5), so `--check`
   could not pass on a file that the printer could wrap. Option (c) joins lines
   the author wrote apart, which a formatter should not do.
7. **What replaces the two generators.** Options: (a) after step 8 the two
   generated files are ordinary source, edited by hand and formatted by fmt, and
   their header comments say so; (b) a generator written in Agentica writes the
   same files; (c) keep the Racket generators, which needs `src/`, so it is not
   possible after step 8. **Recommendation:** (a) when step 8 lands. Choose (b)
   only if the catalog changes often enough to need a tool. The owner decides in
   47c.
8. **Printer style.** Options: (a) a document type with groups and the fit check
   (47.5); (b) direct string building per node, as `render` in
   `tools/agc-format.rkt` does. **Recommendation:** (a). The rules of 47.5 nest
   (a call inside a string inside a `def`), and the fit check must see the text
   that follows a group. Option (b) is enough for the two generated files, which
   have two shapes.
