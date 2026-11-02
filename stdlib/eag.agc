## What an `<<~EAG` template needs: the import `import EAG from "std/eag"`, and the escape for HTML.
##
## EAG is Agentica's ERB: a template is a heredoc `<<~EAG` whose body is text with the tags of Ruby's ERB,
## `<%= code %>`, `<% statement %>`, `<%# note %>` and `-%>`. It is checked and compiled with the file that holds it;
## its output is raw, as the output of ERB is, so write `<%= EAG.html_escape(name) %>` for text that goes into HTML.
##
## ```agentica
## import EAG from "std/eag"
##
## def page(names: List[String]) -> String
##   return <<~EAG
##     <ul>
##     <% for name in names %>
##       <li><%= EAG.html_escape(name) %></li>
##     <% end %>
##     </ul>
##   EAG
## end
## ```
##
## Written in Agentica; nothing here halts.

import HTML from "std/html"

## Replaces `&`, `<`, `>`, `"` and `'` with `&amp;`, `&lt;`, `&gt;`, `&quot;` and `&#39;`, as Ruby's
## `ERB::Util.html_escape` does.
export def html_escape(value: String) -> String
  return HTML.escape(value)
end
