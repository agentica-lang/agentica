---
title: Base64 y hexadecimal
weight: 8
description: Las funciones integradas Base64 y OpenSSL.Digest, que escriben bytes como texto en base64 o hexadecimal y los leen de vuelta.
source_hash: "14ea09d07dd1"
---

`Base64` escribe bytes como texto base64 de RFC 4648 y lo lee de vuelta, con las formas del módulo `Base64` de Ruby y con los mismos resultados. `OpenSSL.Digest.hexencode` escribe dígitos hexadecimales como lo hace Ruby, y `OpenSSL.Digest.hexdecode`, el nombre propio de Agentica para su inverso, los lee de vuelta. La VM los calcula en C puro; nada está escrito en Agentica.

Reciben y devuelven [`Bytes`](/library/data-structures/bytes/), como lo hace `OpenSSL.Digest.sha256`. Para texto, codifica sus bytes UTF-8 desde `s.bytes` y decodifica los bytes de vuelta con `String.from_bytes(b)`.

## Base64 {#base64}

```signature
Base64.strict_encode64(data: Bytes) -> String
Base64.encode64(data: Bytes) -> String
Base64.urlsafe_encode64(data: Bytes, padding: Bool = true) -> String
Base64.strict_decode64(text: String) -> Result[Bytes]
Base64.urlsafe_decode64(text: String) -> Result[Bytes]
Base64.decode64(text: String) -> Bytes
```

- `Base64.strict_encode64` da base64 con relleno en una sola línea. `Base64.encode64` da el mismo texto en líneas de 60 caracteres, cada una terminada en un salto de línea, como lo escribe Ruby; sin bytes, da `""`.
- `Base64.urlsafe_encode64` usa el alfabeto de URL y de nombres de archivo, con `-` y `_` en lugar de `+` y `/`. Con `padding` en false deja fuera el `=` del final, como lo hacen los JSON Web Tokens.
- `Base64.strict_decode64` solo acepta base64 con relleno y sin nada más en el texto, ni siquiera un salto de línea, y con cero bits sobrantes en el último grupo; cualquier otra cosa es `error("invalid base64")`.
- `Base64.urlsafe_decode64` añade el `=` que falta a un texto que no termina en uno, y luego decodifica como lo hace `strict_decode64`. Acepta los dos alfabetos.
- `Base64.decode64` nunca falla: omite cada carácter fuera del alfabeto (saltos de línea, espacios), se detiene en un `=` en el tercer o cuarto lugar de un grupo, y descarta un último carácter suelto. Úsalo para texto de `encode64`; usa las formas estrictas para rechazar una entrada incorrecta.

```agentica
def main() -> Void
  data = "hello, world".bytes
  puts(Base64.strict_encode64(data))
  puts(Base64.urlsafe_encode64(Bytes.from_list([251, 255]).unwrap!, false))
  back = Base64.strict_decode64("aGVsbG8sIHdvcmxk").unwrap!
  puts(String.from_bytes(back).unwrap!)
  puts(Base64.strict_decode64("aGVsbG8\n"))
  puts(Base64.decode64("aGVs\nbG8=\n").to_a)
end
```

```output
aGVsbG8sIHdvcmxk
-_8
hello, world
error("invalid base64", kind: "argument")
[104, 101, 108, 108, 111]
```

## Hexadecimal {#hex}

```signature
OpenSSL.Digest.hexencode(data: Bytes) -> String
OpenSSL.Digest.hexdecode(text: String) -> Result[Bytes]
```

`OpenSSL.Digest.hexencode` da dos dígitos hexadecimales en minúscula por byte. `OpenSSL.Digest.hexdecode` acepta un número par de dígitos hexadecimales en cualquier caso; una longitud impar o cualquier otro carácter, incluidos un espacio o `0x`, es `error("invalid hex")`.

```agentica
def main() -> Void
  puts(OpenSSL.Digest.hexencode(OpenSSL.Digest.sha256("".bytes)).slice(0, 16))
  puts(OpenSSL.Digest.hexdecode("00FFa0").unwrap!.to_a)
  puts(OpenSSL.Digest.hexdecode("abc").ok?)
end
```

```output
e3b0c44298fc1c14
[0, 255, 160]
false
```

- El tiempo crece con el tamaño de la entrada. Ninguna necesita una etiqueta de efecto: solo leen lo que está en su argumento.
- `Base64` es un nombre de tipo reservado.
