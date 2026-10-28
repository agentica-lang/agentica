---
title: CGI (std)
weight: 10
description: The std/cgi module, which escapes and unescapes HTML text and reads and writes HTTP cookies.
---

`std/cgi` is written in Agentica and uses the names of Ruby's `CGI` and of Rack: `import CGI from "std/cgi"`. It escapes text for HTML, reads a `Cookie` request header and writes a `Set-Cookie` header. Nothing in it halts, whatever the input.

```ruby
CGI.escape_html(text: String) -> String
CGI.unescape_html(text: String) -> String
CGI.parse_cookies_header(header: String) -> Map[String, String]
CGI.set_cookie_header(cookie: CGI.Cookie) -> Result[String]
```

`CGI.Cookie(name: String, value: String, ...)` is a cookie to send. The other fields have defaults, and an attribute left at its default is not written.

```ruby
struct CGI.Cookie
  name: String
  value: String
  path: String = ""
  domain: String = ""
  max_age: Int = -1          # negative: no Max-Age; 0 deletes the cookie
  expires: String = ""       # written as it is: "Wed, 21 Oct 2015 07:28:00 GMT"
  secure: Bool = false
  http_only: Bool = false
  same_site: String = ""     # "Strict", "Lax" or "None"
end
```

```agentica
import CGI from "std/cgi"

def main() -> Void
  puts(CGI.escape_html("<a href=\"/?q=1&r='2'\">"))
  puts(CGI.unescape_html("&lt;b&gt; &#x1F600; &#65; &nbsp; &amp;lt;"))
  puts(CGI.parse_cookies_header("sid=abc123; theme=dark; sid=other"))
  cookie = CGI.Cookie(name: "sid", value: "abc123", path: "/", max_age: 3600, secure: true, http_only: true, same_site: "Lax")
  puts(CGI.set_cookie_header(cookie))
  puts(CGI.set_cookie_header(CGI.Cookie(name: "sid", value: "a b")))
end
```

```output
&lt;a href=&quot;/?q=1&amp;r=&#39;2&#39;&quot;&gt;
<b> 😀 A &nbsp; &lt;
{"sid": "abc123", "theme": "dark"}
ok("sid=abc123; Path=/; Max-Age=3600; Secure; HttpOnly; SameSite=Lax")
error("invalid cookie value (a b)")
```

## HTML

`escape_html` replaces `&`, `<`, `>`, `"` and `'` with `&amp;`, `&lt;`, `&gt;`, `&quot;` and `&#39;`, as Ruby does.

`unescape_html` decodes `&amp;`, `&lt;`, `&gt;`, `&quot;`, `&apos;`, decimal `&#65;` and hex `&#x41;` (`&#X41;` too), and nothing else. Other text that looks like an entity stays as written: a name Ruby does not know (`&nbsp;`), a missing `;`, and a number that is not a Unicode scalar value (above `10FFFF`, or a surrogate). Where Ruby raises for such a number or its version decides, this leaves the text. The text is read once, so `&amp;lt;` becomes `&lt;`, and `unescape_html(escape_html(text))` is `text`.

## Cookies

`parse_cookies_header` splits the header on `;`, drops spaces around each piece, and splits a piece on its first `=`. A piece without `=` or with an empty name is skipped, and the first value of a repeated name wins, as in Rack's `parse_cookies_header`. The map keeps the order of the first appearance.

`set_cookie_header` writes `name=value` and then the attributes in Rack's order: `Domain`, `Path`, `Max-Age`, `Expires`, `Secure`, `HttpOnly`, `SameSite`. There is no date type, so `expires` is text you format. It returns an `error` that names the field and shows the text when:

- `name` is empty or is not an RFC 7230 token (letters, digits and ``!#$%&'*+-.^_`|~``),
- `value` has a byte that RFC 6265 does not allow: a space, `"`, `,`, `;`, `\`, a control or a non-ASCII byte,
- `path`, `domain` or `expires` has a control, a non-ASCII byte or `;`,
- `same_site` is not `Strict`, `Lax` or `None`.

Unlike Ruby's `CGI::Cookie` and Rack, the cookie functions neither percent-encode nor decode: both of those escape the value when writing it and decode it when reading. Here the value is written as it is (it is never quoted) and read as the client sent it, so a value with a space, a comma or non-ASCII text must be encoded before `set_cookie_header` and decoded after `parse_cookies_header`. A `%41` in a header stays `%41`.
