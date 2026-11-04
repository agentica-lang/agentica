"""`<<~EAG` templates through the product CLI (docs/future/51-templates.md): the output of a template against an
independent implementation of ERB's rules, and the diagnostics, asserted by code and span, never message text.

The peer is `peer_render` below, written from the rules of Ruby's ERB with `trim_mode: "-"` plus the rule for a line that
holds only one `<% %>` tag. The CI has no Ruby, so the peer is Python: it compiles the template to Python code the way
ERB compiles to Ruby, then runs it."""
import json
import re
import textwrap

import pytest

from tests.agentica_test import cli, run, vm_environment
from tests.span_support import problem, start, where

# A template whose tags are valid in Agentica and in Python: names, `+`, comparisons, `for X in Y`, `if C`, `else`.
TEMPLATE = '''<h1><%= title %></h1>
<%# a note, dropped %>
<ul>
<% for name in names %>
  <% if flag %>
  <li><%= name -%>
  </li>
  <% else %>
  <li>off <%= n + 1 %></li>
  <% end %>
<% end %>
</ul>
    <%- for name in names -%>
  <p><%= name %> <%= n %></p>
    <%- end -%>
A literal <%% tag, #{raw} \\n and 100%> text.
ab  <%- _k = 5 %>cd
    <%- _k = 6 %>ef

<% if flag %>flag<% end %> and <%= title + "!" -%>
tail
'''

PROGRAM = '''import EAG from "std/eag"

def render(title: String, names: List[String], n: Int, flag: Bool) -> String
  return <<~EAG
%s  EAG
end

def main() -> Void
  puts(render("T&<", ["a", "b"], 2, true))
  puts(render("U", [], 0, false))
end
'''


