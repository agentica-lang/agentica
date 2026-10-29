---
title: Base64 and hex
weight: 8
description: The Base64 and Digest builtins, which write bytes as base64 or hex text and read them back.
---

`Base64` writes bytes as RFC 4648 base64 text and reads it back, in the forms of Ruby's `Base64` module and with the same results. `Digest.hexencode` writes hex digits as Ruby's does, and `Digest.hexdecode`, Agentica's own name for its inverse, reads them back. The VM computes them in plain C; nothing is written in Agentica.

They take and give [`Bytes`](/library/data-structures/bytes/), as `Digest.sha256` does. For text, encode its UTF-8 bytes from `s.bytes` and decode the bytes back with `String.from_bytes(b.to_a)`.

## Base64

```text
Base64.strict_encode64(data: Bytes) -> String
Base64.encode64(data: Bytes) -> String
Base64.urlsafe_encode64(data: Bytes, padding: Bool = true) -> String
Base64.strict_decode64(text: String) -> Result[Bytes]
Base64.urlsafe_decode64(text: String) -> Result[Bytes]
Base64.decode64(text: String) -> Bytes
```

- `Base64.strict_encode64` gives padded base64 on one line. `Base64.encode64` gives the same text in lines of 60 characters, each ending in a newline, as Ruby writes them; no bytes give `""`.
- `Base64.urlsafe_encode64` uses the URL and file name alphabet, with `-` and `_` in place of `+` and `/`. With `padding` false it leaves out the `=` at the end, as JSON Web Tokens do.
- `Base64.strict_decode64` takes only padded base64 with nothing else in the text, not even a newline, and with zero spare bits in the last group; anything else is `error("invalid base64")`.
- `Base64.urlsafe_decode64` adds the missing `=` to text that does not end in one, then decodes it as `strict_decode64` does. It takes both alphabets.
- `Base64.decode64` never fails: it skips every character outside the alphabet (newlines, spaces), stops at a `=` in the third or fourth place of a group, and drops a lone last character. Use it for `encode64` text; use the strict forms to reject bad input.

```agentica
def main() -> Void
  data = "hello, world".bytes
  puts(Base64.strict_encode64(data))
  puts(Base64.urlsafe_encode64(Bytes.from_list([251, 255]).unwrap!, false))
  back = Base64.strict_decode64("aGVsbG8sIHdvcmxk").unwrap!
  puts(String.from_bytes(back.to_a).unwrap!)
  puts(Base64.strict_decode64("aGVsbG8\n"))
  puts(Base64.decode64("aGVs\nbG8=\n").to_a)
end
```

```output
aGVsbG8sIHdvcmxk
-_8
hello, world
error("invalid base64")
[104, 101, 108, 108, 111]
```

## Hex

```text
Digest.hexencode(data: Bytes) -> String
Digest.hexdecode(text: String) -> Result[Bytes]
```

`Digest.hexencode` gives two lowercase hex digits per byte. `Digest.hexdecode` takes an even number of hex digits in either case; an odd length or any other character, a space or `0x` included, is `error("invalid hex")`.

```agentica
def main() -> Void
  puts(Digest.hexencode(Digest.sha256("".bytes)).slice(0, 16))
  puts(Digest.hexdecode("00FFa0").unwrap!.to_a)
  puts(Digest.hexdecode("abc").ok?)
end
```

```output
e3b0c44298fc1c14
[0, 255, 160]
false
```

- The time grows with the input. None needs an effect label: they read nothing outside their argument.
- `Base64` and `Digest` are reserved type names.
