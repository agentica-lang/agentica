---
title: OpenSSL
weight: 6
description: La familia de integrados OpenSSL. OpenSSL.Digest calcula resúmenes de bytes con MD5, SHA-1, SHA-256 y SHA-512; OpenSSL.HMAC firma bytes con una clave y compara MAC en tiempo constante; OpenSSL.Cipher cifra con AES-256-GCM y Triple DES CBC; OpenSSL.KDF calcula hash de contraseñas con PBKDF2 y scrypt; OpenSSL.CMAC da los MAC de los formatos de pago; OpenSSL.RSA cifra con una clave pública, y OpenSSL.Random da bytes aleatorios seguros, hexadecimal y UUID.
source_hash: "343f2dff2281"
---

La VM calcula estos integrados con OpenSSL, la biblioteca que ya usa para TLS; nada está escrito en Agentica. Son los miembros de la familia `OpenSSL`, que se escriben `OpenSSL.Member.function`, y sus nombres y formas siguen a Ruby:

- `OpenSSL.Digest`: los resúmenes criptográficos, como `Digest::SHA256.digest` y `hexdigest` de Ruby.
- `OpenSSL.HMAC`: los MAC, como `OpenSSL::HMAC`, y la comparación en tiempo constante `OpenSSL.HMAC.secure_compare`, como `OpenSSL.secure_compare` de Ruby.
- `OpenSSL.Cipher`: AES-256-GCM, como `OpenSSL::Cipher.new("aes-256-gcm")`, y Triple DES CBC.
- `OpenSSL.KDF`: los hash de contraseñas, como `OpenSSL::KDF`.
- `OpenSSL.CMAC`: los CMAC de los formatos de pago.
- `OpenSSL.RSA`: cifrado con una clave pública RSA, como `OpenSSL::PKey::RSA`.
- `OpenSSL.Random`: los números aleatorios seguros, como `SecureRandom` de Ruby.

`OpenSSL` es el único nombre reservado de la familia: `Digest`, `Cipher` o `HMAC` siguen libres para un tipo o un alias de importación del programa. Un miembro que la familia no tiene, como `OpenSSL.Ciphr`, es `CHECK-UNKNOWN-NAME`, y su ayuda lista los miembros.

```agentica {expect="CHECK-UNKNOWN-NAME"}
def main() -> Void
  puts(OpenSSL.Digst.sha256_hexdigest("abc".bytes))
end
```

## Resúmenes criptográficos {#digests}

```signature
OpenSSL.Digest.md5(data: Bytes) -> Bytes
OpenSSL.Digest.md5_hexdigest(data: Bytes) -> String
OpenSSL.Digest.sha1(data: Bytes) -> Bytes
OpenSSL.Digest.sha1_hexdigest(data: Bytes) -> String
OpenSSL.Digest.sha256(data: Bytes) -> Bytes
OpenSSL.Digest.sha256_hexdigest(data: Bytes) -> String
OpenSSL.Digest.sha512(data: Bytes) -> Bytes
OpenSSL.Digest.sha512_hexdigest(data: Bytes) -> String
```

