## Looks up the media type of a file by its extension. The name `mime_type` and the fallback argument are those of
## Ruby's `Rack::Mime.mime_type`; the table is this module's own small one.
##
## Import it with `import MIME from "std/mime"`. `mime_type` takes an extension (`.css`) or a path (`public/app.JS`).
## The table is small (the types a static file server sends) and fixed. Written in Agentica; nothing here halts.
##
## The types are bare, as in Rack: none carries `; charset=utf-8`. `text?` has no counterpart in Ruby (the closest is
## `MIME::Type#ascii?` of the mime-types gem); it exists so that a server that sends text can tell when to add the
## charset, as in `"#{type}; charset=utf-8"`.

# Extension (lowercase, no dot) to type. Where sources differ, the choice is the registered type, except `audio/wav`,
# the common one (the registered type is `audio/vnd.wave`): `text/javascript` (RFC 9239), `application/xml`,
# `application/yaml`, `image/vnd.microsoft.icon`.
TYPES = {
  "html": "text/html",
  "htm": "text/html",
  "css": "text/css",
  "js": "text/javascript",
  "mjs": "text/javascript",
  "cjs": "text/javascript",
  "json": "application/json",
  "map": "application/json",
  "jsonld": "application/ld+json",
  "webmanifest": "application/manifest+json",
  "txt": "text/plain",
  "csv": "text/csv",
  "xml": "application/xml",
  "xhtml": "application/xhtml+xml",
  "rss": "application/rss+xml",
  "atom": "application/atom+xml",
  "ics": "text/calendar",
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
  "bmp": "image/bmp",
  "tif": "image/tiff",
  "tiff": "image/tiff",
  "woff": "font/woff",
  "woff2": "font/woff2",
  "ttf": "font/ttf",
  "otf": "font/otf",
  "pdf": "application/pdf",
  "zip": "application/zip",
  "gz": "application/gzip",
  "tar": "application/x-tar",
  "bz2": "application/x-bzip2",
  "7z": "application/x-7z-compressed",
  "wasm": "application/wasm",
  "mp4": "video/mp4",
  "webm": "video/webm",
  "mp3": "audio/mpeg",
  "m4a": "audio/mp4",
  "flac": "audio/flac",
  "wav": "audio/wav",
  "ogg": "audio/ogg"
}

# The `application/` types that are text, besides `text/*` and any `+json` or `+xml` type.
TEXT_TYPES = Set.new([
  "application/json",
  "application/javascript",
  "application/xml",
  "application/yaml",
  "application/toml",
])

## Returns the media type of a file by its extension, or `fallback` (default `application/octet-stream`) when there is
## none or it is not in the table, in any case. `path` is read in one of two ways:
##
## - An extension: a text that starts with `.`, has no other `.` and has no `/` or `\` (`.css`) is that extension.
## - A path: the part after the last `/`, once the query string (from the first `?`) and the fragment (from the first
##   `#`) are cut, with the extension of Ruby's `File.extname`. The last extension counts (`archive.tar.gz` is `gz`)
##   and a leading dot does not start one (`dir/.json` has none, `.env.json` has `json`).
##
## A name with no dot (`css`, `README`) has no extension, so it gives `fallback`.
export def mime_type(path: String, fallback: String = "application/octet-stream") -> String
  ext = extension(path.split("?")[0].split("#")[0])
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

# The lowercase extension of `text`, or "" when there is none.
def extension(text: String) -> String
  pieces = text.split(".")
  if text.start_with?(".") and pieces.size == 2 and !text.include?("/") and !text.include?("\\")
    return pieces[1].downcase
  end
  # Dots at the start of the name belong to the name, as in File.extname.
  name = text.split("/").last
  parts = name.split(".")
  first = 0
  while first < parts.size and parts[first].empty?
    first = first + 1
  end
  if parts.size - first < 2
    return ""
  end
  return parts.last.downcase
end
