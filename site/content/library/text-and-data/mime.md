---
title: MIME (std)
weight: 11
description: The std/mime module, which gives the media type of a file from its name and tells which types are text.
---

`std/mime` is written in Agentica and follows `Rack::Mime` of Ruby: `import MIME from "std/mime"`. It maps a file extension to a media type (the value of a `Content-Type` header), with a small fixed table of the types a web server sends. Nothing in it halts, whatever the input.

```ruby
MIME.type_for(path: String, fallback: String = "application/octet-stream") -> String
MIME.text?(type: String) -> Bool
```

```agentica
import MIME from "std/mime"

def main() -> Void
  puts(MIME.type_for("public/index.html"))
  puts(MIME.type_for("LOGO.PNG"))
  puts(MIME.type_for("backup.tar.gz"))
  puts(MIME.type_for(".css"))
  puts(MIME.type_for("README"))
  puts(MIME.type_for("README", "text/plain"))
  type = MIME.type_for("app.js")
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

## type_for

`type_for` reads the last extension of the last `/` part of `path`, in any case. `backup.tar.gz` is a `.gz` file, so only the last extension counts. A leading dot is optional: `.css` and `css` both give `text/css`. A name with no dot is an extension only when the text has no `/`, so `css` is `text/css` while `public/css` is not, and neither is `README`.

A path with no extension, an empty extension (`a.`) and an extension that is not in the table all give `fallback`, which is `application/octet-stream` unless you pass one. The query string and the fragment of a URL are not removed, so pass the path alone.

## The table

The table holds: `html htm css js mjs json map webmanifest txt csv xml md yaml yml toml agc svg png jpg jpeg gif webp avif ico woff woff2 ttf otf pdf zip gz tar wasm mp4 webm mp3 wav ogg`. It is not meant to be complete, and `agc` is `text/plain`.

Where sources differ, it uses the current registered type: `js` and `mjs` are `text/javascript` (RFC 9239, where Rack and older Python say `application/javascript`), `xml` is `application/xml`, `yaml` and `yml` are `application/yaml`, `ico` is `image/vnd.microsoft.icon` and `wav` is `audio/wav`. Python's `mimetypes` gives the same answer for all the others it knows; it has no entry for `map`, `yaml`, `toml`, `agc`, the fonts and `ogg`.

## Charset

The types are bare, as in Rack: none ends in `; charset=utf-8`. `text?` says when a file holds text, so that you can add the parameter: it is true for `text/*`, for any `+json` or `+xml` type, and for `application/json`, `javascript`, `xml`, `yaml` and `toml`. It ignores parameters and case, so it also works on a `Content-Type` you read. Whether a file really is UTF-8 is for you to know.
