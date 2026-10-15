---
title: Text and data
weight: 2
description: Work with text and numbers, read and write JSON and TOML, and pack numbers into bytes.
---

- Use [String](/library/text-and-data/string/) to cut, search, change and convert text, and to turn text into numbers.
- Use [Int and Float](/library/text-and-data/numbers/) to convert between `Int`, `Float` and `String`.
- Use [JSON](/library/text-and-data/json/) to move data in and out of programs. `JSON.encode` and `JSON.decode` map values to structs and back. `JSON.parse` and the readers `JSON.get`, `JSON.at`, `JSON.string` and the others read JSON whose shape is not known in advance.
- Use [Binary data](/library/text-and-data/binary/) (`std/binary`) to read and write integers and floats in a list of bytes, in either byte order, and to frame messages with a 4-byte length.
- Use [TOML](/library/text-and-data/toml/) (`std/toml`) to read and write TOML 1.0 documents, such as configuration files, and to decode them into structs through `JSON.decode`.

The tour pages [Strings](/tour/strings/) and [Numbers](/tour/numbers/) are a short start.
