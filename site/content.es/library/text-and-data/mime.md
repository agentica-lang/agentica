---
title: MIME (std)
weight: 12
description: El módulo std/mime, que da el tipo de medio de un archivo a partir de su nombre y dice qué tipos son texto.
source_hash: "3035ace27153"
---

`std/mime` está escrito en Agentica: `import MIME from "std/mime"`. `mime_type` y su argumento de respaldo son los de `Rack::Mime.mime_type` de Ruby. Asigna una extensión de archivo a un tipo de medio (el valor de una cabecera `Content-Type`), con una tabla fija y pequeña de los tipos que envía un servidor web, que es propia de este módulo. Nada en él detiene el programa, sea cual sea la entrada.

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

## mime_type {#mime_type}

`mime_type` lee su argumento de dos maneras. Un texto que empieza con un punto, no tiene otro punto y no tiene `/` ni `\` es una extensión, como en Rack: `.css` da `text/css`. Cualquier otro texto es una ruta: se cortan la cadena de consulta (desde el primer `?`) y el fragmento (desde el primer `#`), y luego se lee la parte después del último `/` con la regla de `File.extname` de Ruby. Solo cuenta la última extensión, sin distinguir mayúsculas de minúsculas, así que `backup.tar.gz` es un archivo `.gz`. Un punto al inicio del nombre no empieza una extensión, así que `public/.json` no tiene ninguna, y `.env.json` es `json`.

Un nombre sin punto (`css`, `README`), una extensión vacía (`a.`) y una extensión que no está en la tabla dan todos `fallback`, que es `application/octet-stream` salvo que pases otro.

## La tabla {#the-table}

La tabla tiene: `html htm css js mjs cjs json map jsonld webmanifest txt csv xml xhtml rss atom ics md yaml yml toml agc svg png jpg jpeg gif webp avif ico bmp tif tiff woff woff2 ttf otf pdf zip gz tar bz2 7z wasm mp4 webm mp3 m4a flac wav ogg`. No pretende ser completa, y `agc` es `text/plain`.

Cuando las fuentes no coinciden, usa el tipo registrado: `js`, `mjs` y `cjs` son `text/javascript` (RFC 9239, donde Rack y el Python antiguo dicen `application/javascript`), `xml` es `application/xml`, `yaml` y `yml` son `application/yaml` e `ico` es `image/vnd.microsoft.icon`. `wav` es `audio/wav`, el tipo común (el registrado es `audio/vnd.wave`), y `tar`, `bz2` y `7z` usan sus tipos comunes con `x-`, que no tienen forma registrada.

## Charset {#charset}

Los tipos van sin parámetros, como en Rack: ninguno termina en `; charset=utf-8`. `text?` dice cuándo un archivo contiene texto, para que puedas añadir el parámetro. Ruby no tiene una función así (lo más cercano es `MIME::Type#ascii?` de la gema mime-types); existe para que un servidor pueda añadir el charset. Es verdadera para `text/*`, para cualquier tipo `+json` o `+xml`, y para `application/json`, `javascript`, `xml`, `yaml` y `toml`. Ignora los parámetros y las mayúsculas, así que también sirve con un `Content-Type` que leíste. Saber si un archivo es UTF-8 de verdad depende de ti.
