# Small web helpers (`std/uri`, `std/html`, `std/cookie`, `std/mime`, `std/utc`)

## URI (`std/uri`)

`import URI from "std/uri"`. Percent-encoding and query strings with the names
and rules of Ruby's `URI`. A decoder returns an `error` for bad input; none
halts.

```text
URI.encode_www_form_component(text: String) -> String          # space is +
URI.encode_uri_component(text: String) -> String               # space is %20
URI.decode_www_form_component(text: String) -> Result[String]  # + is a space
URI.decode_uri_component(text: String) -> Result[String]       # + stays a plus
URI.encode_www_form(pairs: List[URI.Pair]) -> String
URI.decode_www_form(query: String) -> Result[List[URI.Pair]]
URI.Pair(name: String, value: String)
```

- Encoders write the UTF-8 bytes as uppercase `%XX` and keep only
  `A-Z a-z 0-9 * - . _`; `~` becomes `%7E`, as in Ruby.
- Use `decode_uri_component` for a path segment and the `www_form` pair for a
  query string or a form.
- A decoder errors on a `%` without two hex digits (`invalid %-encoding
  (%zz)`) and on decoded bytes that are not UTF-8.
- A query string is a list of `URI.Pair`: names may repeat and the order is
  kept. `decode_www_form` splits on `&` and the first `=`; a piece
  without `=` has the value `""`. Unlike Ruby it skips empty pieces (`a=1&&b=2`)
  and errors on a bad `%`.

## HTML (`std/html`)

`import HTML from "std/html"`. Escapes and unescapes HTML text, as Ruby's
`CGI.escape_html` and `CGI.unescape_html`. Written in Agentica; nothing halts.

```text
HTML.escape(text: String) -> String
HTML.unescape(text: String) -> String
```

- `escape` writes `&amp; &lt; &gt; &quot; &#39;`. `unescape` decodes those,
  `&apos;`, `&#65;` and `&#x41;` once, and leaves any other entity, a missing
  `;` and a number that is not a Unicode scalar value as text.

## Cookie (`std/cookie`)

`import Cookie from "std/cookie"`. Reads a `Cookie` header and writes a
`Set-Cookie` header, with the behaviour of Rack. Written in Agentica; nothing
halts.

```text
Cookie.parse(header: String) -> Map[String, String]
Cookie.set_header(cookie: Cookie.Cookie) -> Result[String]
Cookie.Cookie(name: String, value: String, path: String = "", domain: String = "",
              max_age: Int = Cookie.NO_MAX_AGE, expires: String = "",
              secure: Bool = false, http_only: Bool = false, same_site: String = "")
```

- `parse` splits on `;`, trims, and keeps the first value of a
  name. It does not decode or unquote.
- `set_header` writes `name=value; Domain; Path; Max-Age; Expires;
  Secure; HttpOnly; SameSite`. `Cookie.NO_MAX_AGE` (the smallest `Int`, the
  default) and an empty string leave the attribute out; any other `max_age` of
  0 or less writes `Max-Age=0` and deletes the cookie. `expires` is text you
  format (no date type).
- It never encodes, decodes or quotes (final, unlike Ruby and Rack): encode
  the value yourself and decode it after reading. An `error` names the field
  for a name that is not an RFC 7230 token, a value with a space, `"`, `,`,
  `;`, `\`, a control or a non-ASCII byte, a `path`, `domain` or `expires`
  with a control or `;`, a `same_site` other than `Strict`, `Lax` or `None`,
  `None` without `secure`, `__Secure-` without `secure`, and `__Host-` without
  `secure`, path `/` and no domain.
- A program with its own `Cookie` name imports the module under another alias
  (`import C from "std/cookie"`): `import Cookie` would clash
  (`CHECK-REDEFINED-NAME`).

## MIME (`std/mime`)

`import MIME from "std/mime"`. The media type of a file by its extension.
Like Ruby's `Rack::Mime.mime_type`, with its own table. Nothing halts.

```text
MIME.mime_type(path: String, fallback: String = "application/octet-stream") -> String
MIME.text?(type: String) -> Bool
```

- A text that starts with `.`, has no other `.` and no `/` or `\` is an
  extension (`.css`). Any other text is a path: cut at the first `?` or `#`,
  take the last `/` part, then its extension as Ruby's `File.extname` gives it
  (the last one; a leading dot does not count: `dir/.json` has none). Case does
  not matter. A name with no dot (`css`, `README`), an
  empty or an unknown extension gives `fallback`.
- The table is fixed and small. Types are bare (no `; charset=utf-8`); `js` is
  `text/javascript`, `xml` is `application/xml`.
- `text?` is true for `text/*`, `+json`, `+xml` and
  `application/` `json`, `javascript`, `xml`, `yaml`, `toml` (parameters and
  case ignored): the types that take a `charset`. Send
  `"#{type}; charset=utf-8"` when it is true.

## UTC (`std/utc`)

`import UTC from "std/utc"`. Unix milliseconds (`Time.now_ms()`) as a civil
date and time in UTC. `Time` is the builtin's name, so the module is `UTC`.
`iso8601` is Ruby's `Time#utc.iso8601(n)`. Nothing halts.

```text
UTC.parts(time_ms: Int) -> UTC.Parts
UTC.iso8601(time_ms: Int, fraction_digits: Int = 0) -> String
```

- `UTC.Parts` has `year`, `month` (1-12), `day`, `hour`, `minute`, `second`
  and `millisecond`. A negative `ms` is before 1970.
- `iso8601` gives `2026-06-12T10:55:02Z`; with `fraction_digits` 1 to 9 a
  point and that many digits (`.345Z`; past the third they are `0`). Below 0
  counts as 0, above 9 as 9.
- Proleptic Gregorian calendar, no leap seconds, no time zones, UTC only.
