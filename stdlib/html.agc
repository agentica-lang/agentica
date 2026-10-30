## Escapes and unescapes HTML text, with the behaviour of Ruby's `CGI.escape_html` and `CGI.unescape_html`.
##
## Import it with `import HTML from "std/html"`. Written in Agentica; nothing here halts.
##
## `unescape("&#0;")` gives a NUL character, as Ruby does.

# The code points and bytes that the functions look at.
HASH = 35
UPPER_X = 88
LOWER_X = 120
FIRST_SURROGATE = 55296
LAST_SURROGATE = 57343
LAST_CODE_POINT = 1114111

# The entities that Ruby's `unescape_html` decodes by name, as written between `&` and `;`.
NAMED_ENTITIES = {"amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'"}

## Replaces `&`, `<`, `>`, `"` and `'` with `&amp;`, `&lt;`, `&gt;`, `&quot;` and `&#39;`, as Ruby's
## `CGI.escape_html`.
export def escape(text: String) -> String
  return (
    text.replace("&", "&amp;")
      .replace("<", "&lt;")
      .replace(">", "&gt;")
      .replace("\"", "&quot;")
      .replace("'", "&#39;")
  )
end

## Replaces `&amp;`, `&lt;`, `&gt;`, `&quot;`, `&apos;`, `&#NN;` and `&#xHH;` with their characters, as Ruby's
## `CGI.unescape_html`. Any other text that looks like an entity stays as it is: a name that is not in that list
## (`&nbsp;`), a number that is not a Unicode scalar value (above `10FFFF` or a surrogate), and an entity without its
## `;`. The text is read once, so `&amp;lt;` becomes `&lt;`.
export def unescape(text: String) -> String
  if !text.include?("&")
    return text
  end
  pieces = text.split("&")
  out = [pieces[0]]
  for piece in List.drop(pieces, 1)
    out = out.push(unescape_piece(piece))
  end
  return out.join("")
end

# The text after one `&` up to the next one: the decoded entity followed by the rest, or the `&` and the piece again.
def unescape_piece(piece: String) -> String
  end_at = piece.index_of(";")
  if end_at.none?
    return "&#{piece}"
  end
  at = end_at.unwrap!
  name = piece.slice(0, at)
  rest = piece.slice(at + 1, piece.length - at - 1)
  if NAMED_ENTITIES.key?(name)
    return "#{NAMED_ENTITIES.get(name, "")}#{rest}"
  end
  code = numeric_code(name)
  if code < 0
    return "&#{piece}"
  end
  return "#{String.from_code(code)}#{rest}"
end

# The code point that an entity name like `#65` or `#x41` stands for, or -1 when it is not a number or not a Unicode
# scalar value.
def numeric_code(name: String) -> Int
  bytes = name.bytes.to_a
  if bytes.size < 2 or bytes[0] != HASH
    return -1
  end
  if bytes[1] == LOWER_X or bytes[1] == UPPER_X
    return digits_value(List.drop(bytes, 2), 16)
  end
  return digits_value(List.drop(bytes, 1), 10)
end

# The value of digit bytes in `base`, or -1 for no digits, a bad digit, or a value that is not a Unicode scalar value.
# Stops adding at the first value above the last code point, so a long run of digits cannot overflow.
def digits_value(digits: List[Int], base: Int) -> Int
  if digits.empty?
    return -1
  end
  value = 0
  for byte in digits
    digit = digit_value(byte)
    if digit < 0 or digit >= base
      return -1
    end
    value = value * base + digit
    if value > LAST_CODE_POINT
      return -1
    end
  end
  if value >= FIRST_SURROGATE and value <= LAST_SURROGATE
    return -1
  end
  return value
end

# The value of a hex digit byte of either case, or -1.
def digit_value(byte: Int) -> Int
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
