---
title: Base64 and hex
weight: 8
description: The Base64 and Digest builtins, which write bytes as base64 or hex text and read them back.
---

`Base64` writes bytes as RFC 4648 base64 text and reads it back, in the forms of Ruby's `Base64` module and with the same results. `Digest.hexencode` and `Digest.hexdecode` do the same with hex digits. The VM computes them in plain C; nothing is written in Agentica.

Bytes are a `List[Int]` from 0 to 255, as `Crypto.sha256`, `IO.read_bytes` and `File.read_bytes` use. For text, encode its UTF-8 bytes from `String.to_bytes` and decode the bytes back with `String.from_bytes`.

## Base64

```text
Base64.strict_encode64(data: List[Int]) -> String
Base64.encode64(data: List[Int]) -> String
Base64.urlsafe_encode64(data: List[Int], padding: Bool = true) -> String
Base64.strict_decode64(text: String) -> Result[List[Int]]
Base64.urlsafe_decode64(text: String) -> Result[List[Int]]
Base64.decode64(text: String) -> List[Int]
```

- `Base64.strict_encode64` gives padded base64 on one line. `Base64.encode64` gives the same text in lines of 60 characters, each ending in a newline, as Ruby writes them; no bytes give `""`.
- `Base64.urlsafe_encode64` uses the URL and file name alphabet, with `-` and `_` in place of `+` and `/`. With `padding` false it leaves out the `=` at the end, as JSON Web Tokens do.
- `Base64.strict_decode64` takes only padded base64 with nothing else in the text, not even a newline, and with zero spare bits in the last group; anything else is `error("invalid base64")`.
- `Base64.urlsafe_decode64` adds the missing `=` to text that does not end in one, then decodes it as `strict_decode64` does. It takes both alphabets.
- `Base64.decode64` never fails: it skips every character outside the alphabet (newlines, spaces), stops at a `=` in the third or fourth place of a group, and drops a lone last character. Use it for `encode64` text; use the strict forms to reject bad input.

```agentica
def main() -> Void
  data = String.to_bytes("hello, world")
  puts(Base64.strict_encode64(data))
  puts(Base64.urlsafe_encode64([251, 255], false))
  back = Base64.strict_decode64("aGVsbG8sIHdvcmxk").unwrap!
  puts(String.from_bytes(back).unwrap!)
  puts(Base64.strict_decode64("aGVsbG8\n"))
  puts(Base64.decode64("aGVs\nbG8=\n"))
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
Digest.hexencode(data: List[Int]) -> String
Digest.hexdecode(text: String) -> Result[List[Int]]
```

`Digest.hexencode` gives two lowercase hex digits per byte. `Digest.hexdecode` takes an even number of hex digits in either case; an odd length or any other character, a space or `0x` included, is an error.

```agentica
def main() -> Void
  puts(Digest.hexencode(Crypto.sha256([])).slice(0, 16))
  puts(Digest.hexdecode("00FFa0"))
  puts(Digest.hexdecode("abc").ok?)
end
```

```output
e3b0c44298fc1c14
ok([0, 255, 160])
false
```

- An item outside 0 to 255 in an encoded list stops the program with `RUNTIME-INVALID-NUMBER` at the argument.
- The time grows with the input. None needs an effect label: they read nothing outside their argument.
- `Base64` and `Digest` are reserved type names.

```agentica {expect="RUNTIME-INVALID-NUMBER"}
def main() -> Void
  puts(Base64.strict_encode64([1, 256]))
end
```
