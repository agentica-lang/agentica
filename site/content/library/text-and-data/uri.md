---
title: URI (std)
weight: 9
description: The std/uri module, which percent-encodes and decodes URL components and query strings.
---

`std/uri` is written in Agentica and follows the names and rules of Ruby's `URI`: `import URI from "std/uri"`. It encodes text for a URL, decodes it back, and turns a query string into a list of name and value pairs and back. A decoder returns a `Result` and never halts, whatever the input.

```ruby
URI.encode_www_form_component(text: String) -> String
URI.encode_uri_component(text: String) -> String
URI.decode_www_form_component(text: String) -> Result[String]
URI.decode_uri_component(text: String) -> Result[String]
URI.encode_www_form(pairs: List[List[String]]) -> Result[String]
URI.decode_www_form(query: String) -> Result[List[List[String]]]
```

```agentica
import URI from "std/uri"

def main() -> Void
  puts(URI.encode_www_form_component("café au lait"))
  puts(URI.encode_uri_component("café au lait"))
  puts(URI.decode_uri_component("a+b%20c"))
  puts(URI.decode_www_form("a=1&a=2&b=&k"))
  puts(URI.encode_www_form([["q", "a b"], ["q", "~"]]))
  puts(URI.decode_www_form_component("100%"))
end
```

```output
caf%C3%A9+au+lait
caf%C3%A9%20au%20lait
ok("a+b c")
ok([["a", "1"], ["a", "2"], ["b", ""], ["k", ""]])
ok("q=a+b&q=%7E")
error("invalid %-encoding (100%)")
```

## Components

The text is UTF-8. An encoder writes the bytes of each character as `%XX` in uppercase hex and keeps only `A-Z a-z 0-9 * - . _`; `~` is encoded (`%7E`), as in Ruby. The two encoders differ in the space: `encode_www_form_component` writes `+` (query strings and forms) and `encode_uri_component` writes `%20` (path segments and other components).

A decoder reads `%XX` in either case. `decode_www_form_component` turns `+` into a space; `decode_uri_component` leaves `+` alone, so it is the one to use on a path segment. Text that is not ASCII passes through unchanged.

A decoder returns an `error` when a `%` is not followed by two hex digits (`invalid %-encoding (%zz)`, the message of Ruby's `ArgumentError`) and when the decoded bytes are not valid UTF-8 (`invalid UTF-8 after decoding (%ff)`). Ruby returns a string with invalid bytes for the second case, which a `String` cannot hold.

## Query strings

A query string is a list of `[name, value]` pairs, as in Ruby. A name may repeat and the order is kept, so `a=1&a=2` is two pairs. `decode_www_form` splits on `&` and then on the first `=`: a piece without `=` has the value `""`, and `a=b=c` has the value `b=c`. It returns the error of the first piece that does not decode.

`decode_www_form` differs from Ruby in two ways. An empty piece (`a=1&&b=2`, a trailing `&`) is skipped, as in Python, Rack and browsers, where Ruby returns `["", ""]` for it. A bad `%` is an error, where Ruby leaves it in the text. Only `&` separates pieces.

`encode_www_form` joins the pairs as `name=value` with `encode_www_form_component`, so the output of `decode_www_form` goes back in unchanged. It returns an `error` for a pair that does not have exactly two items; Ruby's one-item pair (a name without `=`) is not accepted, write `[name, ""]`.