`OpenSSL.Digest.sha256` da el resumen SHA-256 de un [`Bytes`](/library/data-structures/bytes/) como un `Bytes` de 32 bytes. `OpenSSL.Digest.md5`, `OpenSSL.Digest.sha1` y `OpenSSL.Digest.sha512` dan 16, 20 y 64. Cada forma `_hexdigest` da el mismo resumen en hexadecimal en minúsculas, el texto que [`OpenSSL.Digest.hexencode`](/library/text-and-data/base64/#hex) escribe para los bytes. Para calcular el resumen de un texto, usa sus bytes UTF-8 desde `s.bytes`; un `List[Int]` se convierte en un `Bytes` con `Bytes.from_list`.

```agentica
def main() -> Void
  digest = OpenSSL.Digest.sha256("abc".bytes)
  puts(digest.size)
  puts(OpenSSL.Digest.hexencode(digest))
  puts(OpenSSL.Digest.sha256_hexdigest("".bytes))
  puts(OpenSSL.Digest.sha512("abc".bytes).size)
  puts(OpenSSL.Digest.md5_hexdigest("abc".bytes))
  puts(digest == OpenSSL.Digest.sha256("abc".bytes))
end
```

```output
32
ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
64
900150983cd24fb0d6963f7d28e17f72
true
```

- MD5 y SHA-1 están rotos para la seguridad: úsalos solo donde un formato los necesite, como ETags, nombres de objetos de git o una API antigua. Usa SHA-256 o SHA-512 para todo lo demás.
- Dos resúmenes se comparan con `==`. `==` no es de tiempo constante: para comprobar un MAC o un token que has recibido, usa [`OpenSSL.HMAC.secure_compare`](#checking-a-mac).
- Un OpenSSL del sistema en modo solo FIPS no tiene MD5 ni SHA-1; `OpenSSL.Digest.md5` y `OpenSSL.Digest.sha1` (y sus formas `_hexdigest`) detienen entonces el programa con `RUNTIME-INTERNAL`. Los binarios de release usan su propio OpenSSL, que tiene los cuatro.
- El tiempo crece con los datos. Una llamada nunca se parte, pero cuenta para el turno de la tarea, así que otras tareas siguen poco después de un resumen grande.
- No necesitan etiqueta de efecto: no leen nada fuera de su argumento.

Un `List[Int]` no es un `Bytes`; conviértelo una vez con `Bytes.from_list`, que da un error para un elemento fuera de 0 a 255.

```agentica {expect="CHECK-TYPE-MISMATCH"}
def main() -> Void
  puts(OpenSSL.Digest.sha256_hexdigest([1, 2]))
end
```

## HMAC {#hmac}

```signature
OpenSSL.HMAC.sha256(key: Bytes, data: Bytes) -> Bytes
OpenSSL.HMAC.sha256_hexdigest(key: Bytes, data: Bytes) -> String
OpenSSL.HMAC.sha512(key: Bytes, data: Bytes) -> Bytes
OpenSSL.HMAC.sha512_hexdigest(key: Bytes, data: Bytes) -> String
OpenSSL.HMAC.secure_compare(bytes: Bytes, other: Bytes) -> Bool
```

`OpenSSL.HMAC.sha256` da el HMAC-SHA256 (RFC 2104) de `data` con `key`: un `Bytes` de 32 bytes. `OpenSSL.HMAC.sha512` da los 64 bytes de HMAC-SHA512. Cada forma `_hexdigest` da el mismo MAC en hexadecimal en minúsculas, como hace `OpenSSL::HMAC.hexdigest("SHA256", key, data)` de Ruby. La clave puede tener cualquier longitud, también vacía; una clave más larga que el bloque del hash (64 bytes para SHA-256, 128 para SHA-512) se resume primero, como dice RFC 2104. Firman payloads de webhooks, JSON Web Tokens con HS256 (el MAC en base64url sin relleno) y URLs firmadas.

```agentica
def main() -> Void
  key = "key".bytes
  data = "The quick brown fox jumps over the lazy dog".bytes
  puts(OpenSSL.HMAC.sha256_hexdigest(key, data))
  puts(OpenSSL.HMAC.sha512(key, data).size)
  puts(Base64.urlsafe_encode64(OpenSSL.HMAC.sha256(key, data), false))
end
```

```output
f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8
64
97yD9DBThCSxMpjmqm-xQ-9NWaFJRhdZl0edvC0aPNg
```

- El tiempo crece con la clave y los datos, como en los resúmenes, y no necesitan etiqueta de efecto.

### Comprobar un MAC {#checking-a-mac}

Para comprobar un MAC, una firma o un token que has recibido, compáralo con el que calculas usando `OpenSSL.HMAC.secure_compare(a, b)`, nunca con `==`. `==` sobre `Bytes` no es de tiempo constante: se detiene en el primer byte distinto, así que su tiempo puede decirle a un atacante cuánto de un MAC falsificado es correcto. `OpenSSL.HMAC.secure_compare` da `true` cuando los dos valores tienen los mismos bytes, en un tiempo que no depende de los bytes ni de dónde difieren: como `OpenSSL.secure_compare` de Ruby, compara los resúmenes SHA-256 de ambos con `CRYPTO_memcmp` de OpenSSL.

```agentica
def main() -> Void
  key = "key".bytes
  body = "{\"event\":\"paid\"}".bytes
  received = OpenSSL.HMAC.sha256(key, body)
  puts(OpenSSL.HMAC.secure_compare(OpenSSL.HMAC.sha256(key, body), received))
  puts(OpenSSL.HMAC.secure_compare(OpenSSL.HMAC.sha256(key, "{}".bytes), received))
  puts(OpenSSL.HMAC.secure_compare(received, received.take(16)))
end
```

```output
true
false
false
```

- Los valores de otra longitud dan `false`. El tiempo crece con las dos longitudes, así que muestra cuánto miden los valores, nunca lo que contienen.
- Para comprobar un MAC en hexadecimal, como el de una cabecera de webhook, decodifícalo primero con [`OpenSSL.Digest.hexdecode`](/library/text-and-data/base64/#hex); un `error` ahí significa un MAC no válido.
- No necesita etiqueta de efecto.

## AES-256-GCM {#aes-256-gcm}

```signature
OpenSSL.Cipher.aes_256_gcm_encrypt(key: Bytes, iv: Bytes, data: Bytes, auth_data: Bytes = "".bytes) -> Result[Bytes]
OpenSSL.Cipher.aes_256_gcm_decrypt(key: Bytes, iv: Bytes, data: Bytes, auth_data: Bytes = "".bytes) -> Result[Bytes]
```

`OpenSSL.Cipher.aes_256_gcm_encrypt` cifra `data` con AES-256-GCM, como hace `OpenSSL::Cipher.new("aes-256-gcm")` de Ruby, y da el texto cifrado con la etiqueta de 16 bytes añadida al final: 16 bytes más que `data`. `OpenSSL.Cipher.aes_256_gcm_decrypt` deshace esa forma. Solo da el texto en claro cuando la etiqueta coincide con la clave, el IV, el texto cifrado y `auth_data`; cualquier cambio da un `error`, y nada del texto en claro. `auth_data` se autentica pero no se cifra: una cabecera, un id de registro o una versión que el receptor lee en claro y no debe cambiarse.

```agentica
def main() -> Void
  key = OpenSSL.Digest.hexdecode("feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308").unwrap!
  iv = OpenSSL.Digest.hexdecode("cafebabefacedbaddecaf888").unwrap!
  header = "record 7".bytes
  sealed = OpenSSL.Cipher.aes_256_gcm_encrypt(key, iv, "attack at dawn".bytes, header).unwrap!
  puts(sealed.size)
  puts(OpenSSL.Digest.hexencode(sealed))
  opened = OpenSSL.Cipher.aes_256_gcm_decrypt(key, iv, sealed, header).unwrap!
  puts(String.from_bytes(opened).unwrap!)
  puts(OpenSSL.Cipher.aes_256_gcm_decrypt(key, iv, sealed, "record 8".bytes).ok?)
  puts(OpenSSL.Cipher.aes_256_gcm_decrypt(key, iv, sealed).ok?)
end
```

```output
30
ea6887b402b95b8325065a07f21f0e754294b29d6398414d4a28a9fb3317
attack at dawn
false
false
```

- La clave tiene 32 bytes; genérala con [`OpenSSL.Random.random_bytes(32)`](#random) o derívala con [`OpenSSL.KDF`](#password-hashing).
- El IV (el nonce) tiene 12 bytes y nunca debe usarse dos veces con la misma clave: dos mensajes con una clave y un IV iguales filtran el XOR de sus textos en claro y permiten a cualquiera falsificar etiquetas. Genera uno nuevo para cada mensaje con `OpenSSL.Random.random_bytes(12)` y envíalo junto a los bytes cifrados; no tiene que ser secreto.
- Una clave o un IV de otro tamaño, bytes cifrados más cortos que la etiqueta, o más de 2^36 - 32 bytes para cifrar dan un `error`, antes de cualquier trabajo.
- El tiempo crece con los datos y con `auth_data`, y no necesitan etiqueta de efecto.

## Hash de contraseñas {#password-hashing}

```signature
OpenSSL.KDF.pbkdf2_hmac_sha256(password: Bytes, salt: Bytes, iterations: Int, length: Int) -> Result[Bytes]
OpenSSL.KDF.scrypt(password: Bytes, salt: Bytes, n: Int, r: Int, p: Int, length: Int) -> Result[Bytes]
```

Un hash de contraseña es lento a propósito, para que adivinar contraseñas a partir de un hash robado también sea lento. `OpenSSL.KDF.pbkdf2_hmac_sha256` da `length` bytes de PBKDF2 (RFC 8018) con HMAC-SHA256, como hace `OpenSSL::KDF.pbkdf2_hmac` de Ruby con `hash: "SHA256"`; su costo es `iterations`. `OpenSSL.KDF.scrypt` da `length` bytes de scrypt (RFC 7914), como hace `OpenSSL::KDF.scrypt` de Ruby, que además necesita memoria: `n` es el costo, una potencia de 2, `r` el tamaño de bloque y `p` la paralelización. Guarda la sal (16 bytes aleatorios por contraseña) y los parámetros junto al hash, vuelve a derivar a partir de la contraseña dada y compara con [`OpenSSL.HMAC.secure_compare`](#checking-a-mac). Las mismas llamadas derivan una clave de cifrado a partir de una frase de contraseña.

```agentica
def main() -> Void
  salt = OpenSSL.Digest.hexdecode("8d2f1e0a9c6b5a4f3e2d1c0b9a8f7e6d").unwrap!
  stored = OpenSSL.KDF.pbkdf2_hmac_sha256("correct horse".bytes, salt, 600000, 32).unwrap!
  puts(OpenSSL.Digest.hexencode(stored))
  attempt = OpenSSL.KDF.pbkdf2_hmac_sha256("correct horse".bytes, salt, 600000, 32).unwrap!
  puts(OpenSSL.HMAC.secure_compare(attempt, stored))
  wrong = OpenSSL.KDF.pbkdf2_hmac_sha256("Correct horse".bytes, salt, 600000, 32).unwrap!
  puts(OpenSSL.HMAC.secure_compare(wrong, stored))
  key = OpenSSL.KDF.scrypt("correct horse".bytes, salt, 16384, 8, 1, 32).unwrap!
  puts(OpenSSL.Digest.hexencode(key))
  puts(OpenSSL.KDF.pbkdf2_hmac_sha256("pw".bytes, salt, 0, 32).ok?)
end
```

```output
685d9f0664089a1dceb6bfec27db35482562804c30a3669a9224cea9240f6609
true
false
8840f2f4d9d646327d081885af746152d33cef9cb0e22384713790a75b136ce2
false
```

- `iterations` es al menos 1 y `length` va de 1 a 1048576; la contraseña y la sal tienen como máximo 1048576 bytes cada una.
- El `n` de scrypt es mayor que 1 y menor que 2^(16 * r), `r` y `p` son al menos 1 con `r * p` menor que 2^30, y la memoria, 128 * r * (n + p + 2) bytes, es como máximo 1025 MiB. Esa memoria es nativa, fuera del recolector de basura, así que cada llamada puede ocupar hasta cerca de 1 GiB mientras se ejecuta. Con `n = 16384` y `r = 8` ocupa unos 16 MiB.
- Cualquier otro valor da un `error`, antes de cualquier trabajo.
- La hoja de referencia rápida de OWASP sobre almacenamiento de contraseñas recomienda 600000 iteraciones para PBKDF2-HMAC-SHA256, y scrypt con `n = 131072`, `r = 8` y `p = 1`.
- Una llamada se ejecuta en el grupo de hilos de cómputo (los hilos de las llamadas nativas de `compute def`): la tarea espera, y las demás tareas siguen ejecutándose. La llamada de una tarea cancelada se omite si aún no ha empezado; una vez empezada, llega hasta su final y su clave se descarta. Dentro de un callback de código nativo, una llamada es `RUNTIME-NATIVE-CALLBACK`, porque ese callback no puede esperar. Una llamada iniciada no se puede detener, ni con `--max-steps` ni con una señal, y ocupa un hilo del grupo de cómputo hasta que termina. Por eso el trabajo tiene un límite, y una llamada válida tarda decenas de segundos como mucho: `iterations * ceil(length / 32)` es como máximo 50000000 para PBKDF2, y `r * p * (n + 16)` como máximo 2^25 (33554432) para scrypt, unas 80 y 32 veces las cifras de OWASP de arriba.
- No necesitan etiqueta de efecto.

## Triple DES y CMAC {#triple-des-and-cmac}

```signature
OpenSSL.Cipher.des_ede3_cbc_encrypt(key: Bytes, iv: Bytes, data: Bytes) -> Result[Bytes]
OpenSSL.Cipher.des_ede3_cbc_decrypt(key: Bytes, iv: Bytes, data: Bytes) -> Result[Bytes]
OpenSSL.CMAC.aes(key: Bytes, data: Bytes) -> Result[Bytes]
OpenSSL.CMAC.des_ede3(key: Bytes, data: Bytes) -> Result[Bytes]
```

Los mensajes de pago usan Triple DES y CMAC: bloques PIN, valores de comprobación de clave y los MAC de los mensajes ISO 8583. Estos integrados son para esos formatos, no para diseños nuevos; Triple DES CBC no está autenticado, y sus bloques de 8 bytes son pequeños. Solo dan lo que da OpenSSL: los formatos de mensaje, BCD y los algoritmos de MAC ISO 9797-1 pertenecen a un paquete.

`OpenSSL.Cipher.des_ede3_cbc_encrypt` cifra `data` con Triple DES en modo CBC y sin relleno, como hace `OpenSSL::Cipher.new("des-ede3-cbc")` de Ruby con `padding = 0`, y `OpenSSL.Cipher.des_ede3_cbc_decrypt` lo descifra. La clave tiene 24 bytes, o 16 para una clave de dos claves (K1 K2, que funciona como K1 K2 K1); el IV tiene 8 bytes; los datos son bloques completos de 8 bytes, y el resultado tiene el mismo tamaño. Rellena los datos como indique tu formato antes de cifrarlos.

```agentica
def main() -> Void
  key = OpenSSL.Digest.hexdecode("0123456789abcdeffedcba9876543210").unwrap!
  iv = Bytes.from_list(List.repeat(0, 8)).unwrap!
  sealed = OpenSSL.Cipher.des_ede3_cbc_encrypt(key, iv, "PIN 1234".bytes).unwrap!
  puts(OpenSSL.Digest.hexencode(sealed))
  opened = OpenSSL.Cipher.des_ede3_cbc_decrypt(key, iv, sealed).unwrap!
  puts(String.from_bytes(opened).unwrap!)
  check_value = OpenSSL.Cipher.des_ede3_cbc_encrypt(key, iv, iv).unwrap!.take(3)
  puts(OpenSSL.Digest.hexencode(check_value))
  puts(OpenSSL.Cipher.des_ede3_cbc_encrypt(key, iv, "PIN".bytes).ok?)
end
```

```output
1a3be5be6098e0d3
PIN 1234
08d7b4
false
```

`OpenSSL.CMAC.aes` da el CMAC (NIST SP 800-38B, RFC 4493) de `data` con AES: la clave tiene 16, 24 o 32 bytes, para AES-128, AES-192 o AES-256, y la etiqueta tiene 16 bytes. `OpenSSL.CMAC.des_ede3` lo da con Triple DES, con una clave de 24 o 16 bytes, y la etiqueta tiene 8 bytes. Ambas dan la etiqueta completa; cuando un formato envía un MAC más corto, toma sus primeros bytes y compruébalo con [`OpenSSL.HMAC.secure_compare`](#checking-a-mac).

```agentica
def main() -> Void
  key = OpenSSL.Digest.hexdecode("2b7e151628aed2a6abf7158809cf4f3c").unwrap!
  message = "0200 payment message".bytes
  tag = OpenSSL.CMAC.aes(key, message).unwrap!
  puts(OpenSSL.Digest.hexencode(tag))
  mac = tag.take(8)
  puts(OpenSSL.HMAC.secure_compare(OpenSSL.CMAC.aes(key, message).unwrap!.take(8), mac))
  tdes_key = OpenSSL.Digest.hexdecode("0123456789abcdeffedcba9876543210").unwrap!
  puts(OpenSSL.CMAC.des_ede3(tdes_key, message).unwrap!.size)
  puts(OpenSSL.CMAC.aes(key.take(10), message).ok?)
end
```

```output
384be8227f8ea73df2a5fe3da6056b99
true
8
false
```

- Una clave, un IV o datos de otro tamaño dan un `error`, antes de cualquier trabajo: nunca hay salida parcial.
- El tiempo crece con los datos, y no necesitan etiqueta de efecto.

## RSA-OAEP {#rsa-oaep}

```signature
OpenSSL.RSA.public_encrypt_oaep(pem: String, data: Bytes) -> Result[Bytes]
```

`OpenSSL.RSA.public_encrypt_oaep` cifra `data` con la clave pública RSA de `pem` y relleno OAEP con SHA-1 y MGF1-SHA-1, como hace `OpenSSL::PKey::RSA.new(pem).public_encrypt(data, OpenSSL::PKey::RSA::PKCS1_OAEP_PADDING)` de Ruby. Solo el propietario de la clave privada puede descifrar el resultado. Los `caching_sha2_password` y `sha256_password` de MySQL lo usan para enviar una contraseña al servidor sin TLS. `pem` guarda la clave como `-----BEGIN PUBLIC KEY-----` (SubjectPublicKeyInfo, lo que escribe `openssl pkey -pubout`) o como `-----BEGIN RSA PUBLIC KEY-----` (PKCS#1); solo se lee su primer bloque PEM. El resultado tiene el tamaño de la clave, 256 bytes para una clave de 2048 bits, y cambia en cada llamada, ya que OAEP genera una semilla aleatoria cada vez.

```agentica
PEM = (
  "-----BEGIN PUBLIC KEY-----\n" +
  "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAs1ZCN9Wxre/bu7dwEeju\n" +
  "bBLygVJkUck+jMQuh8glJPrdzdDsmANl87e/f2/AC2+hmGVaXDCQhORyMBqRT0NW\n" +
  "NhdqwGviyW+lp3h6494ioX3HPTXyoauDWT4Ur2CKaetLO0iH/54vGQGyKGsKxCdD\n" +
  "kGV6hiftn3LKzq3rQ2k4lPEbam2V4SppaSG/d7iR/l4qVzKbPbIa3QqK75JI+PbI\n" +
  "rj5O9zKgeWS1VCVLMjp5GmUH3blNqbMo4bqm8uEBwD0R4/XgksAyV/xwDn/YUGm5\n" +
  "Ge3bi1fuS5ec3N0d6Nym9ueD1PV/s8luy+YYpBxw6d1o5fN/rA+crcKQf4xyquRS\n" +
  "kQIDAQAB\n" +
  "-----END PUBLIC KEY-----\n"
)

def main() -> Void
  sealed = OpenSSL.RSA.public_encrypt_oaep(PEM, "secret password".bytes).unwrap!
  puts(sealed.size)
  puts(sealed == OpenSSL.RSA.public_encrypt_oaep(PEM, "secret password".bytes).unwrap!)
  puts(OpenSSL.RSA.public_encrypt_oaep(PEM, OpenSSL.Random.random_bytes(215)).ok?)
  puts(OpenSSL.RSA.public_encrypt_oaep("not a key", "x".bytes).ok?)
end
```

```output
256
false
false
false
```

- `data` tiene como máximo el tamaño de la clave menos 42 bytes: 214 para una clave de 2048 bits, 470 para una de 4096 bits. Para enviar más, cífralo con [AES-256-GCM](#aes-256-gcm) con una clave aleatoria y cifra esa clave con RSA.
- Un `pem` sin clave pública PEM (se incluye una clave privada o un certificado), de más de 65536 bytes, una clave que no es RSA (EC o RSA-PSS), datos demasiado largos para la clave, o una clave que no puede cifrar (42 bytes o menos, más de 16384 bits, un módulo par, o un exponente par, igual a 1 o de más de 64 bits) da un `error`. Un fallo dentro de OpenSSL, como no tener bytes aleatorios para la semilla, detiene el programa con `RUNTIME-INTERNAL`.
- Solo cifra: no hay claves privadas, firmas, otros rellenos ni generación de claves.
- El trabajo es una sola operación de clave pública, acotada por esos límites, y necesita la etiqueta de efecto `random`, como `OpenSSL.Random`, así que una constante de módulo no puede llamarla.

## Números aleatorios {#random}

```signature
OpenSSL.Random.random_bytes(count: Int = 16) -> Bytes
OpenSSL.Random.hex(count: Int = 16) -> String
OpenSSL.Random.uuid() -> String
```

`OpenSSL.Random.random_bytes(count)` da un `Bytes` de `count` bytes del generador aleatorio seguro de OpenSSL (`RAND_bytes`), que el sistema siembra. `OpenSSL.Random.hex(count)` da `count` de esos bytes como `2 * count` dígitos hexadecimales en minúsculas. `OpenSSL.Random.uuid` da un UUID aleatorio versión 4 (RFC 9562): 36 caracteres en minúsculas, como `"2ddb7c9f-b237-4edc-b8ae-d3a42c7135f5"`. Sin argumento, `random_bytes` y `hex` generan 16 bytes, como en Ruby.

```agentica
def main() -> Void
  key = OpenSSL.Random.random_bytes(32)
  puts(key.size)
  puts(OpenSSL.Random.hex.size)
  id = OpenSSL.Random.uuid
  puts(id.size)
  puts(String.slice(id, 14, 1))
end
```

```output
32
32
36
4
```

Cada ejecución da otros valores.

- Usa `OpenSSL.Random` para claves, sales, tokens de sesión, enlaces para restablecer contraseñas e IDs que no deban poder adivinarse. [`Random`](/library/io-and-system/system/#randomint) está sembrado y `--seed` lo repite, así que no sirve para secretos.
- `count` debe ir de 0 a 1048576 (1 MiB); cualquier otro `count` detiene el programa con `RUNTIME-INVALID-COUNT` en el argumento. Una clave o un token necesita de 16 a 64 bytes.
- Si el sistema no puede dar bytes aleatorios, la llamada detiene el programa con `RUNTIME-INTERNAL`. Nunca da bytes débiles en su lugar.
- Las llamadas tienen la etiqueta de efecto `random`, así que una constante de módulo no puede llamarlas. El tiempo de `random_bytes` y `hex` crece con `count`.

```agentica {expect="RUNTIME-INVALID-COUNT"}
def main() -> Void
  puts(OpenSSL.Random.hex(-1))
end
```
