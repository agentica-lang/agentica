## Looks up the media type of a file by its extension, with the table and the fallback of Ruby's `Rack::Mime`.
##
## Import it with `import MIME from "std/mime"`. `type_for` is `Rack::Mime.mime_type(ext, fallback)` and takes a path
## as well as an extension. The table is small (the types a static file server sends) and fixed. Written in Agentica;
## nothing here halts.
##
## The types are bare, as in Rack: none carries `; charset=utf-8`. `text?` tells a caller that sends text when to add
## it, so `"#{type}; charset=utf-8"` is the `Content-Type` of a text file.

# Extension (lowercase, no dot) to type. Where Python's `mimetypes` or Rack differ, the choice is the current IANA one:
# `text/javascript` (RFC 9239), `application/xml`, `application/yaml`, `image/vnd.microsoft.icon`, `audio/wav`.
TYPES = {
  "html": "text/html",
  "htm": "text/html",
  "css": "text/css",
  "js": "text/javascript",
  "mjs": "text/javascript",
  "json": "application/json",
  "map": "application/json",
  "webmanifest": "application/manifest+json",
  "txt": "text/plain",
  "csv": "text/csv",
  "xml": "application/xml",
  "md": "text/markdown",
  "yaml": "application/yaml",
  "yml": "application/yaml",
  "toml": "application/toml",
  "agc": "text/plain",
  "svg": "image/svg+xml",
  "png": "image/png",
  "jpg": "image/jpeg",
  "jpeg": "image/jpeg",
  "gif": "image/gif",
  "webp": "image/webp",
  "avif": "image/avif",
  "ico": "image/vnd.microsoft.icon",
  "woff": "font/woff",
  "woff2": "font/woff2",
  "ttf": "font/ttf",
  "otf": "font/otf",
  "pdf": "application/pdf",
  "zip": "application/zip",
  "gz": "application/gzip",
  "tar": "application/x-tar",
  "wasm": "application/wasm",
  "mp4": "video/mp4",
  "webm": "video/webm",
  "mp3": "audio/mpeg",
  "wav": "audio/wav",
  "ogg": "audio/ogg"
}

# The `application/` types that are text, besides `text/*` and any `+json` or `+xml` type.
TEXT_TYPES = Set.new(["application/json", "application/javascript", "application/xml", "application/yaml",
                      "application/toml"])

## Returns the media type of a file by its last extension, or `fallback` (default `application/octet-stream`) when
## there is none or it is not in the table.
## `path` may be a path (`public/app.JS`), a file name (`archive.tar.gz` gives the type of `gz`), an extension with its
## dot (`.css`) or a bare extension (`css`); the case does not matter. Only the part after the last `/` is read, and a
## name with no dot is an extension only when the whole text has no `/`, so `css` is `text/css` and `a/css` is not.
## The query string and the fragment of a URL are not removed.
export def type_for(path: String, fallback: String = "application/octet-stream") -> String
  parts = path.split("/")
  name = parts[parts.size - 1]
  pieces = name.split(".")
  if pieces.size == 1 and parts.size > 1
    return fallback
  end
  ext = pieces[pieces.size - 1].downcase
  if TYPES.key?(ext)
    return TYPES[ext]
  end
  return fallback
end

## Returns true when a file of this media type holds text, so a `charset` parameter applies: `text/*`, any `+json` or
## `+xml` type, and `application/json`, `javascript`, `xml`, `yaml` and `toml`. The type may have parameters
## (`text/html; charset=utf-8`) and any case.
export def text?(type: String) -> Bool
  base = type.split(";")[0].strip.downcase
  return base.start_with?("text/") or base.end_with?("+json") or base.end_with?("+xml") or TEXT_TYPES.include?(base)
end
