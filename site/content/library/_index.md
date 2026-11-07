---
title: Library
weight: 4
description: Every builtin module, grouped by topic, with a signature and an example for each function.
---

The builtin modules, grouped by topic. Every function has its signature, a short description and a small example. Functions in the `String`, `List`, `Map`, `Set`, `Range`, `Int`, `Float`, `Result` and `JSON` modules whose first parameter has that type can also be called as methods: `String.upcase(s)` is the same as `s.upcase`. A family groups modules under one name, as Ruby's `OpenSSL::Cipher` does: [`OpenSSL.Cipher.aes_256_gcm_encrypt`](/library/text-and-data/crypto/) is the function `aes_256_gcm_encrypt` of the member `Cipher` of the `OpenSSL` family, and only `OpenSSL` is a reserved name.

You can also look up any builtin from the command line with `agentica help NAME`; `agentica help` alone lists the namespaces, and `agentica help --json` prints every builtin as one JSON array.
