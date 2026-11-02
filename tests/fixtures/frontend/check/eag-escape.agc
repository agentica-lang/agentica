import EAG from "std/eag"

def page(name: String, names: List[String]) -> String
  return <<~EAG
    <%@ escape &EAG.html_escape %>
    <h1><%= name %></h1>
    <% for item in names %>
    <li><%= item %> <%== item %></li>
    <% end %>
  EAG
end

def main() -> Void
  puts(page("a", []))
end