def html_escape(value):
    """`EAG.html_escape`, written again: Ruby's `ERB::Util.html_escape`."""
    for char, entity in (("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ('"', "&quot;"), ("'", "&#39;")):
        value = value.replace(char, entity)
    return value


def peer_render(template, scope):
    """The text of `template` for the names in `scope`, by ERB's rules: `<%= %>`, `<% %>`, `<%# %>`, `<%%`, `-%>`
    (removes the line break after the tag), `<%-` (removes the spaces before it), and a line with one statement or
    comment tag and nothing else but spaces vanishes. `<%@ escape %>` turns on `html_escape` for `<%= %>`, as Erubi's
    `escape: true` does, and `<%== %>` inserts as it is."""
    code = ["_out = []", "_esc = str"]
    depth = 0

    def add(line):
        code.append("  " * depth + line)

    for line in template.split("\n")[:-1]:
        pieces = re.split(r"(<%%|<%(?:==|[=#@-])?.*?-?%>)", line)
        tags = [piece for piece in pieces if piece.startswith("<%") and piece != "<%%"]
        blank = all(not piece.strip() for piece in pieces if piece not in tags and piece != "<%%" and piece != "")
        alone = len(tags) == 1 and not tags[0].startswith("<%=") and blank
        trimmed = False
        first = True
        for piece in pieces:
            if piece == "<%%":
                add("_out.append(%r)" % "<%")
            elif piece.startswith("<%"):
                kind = "==" if piece.startswith("<%==") else piece[2] if piece[2] in "=#@-" else ""
                body = piece[2 + len(kind):-2]
                trimmed = body.endswith("-")
                body = body[:-1] if trimmed else body
                if kind == "==":
                    add("_out.append(str(%s))" % body)
                elif kind == "=":
                    add("_out.append(_esc(str(%s)))" % body)
                elif kind == "@":
                    add("_esc = html_escape")
                elif kind == "#":
                    pass
                else:
                    word = body.strip()
                    if word == "end":
                        depth -= 1
                    elif word == "else":
                        depth -= 1
                        add("else:")
                        depth += 1
                    elif word.startswith(("for ", "if ")):
                        add(word + ":")
                        depth += 1
                    else:
                        add(word)
            elif piece and not alone:
                # `<%-` removes the spaces before it when only spaces come before it on its line.
                if not (first and piece.strip() == "" and kind_is_trim(pieces)):
                    add("_out.append(%r)" % piece)
            first = False
        if not alone and not trimmed:
            add("_out.append('\\n')")
    namespace = dict(scope, html_escape=html_escape)
    exec("\n".join(code), namespace)
    return "".join(namespace["_out"])


def kind_is_trim(pieces):
    """Whether the line starts with a `<%-` tag after spaces: only then are its leading spaces removed."""
    return len(pieces) > 1 and pieces[1].startswith("<%-")


def indented(template):
    return textwrap.indent(template, "    ")


def write(tmp_path, text, name="t.agc"):
    path = tmp_path / name
    path.write_text(text, encoding="utf-8")
    return path


def check(path):
    return run(cli() + ["--json", "check", str(path)], env=vm_environment())


def test_output_matches_the_peer(tmp_path):
    path = write(tmp_path, PROGRAM % indented(TEMPLATE))
    result = run(cli() + [str(path)], env=vm_environment())
    assert result.code == 0, result.stderr
    first = peer_render(TEMPLATE, {"title": "T&<", "names": ["a", "b"], "n": 2, "flag": True})
    second = peer_render(TEMPLATE, {"title": "U", "names": [], "n": 0, "flag": False})
    # `puts` adds a line break after the text, which ends with one.
    assert result.stdout == first + "\n" + second + "\n"
    # Raw by default, as ERB is: nothing is escaped, `#{raw}` is text, and `\n` is a backslash and an n.
    assert "T&<" in result.stdout and "#{raw} \\n" in result.stdout


ESCAPED = '''<%@ escape &EAG.html_escape %>
<h1><%= title %></h1>
<% for name in names %>
<li><%= name %> <%== name %> <%= n + 1 %></li>
<% end %>
'''

# The same tags with no directive: `<%==` is `<%=`.
PLAIN = ESCAPED.replace("<%@ escape &EAG.html_escape %>\n", "")


def test_an_escape_directive_applies_to_output_tags_and_not_to_raw_tags(tmp_path):
    source = PROGRAM % indented(ESCAPED)
    source = source.replace("def main()", "def plain(title: String, names: List[String], n: Int, flag: Bool) -> String\n"
                            "  return <<~EAG\n%s  EAG\nend\n\ndef main()" % indented(PLAIN))
    source = source.replace("  puts(render(\"U\", [], 0, false))\n", "  puts(plain(\"T&<\", [\"a<\", \"b\"], 2, true))\n")
    path = write(tmp_path, source)
    result = run(cli() + [str(path)], env=vm_environment())
    assert result.code == 0, result.stderr
    scope = {"title": "T&<", "names": ["a", "b"], "n": 2, "flag": True}
    first = peer_render(ESCAPED, scope)
    second = peer_render(PLAIN, dict(scope, names=["a<", "b"]))
    assert result.stdout == first + "\n" + second + "\n"
    # `<%=` escaped, `<%==` as it is, and a template with no directive is raw.
    assert "<h1>T&amp;&lt;</h1>" in result.stdout and "<li>a&lt; a<" not in result.stdout
    assert "<li>a<" in result.stdout.split("<h1>T&<</h1>")[1]
    assert run(cli() + ["fmt", "--check", str(path)], env=vm_environment()).code == 0


def test_a_template_is_an_expression_and_html_escape_is_in_std_eag(tmp_path):
    path = write(tmp_path, '''import {html_escape} from "std/eag"

def main() -> Void
  name = "a<b & \\"c\\" 'd'"
  if <<~EAG.length > 3
    <%= html_escape(name) %>
    <%= name.length %>
  EAG
    puts(<<~EAG)
      <%= html_escape(name) %>
    EAG
  end
end
''')
    result = run(cli() + [str(path)], env=vm_environment())
    assert result.code == 0, result.stderr
    # The template ends with a line break and `puts` adds one.
    assert result.stdout == "a&lt;b &amp; &quot;c&quot; &#39;d&#39;\n\n"


def test_a_template_without_the_import_is_check_eag_import(tmp_path):
    source = "def main() -> Void\n  puts(<<~EAG)\n    a\n    b\n  EAG\nend\n"
    diagnostic = problem(check(write(tmp_path, source)), "CHECK-EAG-IMPORT", 1)
    assert (diagnostic["range"]["start"]["line"], diagnostic["range"]["start"]["column"]) == (2, 8)
    # Any import of the module is enough, and the file's own name for it does not matter.
    assert check(write(tmp_path, 'import Other from "std/eag"\n\n' + source, "b.agc")).code == 0


def test_code_in_a_tag_is_checked_in_the_scope_of_the_function(tmp_path):
    source = '''import EAG from "std/eag"

struct Item
  title: String
end

def page(items: List[Item]) -> String
  return <<~EAG
    <% for item in items %>
    <li><%= item.titl %></li>
    <% end %>
  EAG
end

def main() -> Void
  puts(page([]))
end
'''
    diagnostic = problem(check(write(tmp_path, source)), "CHECK-UNKNOWN-FIELD", 1)
    # The span is in the template, at the field, as the tag was written.
    assert (diagnostic["range"]["start"]["line"], diagnostic["range"]["start"]["column"]) == where(source, "item.titl")
    # A tag cannot assign a variable of the function: the template is a block (CHECK-CAPTURED-ASSIGNMENT).
    assigned = source.replace("item.titl", "item.title").replace("<% for", "<% total = 1 %>\n    <% for")
    assigned = assigned.replace("def page(items", "def page(total: Int, items").replace("page([])", "page(0, [])")
    problem(check(write(tmp_path, assigned, "c.agc")), "CHECK-CAPTURED-ASSIGNMENT", 1)


@pytest.mark.parametrize("body, code, needle", [
    ("a\n    <%= n\n", "PARSE-EAG-UNTERMINATED-TAG", "<%= n"),
    ("<% if n > 1 %>\n    a\n", "PARSE-EAG-BLOCK", "if n > 1"),
    ("a\n    <% end %>\n", "PARSE-EAG-BLOCK", "end %>"),
    ("a\n    <%= n + %>\n", "PARSE-UNEXPECTED-TOKEN", " n + "),
    ("a\n    <%= puts(\"x\") %>\n", "CHECK-VOID-VALUE", "puts"),
    ("a\n    <%@ escape &EAG.html_escape %>\n", "PARSE-EAG-DIRECTIVE", " escape &EAG"),
    ("<%@ escape &EAG.html_escape %>\n    <%@ escape  &EAG.html_escape %>\n", "PARSE-EAG-DIRECTIVE", " escape  &EAG"),
    ("<%@ other &EAG.html_escape %>\n    a\n", "PARSE-EAG-DIRECTIVE", " other &EAG"),
    ("<%@ escape %>\n    a\n", "PARSE-EAG-DIRECTIVE", " escape "),
])
def test_template_diagnostics_carry_a_span_in_the_template(tmp_path, body, code, needle):
    source = 'import EAG from "std/eag"\n\ndef page(n: Int) -> String\n  return <<~EAG\n    %s  EAG\nend\n' % body
    source += "\ndef main() -> Void\n  puts(page(1))\nend\n"
    diagnostic = problem(check(write(tmp_path, source)), code, 1)
    assert (diagnostic["range"]["start"]["line"], diagnostic["range"]["start"]["column"]) == where(source, needle)


@pytest.mark.parametrize("escaper, code, needle", [
    ("&count", "CHECK-TYPE-MISMATCH", "&count"),
    ("&join", "CHECK-TYPE-MISMATCH", "&join"),
    ("3", "CHECK-TYPE-MISMATCH", "3 %>"),
    ("&nope", "CHECK-UNKNOWN-NAME", "&nope"),
    # Two functions are not one expression: the binding of the escaper stops at the comma.
    ("&count, &join", "PARSE-UNEXPECTED-TOKEN", ", &join"),
])
def test_the_escaper_is_checked_as_a_function_from_string_to_string(tmp_path, escaper, code, needle):
    source = '''import EAG from "std/eag"

def count(n: Int) -> String
  return "#{n}"
end

def join(a: String, b: String) -> String
  return a
end

def page() -> String
  return <<~EAG
    <%%@ escape %s %%>
    a <%%= "x" %%>
  EAG
end

def main() -> Void
  puts(page())
end
''' % escaper
    diagnostic = problem(check(write(tmp_path, source)), code, 1)
    assert (diagnostic["range"]["start"]["line"], diagnostic["range"]["start"]["column"]) == where(source, needle)


def test_the_escaper_may_be_any_expression_of_the_type(tmp_path):
    path = write(tmp_path, '''import EAG from "std/eag"

def up(text: String) -> String
  return text.upcase
end

def make() -> Fn[String, String]
  return &up
end

def main() -> Void
  puts(<<~EAG)
    <%@ escape make() %>
    a <%= "x" %> <%== "y" %>
  EAG
end
''')
    result = run(cli() + [str(path)], env=vm_environment())
    assert result.code == 0, result.stderr
    assert result.stdout == "a X y\n\n"


def test_a_block_of_a_tag_cannot_write_the_output(tmp_path):
    source = '''import EAG from "std/eag"

def page(items: List[String]) -> String
  return <<~EAG
    <% items.each do |i| %>
    <%= i %>
    <% end %>
  EAG
end

def main() -> Void
  puts(page([]))
end
'''
    diagnostic = problem(check(write(tmp_path, source)), "CHECK-CAPTURED-ASSIGNMENT", 1)
    line, column = where(source, "<%= i %>")
    # The span is the code of the tag that writes, and the text speaks of the template, not of its inner names.
    assert (diagnostic["range"]["start"]["line"], diagnostic["range"]["start"]["column"]) == (line, column + 3)
    assert "eag#" not in diagnostic["message"] + diagnostic.get("help", "")
    # A `for` loop writes the output.
    fixed = source.replace("<% items.each do |i| %>", "<% for i in items %>")
    assert check(write(tmp_path, fixed, "d.agc")).code == 0


def test_an_empty_output_tag_is_reported_at_the_tag(tmp_path):
    source = '''import EAG from "std/eag"

def page() -> String
  return <<~EAG
    a <%=  %>
    b
  EAG
end

def main() -> Void
  puts(page())
end
'''
    diagnostic = problem(check(write(tmp_path, source)), "PARSE-UNEXPECTED-TOKEN", 1)
    line, column = where(source, "<%=")
    assert (diagnostic["range"]["start"]["line"], diagnostic["range"]["start"]["column"]) == (line, column + 3)


def test_a_line_of_many_open_tags_without_an_end_is_reported_at_once(tmp_path):
    # Linear work: 40,000 `<%` and no `%>` is one error at the first, found without joining the line again and again.
    source = 'import EAG from "std/eag"\n\ndef page() -> String\n  return <<~EAG\n    a %s\n  EAG\nend\n' % ("<% x " * 40000)
    diagnostic = problem(check(write(tmp_path, source)), "PARSE-EAG-UNTERMINATED-TAG", 1)
    assert (diagnostic["range"]["start"]["line"], diagnostic["range"]["start"]["column"]) == where(source, "<% x ")


def test_refs_finds_the_names_a_tag_uses_and_none_of_the_expansion(tmp_path):
    path = write(tmp_path, '''import EAG from "std/eag"

def page(names: List[String]) -> String
  return <<~EAG
    a
    <% for name in names %>
    <%= name.upcase %>
    <% end %>
  EAG
end

def main() -> Void
  puts(page([]))
end
''')
    def references(name):
        result = run(cli() + ["--json", "refs", name, str(path)], env=vm_environment())
        assert result.code == 0, result.stderr
        # std/eag imports std/html, whose own calls are not the template's.
        return [item for item in json.loads(result.stdout)["references"] if item["span"]["file"].endswith(path.name)]

    assert [item["span"]["range"]["start"]["line"] for item in references("String.upcase")] == [7]
    # The calls of the expansion (`map`, `first`, `join`, `push`) belong to no line of the template.
    for hidden in ("List.map", "List.first", "String.join", "List.append"):
        assert references(hidden) == []


def test_the_formatter_keeps_a_template_as_written(tmp_path):
    path = write(tmp_path, PROGRAM % indented(TEMPLATE))
    result = run(cli() + ["fmt", "--check", str(path)], env=vm_environment())
    assert result.code == 0, result.stdout + result.stderr
    assert json.loads(check(path).stdout)["ok"] is True
