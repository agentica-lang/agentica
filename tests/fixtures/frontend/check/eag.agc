import EAG from "std/eag"

struct Item
  title: String
  visible: Bool
end

def page(name: String, items: List[Item]) -> String
  return <<~EAG
    <h1><%= EAG.html_escape(name) %></h1>
    <% for item in items %>
    <% if item.visible %>
    <li><%= item.title %></li>
    <% end %>
    <% end %>
  EAG
end

def main() -> Void
  puts(page("a", []))
end
