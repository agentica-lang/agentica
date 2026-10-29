---
title: MIME (std)
weight: 11
description: The std/mime module, which gives the media type of a file from its name and tells which types are text.
---

`std/mime` is written in Agentica: `import MIME from "std/mime"`. `mime_type` and its fallback argument are those of Ruby's `Rack::Mime.mime_type`. It maps a file extension to a media type (the value of a `Content-Type` header), with a small fixed table of the types a web server sends, which is this module's own. Nothing in it halts, whatever the input.

```ruby
MIME.mime_type(path: String, fallback: String = "application/octet-stream") -> String
MIME.text?(type: String) -> Bool
```

```agentica
import MIME from "std/mime"

def main() -> Void
  puts(MIME.mime_type("public/index.html"))
  puts(MIME.mime_type("LOGO.PNG"))
  puts(MIME.mime_type("backup.tar.gz"))
  puts(MIME.mime_type(".css"))
  puts(MIME.mime_type("README"))
  puts(MIME.mime_type("README", "text/plain"))
  type = MIME.mime_type("app.js")
  if MIME.text?(type)
    type = "#{type}; charset=utf-8"
  end
  puts(type)
end
```

```output
text/html
image/png
application/gzip
text/css
application/octet-stream
text/plain
text/javascript; charset=utf-8
```

## mime_type

`mime_type` reads its argument in one of two ways. A text that starts with a dot, has no other dot and has no `/` or `\` is an extension, as in Rack: `.css` gives `text/css`. Any other text is a path: the query string (from the first `?`) and the fragment (from the first `#`) are cut, then the part after the last `/` is read with the rule of Ruby's `File.extname`. Only the last extension counts, in any case, so `backup.tar.gz` is a `.gz` file. A dot at the start of the name does not begin an extension, so `public/.json` has none and `.env.json` is `json`.

A name with no dot (`css`, `README`), an empty extension (`a.`) and an extension that is not in the table all give `fallback`, which is `application/octet-stream` unless you pass one.

## The table

The table holds: `html htm css js mjs cjs json map jsonld webmanifest txt csv xml xhtml rss atom ics md yaml yml toml agc svg png jpg jpeg gif webp avif ico bmp tif tiff woff woff2 ttf otf pdf zip gz tar bz2 7z wasm mp4 webm mp3 m4a flac wav ogg`. It is not meant to be complete, and `agc` is `text/plain`.

Where sources differ, it uses the registered type: `js`, `mjs` and `cjs` are `text/javascript` (RFC 9239, where Rack and older Python say `application/javascript`), `xml` is `application/xml`, `yaml` and `yml` are `application/yaml` and `ico` is `image/vnd.microsoft.icon`. `wav` is `audio/wav`, the common type (the registered one is `audio/vnd.wave`).

## Charset

The types are bare, as in Rack: none ends in `; charset=utf-8`. `text?` says when a file holds text, so that you can add the parameter. Ruby has no function like it (the closest is `MIME::Type#ascii?` of the mime-types gem); it exists so that a server can add the charset. It is true for `text/*`, for any `+json` or `+xml` type, and for `application/json`, `javascript`, `xml`, `yaml` and `toml`. It ignores parameters and case, so it also works on a `Content-Type` you read. Whether a file really is UTF-8 is for you to know.
