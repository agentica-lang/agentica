---
title: Text and data
weight: 2
description: Work with text and numbers, read and write JSON and TOML, encode URLs, escape HTML and handle cookies, pack numbers into bytes, hash and sign bytes, and draw secure random bytes.
---

- Use [String](/library/text-and-data/string/) to cut, search, change and convert text, and to turn text into numbers.
- Use [Int and Float](/library/text-and-data/numbers/) to convert between `Int`, `Float` and `String`.
- Use [JSON](/library/text-and-data/json/) to move data in and out of programs, for a known shape (structs) or not.
- Use [Binary data](/library/text-and-data/binary/) (`std/binary`) to read and write numbers in a list of bytes, and to frame messages.
- Use [TOML](/library/text-and-data/toml/) (`std/toml`) to read and write TOML 1.0 documents, such as configuration files.
- Use [CGI](/library/text-and-data/cgi/) (`std/cgi`) to escape and unescape HTML, to read a `Cookie` header and to write a `Set-Cookie` header.
- Use [URI](/library/text-and-data/uri/) (`std/uri`) to percent-encode and decode URL components and to read and write query strings.
- Use [Digest, HMAC and SecureRandom](/library/text-and-data/crypto/) to hash a list of bytes with MD5, SHA-1, SHA-256 or SHA-512, to sign it with HMAC-SHA256 or HMAC-SHA512, to compare MACs in constant time, and to draw secure random bytes, hex and UUIDs.
- Use [Zlib](/library/text-and-data/zlib/) to compress bytes, files and streams with DEFLATE, zlib and gzip.
- Use [Base64 and hex](/library/text-and-data/base64/) to write bytes as text and read them back.

The tour pages [Strings](/tour/strings/) and [Numbers](/tour/numbers/) are a short start.
