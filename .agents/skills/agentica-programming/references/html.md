# HTML (`std/html`)

`import HTML from "std/html"`. Escapes and unescapes HTML text, as Ruby's
`CGI.escape_html` and `CGI.unescape_html`. Written in Agentica; nothing halts.

```text
HTML.escape(text: String) -> String
HTML.unescape(text: String) -> String
```

- `escape` writes `&amp; &lt; &gt; &quot; &#39;`. `unescape` decodes those,
  `&apos;`, `&#65;` and `&#x41;` once, and leaves any other entity, a missing
  `;` and a number that is not a Unicode scalar value as text.
