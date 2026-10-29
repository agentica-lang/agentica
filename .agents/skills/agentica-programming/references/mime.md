# MIME (`std/mime`)

`import MIME from "std/mime"`. The media type of a file by its extension.
`mime_type` and its fallback are those of Ruby's `Rack::Mime.mime_type`; the
table is this module's own. Written in Agentica; nothing halts.

```text
MIME.mime_type(path: String, fallback: String = "application/octet-stream") -> String
MIME.text?(type: String) -> Bool
```

- A text that starts with `.`, has no other `.` and no `/` or `\` is an
  extension (`.css`). Any other text is a path: cut at the first `?` or `#`,
  take the last `/` part, then the extension of `File.extname` (the last one;
  a leading dot does not count: `dir/.json` has none, `.env.json` is `json`).
  Case does not matter. A name with no dot (`css`, `README`), an empty or an
  unknown extension gives `fallback`.
- The table is fixed and small: web text and data, images, fonts, audio,
  video, `wasm`, `pdf`, archives. Types are bare (no `; charset=utf-8`);
  `js` is `text/javascript`, `xml` is `application/xml`, `wav` is `audio/wav`.
- `text?` has no Ruby counterpart (the closest is mime-types'
  `MIME::Type#ascii?`). It is true for `text/*`, `+json`, `+xml` and
  `application/` `json`, `javascript`, `xml`, `yaml`, `toml` (parameters and
  case ignored): the types that take a `charset`. Send
  `"#{type}; charset=utf-8"` when it is true.
