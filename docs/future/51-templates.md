## 51. EAG templates

**Status:** Built in 0.22.0 (roadmap row 7.13). EAG, "Embedded AGentica", is
Agentica's ERB, as Elixir's EEx is its. The name EAG is the one exception to the
Ruby-name rule: Ruby has no heredoc form of ERB, so the Ruby name would promise
`ERB.new(text).result`, which needs `eval`. Rules, tags and diagnostics are in
the grammar ([`04-lexical.md`](../grammar/04-lexical.md#eag-templates)); the
library page is `site/content/library/text-and-data/eag.md`.

### 51.1 Decisions (owner, 2026-11-01)

- **Compile time, no `eval`.** A template is a heredoc `<<~EAG` in the code of a
  function. Its tags are checked as ordinary code, in the scope of the
  function, so a typo in `<%= user.nme %>` is `CHECK-UNKNOWN-FIELD` at the tag.
- **Ruby's tags**: `<%= %>`, `<% %>`, `<%# %>`, `<%%`, `-%>`, and `<%-`.
- **Raw output**, as ERB. HTML escaping is `EAG.html_escape(value)` from
  `std/eag` (Ruby's `ERB::Util.html_escape`), written in the tag. An escaping
  mode is a possible later step, not part of this one.
- **`<% %>` holds any statement.** Blocks (`if`, `for`, `while`, `case`) must
  close inside the template (`PARSE-EAG-BLOCK`).
- **The file imports `std/eag`** in any form, as `require "erb"`; the check is
  `CHECK-EAG-IMPORT`, as for the regex literal (48.6). Nothing is generated from
  the import: it only has to be there.
- **A template is an expression.** It works where any expression does.

### 51.2 How it works

The lexer keeps the lines of an `<<~EAG` body in one `eag` token. The parser
expands it (`compiler/syntax/eag.agc`) into the tokens of

```agentica
[0].map do |eag#n: Int|
  eag#t: List[String] = []
  eag#t = eag#t.push("text")
  eag#t = eag#t.push("#{code}")
  <statement of a tag>
  eag#t.join("")
end.first
```

and parses them on their own, so the checker, the linker and the lowering see
ordinary code and the VM does not change. The tokens of a tag come from lexing
the tag's own text again and moving the positions to where it stands in the
file, so every diagnostic about a tag has its place in the template. The block
is there because the language has no block expression and no standalone lambda;
as a block it is also an expression, its locals do not leak, and `for` and `if`
work inside it. The literal is an `Ast.EagLit` node that wraps the expression,
so the linker can ask for the import and the formatter can print the template as
written.

The two names have a `#`, which no identifier has, so a tag can neither write
them nor read them (the regex literal names its constants `regex#<id>` the same
way); the checker tells them from user names to explain two errors.

What follows from the block:

- A tag cannot assign a variable of the function
  (`CHECK-CAPTURED-ASSIGNMENT`, at the tag, with a message about the template);
  a variable made in a tag stays in the template.
- A block inside a tag cannot write output, since writing is an assignment of
  the list of pieces: `<% items.each do |i| %>` with `<%= i %>` is the same
  error, with the help to loop with `for i in items`. A way to make `each do`
  work would need a mutable cell or a block that returns its pieces; neither is
  in the language.
- A tag cannot `return` from the function.
- The cost of a template is that of the code it expands to: one list of pieces
  and one `join`.

### 51.3 Not here

- Template files and `.eag` imports; a template read at run time (it needs
  `eval`; a run-time engine over `Json` is a separate `std/` module if asked).
- Multi-line tags: a tag ends on its line.
- `%%>` for the text `%>` inside a tag, and the other trim modes of ERB
  (`%`, `<>`, `>`). `<>` is nearly the rule for a line with one tag (the next
  item).
- Escaping by default.
- `agentica type-at` and `refs` at a position inside a tag: the literal holds
  its expansion for the checker, but the query walkers do not descend into it.

### 51.4 Differences from Ruby's ERB

- Output equals ERB with `trim_mode: "-"`, except for one rule: a line that
  holds only one `<% %>` or `<%# %>` tag and spaces is removed whole (Erubi does
  the same). A template written with `-%>` and `<%-` gives the same text in
  both.
- A template is code of its function, so a variable of the function is read-only
  inside it, and Agentica's syntax applies in the tags (`for x in xs`, `end`).
