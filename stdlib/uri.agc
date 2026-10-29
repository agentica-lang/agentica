## Percent-encodes and decodes URL components and query strings, with the names and rules of Ruby's `URI`.
##
## Import it with `import URI from "std/uri"`. The text is UTF-8: the encoders write the bytes of each character as
## `%XX` (uppercase hex), and the decoders read `%XX` back (either case) and check that the bytes are valid UTF-8. Both
## encoders leave `A-Z a-z 0-9 * - . _` alone and encode every other byte, `~` included, as Ruby does; they differ only
## in the space, `+` for the form style and `%20` for the URI style. The decoders turn the `+` of the form style into a
## space and never touch the `+` of the URI style, so use `decode_uri_component` for a path segment.
##
## A decoder returns an `error` for a `%` that is not followed by two hex digits (Ruby raises `invalid %-encoding`) and
## for bytes that are not UTF-8 after decoding (Ruby returns a string with invalid bytes, which a `String` cannot
## hold). Nothing here halts. Text that is not ASCII passes through a decoder unchanged.
##
## A query string is a list of `Pair`s, Ruby's `[name, value]` arrays: a name may repeat and the order is kept. Unlike
## Ruby, `decode_www_form` skips an empty piece (`a=1&&b=2` has two pairs, as in Python, Rack and browsers) and
## returns an `error` for a bad `%` instead of leaving it in the text.

# The bytes of "0123456789ABCDEF", indexed by a nibble.
HEX_DIGITS = [48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 65, 66, 67, 68, 69, 70]

# The bytes that Ruby's encoders keep: A-Z a-z 0-9 * - . _
PLAIN = Set.new(List.concat(List.concat((48..57).to_a, (65..90).to_a), List.concat((97..122).to_a, [42, 45, 46, 95])))

# The byte values the encoders and decoders look at, and the three bytes of "%20".
PERCENT = 37
PLUS = 43
SPACE = 32
ENCODED_SPACE = [PERCENT, 50, 48]

## One `name=value` piece of a query string.
export struct Pair
  name: String
  value: String
end

## Encodes `text` for a query string or a form: space becomes `+` and every byte but `A-Z a-z 0-9 * - . _` becomes
## `%XX`, as Ruby's `URI.encode_www_form_component`.
export def encode_www_form_component(text: String) -> String
  return encode(text, [PLUS])
end

## Encodes `text` for a path segment or any URI component: space becomes `%20` and every byte but `A-Z a-z 0-9 * - . _`
## becomes `%XX`, as Ruby's `URI.encode_uri_component`.
export def encode_uri_component(text: String) -> String
  return encode(text, ENCODED_SPACE)
end

## Decodes a query string or form component: `+` becomes a space and `%XX` becomes its byte, as Ruby's
## `URI.decode_www_form_component`. Returns an error for a `%` without two hex digits and for bytes that are not UTF-8.
export def decode_www_form_component(text: String) -> Result[String]
  return decode(text, true)
end

## Decodes a path segment or any URI component: `%XX` becomes its byte and `+` stays a plus, as Ruby's
## `URI.decode_uri_component`. Returns an error for a `%` without two hex digits and for bytes that are not UTF-8.
export def decode_uri_component(text: String) -> Result[String]
  return decode(text, false)
end

## Joins pairs into a query string, `a=1&a=2&b=`, encoding each name and value with `encode_www_form_component`. Names
## may repeat and the order is kept.
export def encode_www_form(pairs: List[Pair]) -> String
  parts = pairs.map do |pair|
    "#{encode_www_form_component(pair.name)}=#{encode_www_form_component(pair.value)}"
  end
  return parts.join("&")
end

## Splits a query string on `&` into pairs and decodes both parts with `decode_www_form_component`, as Ruby's
## `URI.decode_www_form`. Names may repeat and the order is kept; a piece without `=` has the value `""`, and an empty
## piece is skipped. Returns the error of the first piece that does not decode.
export def decode_www_form(query: String) -> Result[List[Pair]]
  pairs: List[Pair] = []
  for piece in query.split("&")
    if piece.empty?
      next
    end
    pairs = pairs.push(try decode_pair(piece))
  end
  return ok(pairs)
end

def encode(text: String, space: List[Int]) -> String
  out: List[Int] = []
  for byte in text.bytes
    if byte == SPACE
      for s in space
        out = out.push(s)
      end
    elsif PLAIN.include?(byte)
      out = out.push(byte)
    else
      out = out.push(PERCENT).push(HEX_DIGITS[byte.shift_right(4)]).push(HEX_DIGITS[byte.bit_and(15)])
    end
  end
  # Every output byte is ASCII (a plain byte, `%`, a hex digit, `+`), so neither step can halt.
  return String.from_bytes(Bytes.from_list(out).unwrap!).unwrap!
end

# Decodes the bytes of `text`. Text without a `%` (or a `+` to turn into a space) is returned as it is.
def decode(text: String, plus_is_space: Bool) -> Result[String]
  if !needs_decoding?(text, plus_is_space)
    return ok(text)
  end
  bytes = text.bytes
  out: List[Int] = []
  i = 0
  while i < bytes.size
    byte = bytes[i]
    if byte == PERCENT
      if i + 2 >= bytes.size
        return error("invalid %-encoding (#{text})")
      end
      high = hex_value(bytes[i + 1])
      low = hex_value(bytes[i + 2])
      if high < 0 or low < 0
        return error("invalid %-encoding (#{text})")
      end
      out = out.push(high * 16 + low)
      i = i + 3
    elsif byte == PLUS and plus_is_space
      out = out.push(SPACE)
      i = i + 1
    else
      out = out.push(byte)
      i = i + 1
    end
  end
  # Every item of `out` is a byte (one of `text`, or two hex digits), so Bytes.from_list cannot fail.
  case String.from_bytes(try Bytes.from_list(out))
    ok(decoded) -> return ok(decoded)
    error(_) -> return error("invalid UTF-8 after decoding (#{text})")
  end
end

# Whether `text` has a `%` escape or, for the form style, a `+`.
def needs_decoding?(text: String, plus_is_space: Bool) -> Bool
  if text.include?("%")
    return true
  end
  return plus_is_space and text.include?("+")
end

# The value of a hex digit byte of either case, or -1.
def hex_value(byte: Int) -> Int
  if byte >= 48 and byte <= 57
    return byte - 48
  end
  if byte >= 65 and byte <= 70
    return byte - 55
  end
  if byte >= 97 and byte <= 102
    return byte - 87
  end
  return -1
end

# One `name=value` piece. The first `=` splits it; a piece without one is a name with the value "".
def decode_pair(piece: String) -> Result[Pair]
  split = piece.index_of("=")
  if !split.ok?
    return ok(Pair(name: try decode_www_form_component(piece), value: ""))
  end
  at = split.unwrap!
  name = try decode_www_form_component(piece.slice(0, at))
  value = try decode_www_form_component(piece.slice(at + 1, piece.length - at - 1))
  return ok(Pair(name: name, value: value))
end
