# CGI (`std/cgi`)

`import CGI from "std/cgi"`. HTML escaping and cookies with the names of Ruby's
`CGI` and Rack. Written in Agentica; nothing halts.

```text
CGI.escape_html(text: String) -> String
CGI.unescape_html(text: String) -> String
CGI.parse_cookies_header(header: String) -> Map[String, String]
CGI.set_cookie_header(cookie: CGI.Cookie) -> Result[String]
CGI.Cookie(name: String, value: String, path: String = "", domain: String = "",
           max_age: Int = -1, expires: String = "", secure: Bool = false,
           http_only: Bool = false, same_site: String = "")
```

- `escape_html` writes `&amp; &lt; &gt; &quot; &#39;`. `unescape_html` decodes
  those, `&apos;`, `&#65;` and `&#x41;` once, and leaves any other entity,
  a missing `;` and a number that is not a Unicode scalar value as text.
- `parse_cookies_header` splits on `;`, trims, and keeps the first value of a
  name. It does not decode or unquote.
- `set_cookie_header` writes `name=value; Domain; Path; Max-Age; Expires;
  Secure; HttpOnly; SameSite`. A negative `max_age` and an empty string leave
  the attribute out; `max_age: 0` deletes the cookie. `expires` is text you
  format (no date type).
- It does not encode or quote. An `error` names the field for a name that is
  not an RFC 7230 token, a value with a space, `"`, `,`, `;`, `\`, a control
  or a non-ASCII byte, a `path`, `domain` or `expires` with a control or `;`,
  and a `same_site` other than `Strict`, `Lax` or `None`. Unlike Ruby and
  Rack, encode the value yourself and decode it after reading.
