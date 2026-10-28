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
## A query string is a list of `[name, value]` pairs, as in Ruby: a name may repeat and the order is kept. Unlike Ruby,
## `decode_www_form` skips an empty piece (`a=1&&b=2` has two pairs, as in Python, Rack and browsers) and returns an
## `error` for a bad `%` instead of leaving it in the text.

HEX_DIGITS = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "A", "B", "C", "D", "E", "F"]

# The byte values the encoders and decoders look at.
PERCENT = 37
PLUS = 43
SPACE = 32

## Encodes `text` for a query string or a form: space becomes `+` and every byte but `A-Z a-z 0-9 * - . _` becomes
## `%XX`, as Ruby's `URI.encode_www_form_component`.
export def encode_www_form_component(text: String) -> String
  return encode(text, "+")
end

## Encodes `text` for a path segment or any URI component: space becomes `%20` and every byte but `A-Z a-z 0-9 * - . _`
## becomes `%XX`, as Ruby's `URI.encode_uri_component`.
export def encode_uri_component(text: String) -> String
  return encode(text, "%20")
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

## Joins `[name, value]` pairs into a query string, `a=1&a=2&b=`, encoding each part with
## `encode_www_form_component`. Names may repeat and the order is kept. Returns an error when a pair does not have
## exactly two items.
export def encode_www_form(pairs: List[List[String]]) -> Result[String]
  parts: List[String] = []
  for pair in pairs
    if pair.size != 2
      return error("pair #{parts.size} has #{pair.size} items, expected a name and a value")
    end
    parts = parts.push("#{encode_www_form_component(pair[0])}=#{encode_www_form_component(pair[1])}")
  end
  return ok(parts.join("&"))
end

## Splits a query string on `&` into `[name, value]` pairs and decodes both with `decode_www_form_component`, as Ruby's
## `URI.decode_www_form`. Names may repeat and the order is kept; a piece without `=` has the value `""`, and an empty
## piece is skipped. Returns the error of the first piece that does not decode.
export def decode_www_form(query: String) -> Result[List[List[String]]]
  pairs: List[List[String]] = []
  for piece in query.split("&")
    if piece.empty?
      next
    end
    pairs = pairs.push(try decode_pair(piece))
  end
  return ok(pairs)
end

def encode(text: String, space: String) -> String
  parts: List[String] = []
  for byte in text.to_bytes
    if byte == SPACE
      parts = parts.push(space)
    elsif plain?(byte)
      parts = parts.push(String.from_code(byte))
    else
      parts = parts.push("%#{HEX_DIGITS[byte.shift_right(4)]}#{HEX_DIGITS[byte.bit_and(15)]}")
    end
  end
  return parts.join("")
end

# A byte that Ruby's encoders keep: A-Z a-z 0-9 and * - . _
def plain?(byte: Int) -> Bool
  if byte >= 97
    return byte <= 122
  end
  if byte >= 65
    return byte <= 90 or byte == 95
  end
  return (byte >= 48 and byte <= 57) or (byte >= 42 and byte <= 46 and byte != 43 and byte != 44)
end

# Decodes the bytes of `text`. Text without a `%` (or a `+` to turn into a space) is returned as it is.
def decode(text: String, plus_is_space: Bool) -> Result[String]
  if !text.include?("%") and !(plus_is_space and text.include?("+"))
    return ok(text)
  end
  bytes = text.to_bytes
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
  case String.from_bytes(out)
    ok(decoded) -> return ok(decoded)
    error(_) -> return error("invalid UTF-8 after decoding (#{text})")
  end
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
def decode_pair(piece: String) -> Result[List[String]]
  split = piece.index_of("=")
  if !split.ok?
    return ok([try decode_www_form_component(piece), ""])
  end
  at = split.unwrap!
  name = try decode_www_form_component(piece.slice(0, at))
  value = try decode_www_form_component(piece.slice(at + 1, piece.length - at - 1))
  return ok([name, value])
end
