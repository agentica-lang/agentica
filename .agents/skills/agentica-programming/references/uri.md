# URI (`std/uri`)

`import URI from "std/uri"`. Percent-encoding and query strings with the names
and rules of Ruby's `URI`. Written in Agentica; a decoder returns an `error`
for bad input and none halts.

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
- `encode_www_form` cannot fail; a name alone is `Pair(name: n, value: "")`.
