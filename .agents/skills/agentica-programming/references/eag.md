# EAG templates (`<<~EAG`, `std/eag`)

EAG is Agentica's ERB: a heredoc with ERB tags, checked with the code around
it, with no `eval`. The file must `import EAG from "std/eag"` (any import form;
`CHECK-EAG-IMPORT`).

```agentica
import EAG from "std/eag"

def page(names: List[String]) -> String
  return <<~EAG
    <ul>
    <% for name in names %>
      <li><%= EAG.html_escape(name) %></li>
    <% end %>
    </ul>
  EAG
end
```

```text
EAG.html_escape(value: String) -> String   # & < > " ' ; Ruby's ERB::Util.html_escape
```

- `<%= code %>` inserts `code` as `"#{code}"` does. Output is raw, as in ERB:
  escape HTML yourself with `EAG.html_escape`.
- `<%== code %>` inserts raw. `<%@ escape &F %>` alone on the first line
  gives the template an escaper, `F: Fn[String, String]` (as
  `&EAG.html_escape`): then every `<%= %>` is escaped and `<%==` is the way to
  insert raw text. A wrong type is `CHECK-TYPE-MISMATCH`; a bad, late or second
  directive is `PARSE-EAG-DIRECTIVE`.
- `<% stmt %>`: `if/elsif/else/for/while/case/end` or any statement. A tag
  must close its blocks (`PARSE-EAG-BLOCK`). A template is a block, so a tag
  cannot assign a variable of the function (`CHECK-CAPTURED-ASSIGNMENT`): use
  a variable made in the template, or build the value before. Output cannot
  be written from a block in a tag either: `<% items.each do |i| %>` with
  `<%= i %>` is `CHECK-CAPTURED-ASSIGNMENT`; loop with `for i in items`.
- `<%# note %>` dropped; `<%%` is `<%`; `-%>` removes the next line break;
  `<%-` removes the spaces before it. A line with only one `<% %>` or `<%# %>`
  tag vanishes whole (Ruby's `trim_mode: "-"` does not do that).
- The body is raw: no `\n`, no `#{}`. A tag ends on its line
  (`PARSE-EAG-UNTERMINATED-TAG`). A template is an expression: return it, pass
  it, or call a method on it (`<<~EAG.length`).
