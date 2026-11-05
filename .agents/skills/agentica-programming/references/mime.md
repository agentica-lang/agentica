# MIME (`std/mime`)

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
