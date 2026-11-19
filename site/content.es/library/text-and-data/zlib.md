---
title: Zlib
weight: 7
description: Las funciones integradas de Zlib y los pasos de Lazy, que comprimen bytes, archivos y flujos con DEFLATE, zlib y gzip.
source_hash: "80e94fcab114"
---

`Zlib` reúne las funciones integradas de compresión para bytes en el envoltorio zlib (RFC 1950, el predeterminado de Ruby y de Python) y en gzip (RFC 1952). Los archivos y los flujos pasan por los pasos de [Lazy](/library/data-structures/lazy/#zlib-steps), que también hablan DEFLATE crudo (RFC 1951). La VM los calcula con zlib, la biblioteca que ya enlaza; nada está escrito en Agentica.

No hay detección automática, ni diccionario, ni opción de metadatos. Los decodificadores son estrictos a propósito: se verifica la suma de comprobación, y un byte después del final es un error. `Zlib.inflate` y `lazy.inflate` leen un flujo, y cualquier byte después de él es un error. `Zlib.gunzip` y `lazy.gunzip` leen cada miembro de un archivo gzip (RFC 1952, sección 2.2), como `gzip.decompress` de Python, y su salida es la salida de los miembros uno tras otro; un miembro puede estar vacío. Un byte después del último miembro que no empieza otro miembro es un error, incluido el relleno de ceros (Python lo salta), y un miembro truncado o con una suma de comprobación incorrecta es un error.

## Bytes {#bytes}

```signature
Zlib.deflate(data: Bytes, level: Int = 6, max_bytes: Int = 1048576) -> Result[Bytes]
Zlib.inflate(data: Bytes, max_bytes: Int = 1048576) -> Result[Bytes]
Zlib.gzip(data: Bytes, level: Int = 6, max_bytes: Int = 1048576) -> Result[Bytes]
Zlib.gunzip(data: Bytes, max_bytes: Int = 1048576) -> Result[Bytes]
Zlib.crc32(data: Bytes, seed: Int = 0) -> Result[Int]
```

`Zlib.deflate` comprime bytes al envoltorio zlib y `Zlib.gzip` a gzip, con `level` de 0 a 9; una entrada vacía es válida y da el flujo o el miembro vacíos. `Zlib.inflate` descomprime un flujo, comprobando la suma de comprobación Adler, y `Zlib.gunzip` cada miembro de un archivo gzip, comprobando el CRC y el tamaño de cada uno. Una entrada comprimida vacía falla.

```agentica {mode="check"}
def main() -> Void
  packed = Zlib.deflate("hi".bytes).unwrap!
  puts(Test.eq(Zlib.inflate(packed).unwrap!, "hi".bytes))
  gz = Zlib.gzip("hi".bytes, 9).unwrap!
  puts(Test.eq(Zlib.gunzip(gz, 2).unwrap!, "hi".bytes))
end
```

```text
ok()
ok()
```

- `data` tiene como máximo 1048576 bytes y `max_bytes`, el límite de la salida, va de 1 a 1048576; una salida que lo supere es un error.
- Los datos son [`Bytes`](/library/data-structures/bytes/), como los dan `s.bytes`, `IO.read_bytes` y `File.read_bytes`; `Bytes.from_list` crea uno a partir de una `List[Int]`.
- `Zlib.crc32` es el CRC32 (RFC 1952) de `data` encadenado tras `seed`: omite la semilla la primera vez (vale 0), y luego pasa cada trozo siguiente con el resultado anterior, así que los miembros gzip y los elementos de un ZIP pueden calcular su suma de comprobación trozo a trozo. Una entrada vacía devuelve `seed` sin cambios. `data` tiene como máximo 1048576 bytes y `seed` va de 0 a 4294967295; si no, es un error de contrato.

```agentica {mode="check"}
def main() -> Void
  digits = "123456789".bytes
  puts(Test.eq(Zlib.crc32(digits).unwrap!, 3421780262))
  first = Zlib.crc32(digits.take(3)).unwrap!
  puts(Test.eq(Zlib.crc32(digits.drop(3), first).unwrap!, 3421780262))
  puts(Test.eq(Zlib.crc32("".bytes, 4294967295).unwrap!, 4294967295))
end
```

```text
ok()
ok()
ok()
```

## Flujos {#streams}

```signature
lazy.deflate(level: Int = 6, raw: Bool = false) -> Lazy[Bytes]
lazy.inflate(raw: Bool = false, max_bytes: Int = 1073741824) -> Lazy[Bytes]
lazy.gzip(level: Int = 6) -> Lazy[Bytes]
lazy.gunzip(max_bytes: Int = 1073741824) -> Lazy[Bytes]
lazy.write_bytes(path: String, timeout_ms: Int = 30000) -> Result[Int]
```

Un flujo es un `Lazy[Bytes]` de trozos de bytes. [`File.chunks`](/library/data-structures/lazy/#filechunks) lee un archivo regular en trozos, los cuatro pasos comprimen o descomprimen los trozos que pasan, y `write_bytes` los escribe en un archivo, creado o truncado, y devuelve los bytes escritos. La memoria queda acotada a un trozo, así que un archivo que supera con creces el límite de 1 MiB de las llamadas de bytes se convierte sin retenerlo en memoria.

```agentica {mode="check"}
def main() -> Void
  case File.chunks("notes.txt").gzip.write_bytes("notes.txt.gz")
    ok(bytes) -> puts("#{bytes} bytes written")
    error(message) -> IO.warn("cannot compress: #{message}")
  end

  puts(File.chunks("notes.txt.gz").gunzip.reduce(0) do |n, chunk| n + chunk.size end)
end
```

- `raw: true` es DEFLATE crudo, sin envoltorio y sin suma de comprobación. Se aceptan trozos de cualquier tamaño, también los vacíos; un trozo de salida tiene como máximo 65536 bytes.
- El `max_bytes` de un decodificador (al menos 1) limita toda su salida mientras fluye: la ejecución termina con un error antes de que se pase un byte que lo supere. Un truncamiento, una suma de comprobación incorrecta y un byte sobrante también terminan la ejecución con un error, y un `level` o un `max_bytes` incorrectos son el error de la ejecución.
- La ejecución termina con el primer error, y una ejecución que se detiene pronto (`first`, `find`, un `try` que falla en un bloque, un error o una cancelación) libera su flujo zlib y cierra su archivo.
- Solo `File.chunks` y `write_bytes` tienen el efecto del sistema de archivos: con `--deny-fs` (o `--sandbox`) dan un error que empieza con `denied: --deny-fs`, mientras que los pasos y las llamadas de bytes funcionan en cualquier lugar.
- `Zlib` es un nombre de tipo reservado.
