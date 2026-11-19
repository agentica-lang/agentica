---
title: Archivo comprimido
weight: 8
description: El módulo Archive, que extrae los archivos con nombre de un TAR o un ZIP.
source_hash: "e7e82c9cf78b"
---

`Archive` copia a un directorio privado nuevo una lista de permitidos explícita de archivos regulares de un TAR o de un ZIP. Las únicas operaciones son los dos extractores: no hay una función para extraer todo, ni patrones con comodines, ni listado, ni escritor de ZIP.

```signature
Archive.extract_tar(src: String, members: List[String], dest_dir: String, options: Archive.Options = Archive.Options()) -> Result[List[Int]]
Archive.extract_zip(src: String, members: List[String], dest_dir: String, options: Archive.Options = Archive.Options()) -> Result[List[Int]]
```

`extract_tar` lee un `.tar` plano o un `.tar.gz` comprimido con gzip (lo distingue por la firma de gzip al principio), escribe cada miembro bajo `dest_dir` y devuelve las cantidades de bytes en el orden de los miembros. `members` tiene de 1 a 256 rutas del archivo; un `./` inicial es opcional, así que `./lib.so` y `lib.so` son el mismo miembro. Todo fallo es un `error` y nunca detiene el programa; un destino incompleto se conserva si hay error y solo se puede usar cuando la llamada devuelve `ok`.

```agentica {mode="check"}
import Archive from "std/archive"

def main() -> Void
  case Archive.extract_tar("ffi.tar.gz", ["libssl.so", "include/ssl.h"], "vendor")
    ok(counts) -> puts("wrote #{counts}")
    error(message) -> IO.warn("cannot unpack: #{message}")
  end
end
```

- `Archive.Options()`, el predeterminado, es un plazo de 30 s con como máximo 268435456 bytes extraídos; `timeout_ms` va de 1 a 86400000 y `max_output_bytes` de 1 a 1073741824.
- El destino se crea privado y no debe existir; cada archivo se crea sin sobrescribir nunca, y sus carpetas padre se crean bajo la nueva base. Solo se escriben archivos regulares: los enlaces, los directorios, los dispositivos y los elementos dispersos se rechazan si están seleccionados y se omiten si no.
- Los nombres conservan la grafía que tienen en el archivo: se rechazan las rutas absolutas, las letras de unidad, los recursos compartidos UNC, las barras invertidas, los dos puntos, los bytes NUL y los segmentos `.` o `..`, como también dos miembros que solo difieren en mayúsculas. La llamada recorre todo el contenedor hasta los dos bloques finales de ceros, así que un duplicado, un miembro que falta o una suma de comprobación incorrecta después de un archivo seleccionado sigue siendo un error.
- Límites fijos: el recorrido del TAR en bruto es de como máximo 1073741824 bytes, un origen comprimido con gzip de como máximo 268435456 bytes comprimidos, 8192 elementos, 1024 bytes de nombre y 65536 bytes de datos de extensión PAX y GNU. Las cabeceras siguen USTAR con los registros PAX `path` y `size` y los nombres largos de GNU; los demás registros PAX se ignoran y los elementos dispersos se rechazan.
- Un TAR comprimido con gzip se lee con `Zlib.gunzip`, que acepta cada miembro de gzip con su CRC y su tamaño verificados: el TAR que llevan debe seguir terminando en los dos bloques finales de ceros y en relleno de ceros (un segundo archivo después es un error), y ningún byte puede seguir al último miembro. El origen debe ser un archivo regular estable del que el llamador es propietario: se comprueba con `File.lstat`, que no puede garantizar que una condición de carrera al renombrar no lo haya reemplazado después.
- `extract_zip` lee un `.zip` clásico de un solo disco, solo con elementos almacenados (método 0) y con deflate sin envoltorio (método 8): se rechazan ZIP64, el cifrado, las imágenes de varios discos, los archivos divididos, los autoextraíbles y los demás métodos. El lector hace tres pasadas que solo avanzan, con lecturas de 64 KiB, así que el origen mide como máximo 268435456 bytes y las pasadas juntas leen como máximo 768 MiB de bytes físicos. Los nombres son UTF-8 estricto cuando el flag 11 está activo y ASCII puro en otro caso; los bytes CP437 heredados se rechazan. Cada registro local se valida incluso después de los archivos seleccionados. Los payloads seleccionados se leen en flujo dentro de su ventana comprimida exacta, con su CRC32 y su tamaño sin comprimir verificados; los no seleccionados se saltan solo por tamaño y desplazamiento, sin descomprimirse ni comprobar su CRC.
