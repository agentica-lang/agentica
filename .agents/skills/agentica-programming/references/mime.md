# MIME (`std/mime`)

`import MIME from "std/mime"`. The media type of a file by its extension, with
the fallback of Ruby's `Rack::Mime`. Written in Agentica; nothing halts.

```text
MIME.type_for(path: String, fallback: String = "application/octet-stream") -> String
MIME.text?(type: String) -> Bool
```

- `type_for` reads the last extension of the last `/` part, in any case:
  `archive.tar.gz` is `gz`, and `.css` and `css` are `css`. A name with no dot
  is an extension only when the text has no `/` (`css` is `text/css`, `a/css`
  is not). No extension or an unknown one gives `fallback`. A query string or
  fragment is not removed.
- The table is fixed and small: web text, data, images, fonts, audio, video,
  `wasm`, `pdf`, `zip`, `gz`, `tar`. Types are bare (no `; charset=utf-8`);
  `js` is `text/javascript`, `xml` is `application/xml`.
- `text?` is true for `text/*`, `+json`, `+xml` and `application/` `json`,
  `javascript`, `xml`, `yaml`, `toml` (parameters and case ignored): the types
  that take a `charset`. Send `"#{type}; charset=utf-8"` when it is true.
