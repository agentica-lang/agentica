---
title: Text and data
weight: 2
description: Work with text and numbers, read and write JSON and TOML, encode URLs, escape HTML and handle cookies, find the media type of a file, pack numbers into bytes, hash and sign bytes, and draw secure random bytes.
---

- Use [String](/library/text-and-data/string/) to cut, search, change and convert text, and to turn text into numbers.
- Use [Int and Float](/library/text-and-data/numbers/) to convert between `Int`, `Float` and `String`.
- Use [JSON](/library/text-and-data/json/) to move data in and out of programs, for a known shape (structs) or not.
- Use [Binary data](/library/text-and-data/binary/) (`std/binary`) to read and write numbers in a `Bytes`, and to frame messages.
- Use [TOML](/library/text-and-data/toml/) (`std/toml`) to read and write TOML 1.0 documents, such as configuration files.
- Use [HTML](/library/text-and-data/html/) (`std/html`) to escape and unescape HTML text.
- Use [Cookie](/library/text-and-data/cookie/) (`std/cookie`) to read a `Cookie` header and to write a `Set-Cookie` header.
- Use [MIME](/library/text-and-data/mime/) (`std/mime`) to find the media type of a file from its name, and to tell which types are text.
- Use [URI](/library/text-and-data/uri/) (`std/uri`) to percent-encode and decode URL components and to read and write query strings.
- Use [Digest, HMAC and SecureRandom](/library/text-and-data/crypto/) to hash a list of bytes with MD5, SHA-1, SHA-256 or SHA-512, to sign it with HMAC-SHA256 or HMAC-SHA512, to compare MACs in constant time, to encrypt with AES-256-GCM, to hash passwords with PBKDF2 and scrypt, to encrypt and MAC payment data with Triple DES and CMAC, and to draw secure random bytes, hex and UUIDs.
- Use [Zlib](/library/text-and-data/zlib/) to compress bytes, files and streams with DEFLATE, zlib and gzip.
- Use [Base64 and hex](/library/text-and-data/base64/) to write bytes as text and read them back.

The tour pages [Strings](/tour/strings/) and [Numbers](/tour/numbers/) are a short start.
