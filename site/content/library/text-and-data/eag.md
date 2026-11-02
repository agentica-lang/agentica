---
title: EAG templates (std)
weight: 11
description: The `<<~EAG` template heredoc and the std/eag module that it needs.
---

EAG ("Embedded AGentica") is Agentica's ERB: a template is a heredoc `<<~EAG` whose text has the tags of Ruby's ERB. A template is code of the file that holds it: the checker types every tag, there is no `eval`, and the result is a `String`. The file must `import EAG from "std/eag"` (any import form; `CHECK-EAG-IMPORT` without it), as Ruby needs `require "erb"`. This is the one name that is not Ruby's: Ruby has no heredoc form of ERB.

```ruby
EAG.html_escape(value: String) -> String   # ERB::Util.html_escape
```

```agentica
import EAG from "std/eag"

struct Item
  title: String
  visible: Bool
end

def page(name: String, items: List[Item]) -> String
  return <<~EAG
    <h1><%= EAG.html_escape(name) %></h1>
    <ul>
    <% for item in items %>
      <% if item.visible %>
      <li><%= EAG.html_escape(item.title) -%>
      </li>
      <% end %>
    <% end %>
    </ul>
  EAG
end

def main() -> Void
  puts(page("a<b", [Item(title: "x&y", visible: true), Item(title: "z", visible: false)]))
end
```

```output
<h1>a&lt;b</h1>
<ul>
  <li>x&amp;y  </li>
</ul>

```

- `<%= code %>` inserts the value of `code` as `"#{code}"` does (`to_s`). The output is raw, as ERB's is: nothing is escaped, so write `EAG.html_escape(...)` for HTML.
- `<% code %>` is a statement: `if`, `elsif`, `else`, `for`, `while`, `case`, `end`, or any other. The tags of a template must close their own blocks (`PARSE-EAG-BLOCK`). A template is a block of its function, so a tag cannot assign a variable of the function (`CHECK-CAPTURED-ASSIGNMENT`); a variable made in a tag lives in the template. For the same reason a block inside a tag cannot write output: `<% items.each do |i| %><%= i %><% end %>` is `CHECK-CAPTURED-ASSIGNMENT`, so write `<% for i in items %>` (Ruby's `each do` habit does not work here).
- `<%# note %>` is dropped. `<%%` is the text `<%`. `-%>` removes the line break after the tag, and `<%-` removes the spaces before the tag when only spaces come before it on its line (Ruby's `trim_mode: "-"`).
- One rule is not Ruby's `trim_mode: "-"`: a line that holds only one `<% %>` or `<%# %>` tag and spaces is removed whole, so a loop leaves no blank lines.
- The body is raw text: no `\n` or other escape and no `#{}`. The common indentation is removed, as for any `<<~` heredoc, and a body may be one line. A tag ends on its line, at the first `%>` (`PARSE-EAG-UNTERMINATED-TAG`).
- A template is an expression, so it can be returned, assigned, passed as an argument or followed by a method (`<<~EAG.length`). An error in a tag has the place of the tag in the template. `agentica type-at` and `refs` at a position inside a tag do not work yet.

`html_escape` replaces `&`, `<`, `>`, `"` and `'` with `&amp;`, `&lt;`, `&gt;`, `&quot;` and `&#39;`, as `ERB::Util.html_escape` does. It takes a `String`; call `to_s` on another value first. Ruby's alias `h` does not exist here.
