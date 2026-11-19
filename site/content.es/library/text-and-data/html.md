---
title: HTML (std)
weight: 10
description: El módulo std/html, que escapa y desescapa texto HTML.
source_hash: "cbbf3aac0675"
---

`std/html` está escrito en Agentica y tiene el comportamiento de `CGI.escape_html` y `CGI.unescape_html` de Ruby: `import HTML from "std/html"`. Nada en él se detiene, sea cual sea la entrada.

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

`escape` reemplaza `&`, `<`, `>`, `"` y `'` por `&amp;`, `&lt;`, `&gt;`, `&quot;` y `&#39;`, como hace Ruby.

`unescape` decodifica `&amp;`, `&lt;`, `&gt;`, `&quot;`, `&apos;`, el decimal `&#65;` y el hexadecimal `&#x41;` (`&#X41;` también), y nada más. Otro texto que parece una entidad se queda como está escrito: un nombre que Ruby no conoce (`&nbsp;`), un `;` que falta, y un número que no es un valor escalar de Unicode (mayor que `10FFFF`, o un sustituto). Para un número así, Ruby puede lanzar un error o dejar el texto, según su versión; este comportamiento puede diferir de Ruby en ese caso. `unescape("&#0;")` da un carácter NUL, como lo hace Ruby. El texto se lee una sola vez, así que `&amp;lt;` pasa a ser `&lt;`, y `unescape(escape(text))` es `text`.
