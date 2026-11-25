---
title: Texto y datos
weight: 2
description: Trabaja con texto y números, busca y reemplaza texto con expresiones regulares, lee y escribe JSON y TOML, codifica URL, escapa HTML y gestiona cookies, halla el tipo de medio de un archivo, lee la hora Unix como fecha UTC y como texto RFC 3339, empaqueta números en bytes, calcula hashes y firma bytes, y genera bytes aleatorios seguros.
source_hash: "c01abdbab5d3"
---

- Usa [String](/library/text-and-data/string/) para cortar, buscar, cambiar y convertir texto, y para convertirlo en números.
- Usa [Regex](/library/text-and-data/regex/) (`std/regex`) para buscar, extraer, reemplazar y dividir texto con expresiones regulares.
- Usa [Int y Float](/library/text-and-data/numbers/) para convertir entre `Int`, `Float` y `String`, para redondear, acotar y sacar raíces cuadradas, y para trabajar con bits.
- Usa [JSON](/library/text-and-data/json/) para mover datos hacia dentro y hacia fuera de los programas, con una forma conocida (estructuras) o sin ella.
- Usa [Datos binarios](/library/text-and-data/binary/) (`std/binary`) para leer y escribir números en un `Bytes`, y para enmarcar mensajes.
- Usa [Term](/library/text-and-data/term/) (`Term.encode`, `Term.decode`) para escribir un valor como CBOR y leerlo de vuelta, una forma binaria compacta que conserva claves `Int`, los bits exactos de un `Float`, `nil` y `Bytes`.
- Usa [TOML](/library/text-and-data/toml/) (`std/toml`) para leer y escribir documentos TOML 1.0, como los archivos de configuración.
- Usa [HTML](/library/text-and-data/html/) (`std/html`) para escapar y desescapar texto HTML.
- Usa [Plantillas EAG](/library/text-and-data/eag/) (`<<~EAG` y `std/eag`) para crear texto a partir de una plantilla con etiquetas ERB.
- Usa [Cookie](/library/text-and-data/cookie/) (`std/cookie`) para leer una cabecera `Cookie` y para escribir una cabecera `Set-Cookie`.
- Usa [MIME](/library/text-and-data/mime/) (`std/mime`) para hallar el tipo de medio de un archivo a partir de su nombre, y para saber qué tipos son texto.
- [UTC](/library/text-and-data/utc/) (`std/utc`) está obsoleto: usa las [fechas y horas](/library/io-and-system/time/) integradas de `Time`.
- Usa [URI](/library/text-and-data/uri/) (`std/uri`) para codificar y decodificar por porcentaje los componentes de una URL, y para leer y escribir cadenas de consulta.
- Usa las [funciones integradas de OpenSSL](/library/text-and-data/crypto/) para calcular el hash de una lista de bytes con MD5, SHA-1, SHA-256 o SHA-512, firmarla con HMAC-SHA256 o HMAC-SHA512, comparar MAC en tiempo constante, cifrar con AES-256-GCM, calcular hashes de contraseñas con PBKDF2 y scrypt, cifrar y calcular MAC de datos de pago con Triple DES y CMAC, cifrar con una clave pública RSA, y generar bytes, hexadecimal y UUID aleatorios seguros.
- Usa [Zlib](/library/text-and-data/zlib/) para comprimir bytes, archivos y flujos con DEFLATE, zlib y gzip.
- Usa [Base64 y hexadecimal](/library/text-and-data/base64/) para escribir bytes como texto y leerlos de vuelta.

Las páginas del tour [Cadenas e interpolación](/tour/strings/) y [Números](/tour/numbers/) son un inicio breve.
