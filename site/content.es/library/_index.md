---
title: Biblioteca
weight: 4
description: Cada módulo integrado, agrupado por tema, con su firma y un ejemplo de cada función.
source_hash: "f018e99d271d"
---

Los módulos integrados, agrupados por tema. Cada función tiene su firma, una descripción corta y un ejemplo pequeño. Las funciones de los módulos `String`, `List`, `Map`, `Set`, `Range`, `Int`, `Float`, `Result` y `JSON` cuyo primer parámetro tiene ese tipo también se pueden llamar como métodos: `String.upcase(s)` es lo mismo que `s.upcase`. Una familia agrupa módulos bajo un nombre, como lo hace `OpenSSL::Cipher` en Ruby: [`OpenSSL.Cipher.aes_256_gcm_encrypt`](/library/text-and-data/crypto/) es la función `aes_256_gcm_encrypt` del miembro `Cipher` de la familia `OpenSSL`, y solo `OpenSSL` es un nombre reservado.

También puedes buscar cualquier integrado desde la línea de comandos con `agentica help NAME`; `agentica help` solo lista los espacios de nombres y los tipos integrados, y `agentica help --json` imprime cada integrado y cada tipo integrado como un único array JSON.
