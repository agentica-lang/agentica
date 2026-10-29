---
title: HTML (std)
weight: 10
description: The std/html module, which escapes and unescapes HTML text.
---

`std/html` is written in Agentica and has the behaviour of Ruby's `CGI.escape_html` and `CGI.unescape_html`: `import HTML from "std/html"`. Nothing in it halts, whatever the input.

```ruby
HTML.escape(text: String) -> String
HTML.unescape(text: String) -> String
```

```agentica
import HTML from "std/html"

def main() -> Void
  puts(HTML.escape("<a href=\"/?q=1&r='2'\">"))
  puts(HTML.unescape("&lt;b&gt; &#x1F600; &#65; &nbsp; &amp;lt;"))
end
```

```output
&lt;a href=&quot;/?q=1&amp;r=&#39;2&#39;&quot;&gt;
<b> 😀 A &nbsp; &lt;
```

`escape` replaces `&`, `<`, `>`, `"` and `'` with `&amp;`, `&lt;`, `&gt;`, `&quot;` and `&#39;`, as Ruby does.

`unescape` decodes `&amp;`, `&lt;`, `&gt;`, `&quot;`, `&apos;`, decimal `&#65;` and hex `&#x41;` (`&#X41;` too), and nothing else. Other text that looks like an entity stays as written: a name Ruby does not know (`&nbsp;`), a missing `;`, and a number that is not a Unicode scalar value (above `10FFFF`, or a surrogate). For such a number Ruby may raise or leave the text, depending on its version; this behaviour may differ from Ruby there. `unescape("&#0;")` gives a NUL character, as Ruby does. The text is read once, so `&amp;lt;` becomes `&lt;`, and `unescape(escape(text))` is `text`.
