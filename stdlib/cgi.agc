## Escapes and unescapes HTML text, and reads and writes HTTP cookies, with the names of Ruby's `CGI` and Rack.
##
## Import it with `import CGI from "std/cgi"`. `escape_html` and `unescape_html` are Ruby's `CGI.escape_html` and
## `CGI.unescape_html`. `Cookie`, `parse_cookies_header` and `set_cookie_header` are the cookie half: `Cookie` has the
## fields of Rack's cookie options (`max_age`, `http_only`, `same_site`) and the two functions are Rack's
## `Rack::Utils.parse_cookies_header` and `Rack::Utils.set_cookie_header`. Written in Agentica; nothing here halts.
##
## Unlike Ruby and Rack, the cookie functions never percent-encode, decode or quote, and this is final.
## `set_cookie_header` writes the value as it is and returns an `error` for a byte that RFC 6265 does not allow in it,
## and `parse_cookies_header` returns the value as the client sent it. A caller that needs encoding (for a space, a
## comma or a non-ASCII character) does it before `set_cookie_header` and decodes after `parse_cookies_header`.
##
## `unescape_html("&#0;")` gives a NUL character, as Ruby does.

# The code points and bytes that the functions look at.
SPACE = 32
QUOTE = 34
HASH = 35
UPPER_X = 88
SEMICOLON = 59
COMMA = 44
BACKSLASH = 92
LOWER_X = 120
DEL = 127
FIRST_SURROGATE = 55296
LAST_SURROGATE = 57343
LAST_CODE_POINT = 1114111

## The `max_age` of a cookie that has no `Max-Age`, the default. It is the smallest `Int`, so no computed value is
## taken for it: every other negative `max_age` writes `Max-Age=0`, which deletes the cookie.
export NO_MAX_AGE = -9223372036854775808

# The entities that Ruby's `unescape_html` decodes by name, as written between `&` and `;`.
NAMED_ENTITIES = {"amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'"}

# The bytes that RFC 6265 allows in a cookie name (an RFC 7230 token): letters, digits and !#$%&'*+-.^_`|~
TOKEN_SYMBOLS = Set.new("!#$%&'*+-.^_`|~".to_bytes)

# The same-site values that `set_cookie_header` writes.
SAME_SITE_VALUES = Set.new(["Strict", "Lax", "None"])

## A cookie to send. An empty `path`, `domain`, `expires` or `same_site`, a `max_age` of `NO_MAX_AGE` and a false
## `secure` or `http_only` leave that attribute out. A `max_age` of 0 or less writes `Max-Age=0`, which deletes the
## cookie.
export struct Cookie
  name: String
  value: String
  path: String = ""
  domain: String = ""
  # The literal is NO_MAX_AGE: a default must be a literal.
  max_age: Int = -9223372036854775808
  ## Written as it is, for example `Wed, 21 Oct 2015 07:28:00 GMT`.
  expires: String = ""
  secure: Bool = false
  http_only: Bool = false
  ## One of `Strict`, `Lax` or `None`.
  same_site: String = ""
end

## Replaces `&`, `<`, `>`, `"` and `'` with `&amp;`, `&lt;`, `&gt;`, `&quot;` and `&#39;`, as Ruby's
## `CGI.escape_html`.
export def escape_html(text: String) -> String
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
export def unescape_html(text: String) -> String
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

## Reads the value of a `Cookie` request header into a map from name to value, as Rack's `parse_cookies_header`.
## Pieces are separated by `;`, and spaces around a piece, a name and a value are dropped. A piece without `=` or with
## an empty name is skipped, and the first value of a repeated name wins. Values are not decoded or unquoted.
export def parse_cookies_header(header: String) -> Map[String, String]
  cookies: Map[String, String] = {}
  for piece in header.split(";")
    pair = piece.strip
    eq_at = pair.index_of("=")
    if !eq_at.ok?
      next
    end
    at = eq_at.unwrap!
    name = pair.slice(0, at).strip
    if name.empty? or cookies.key?(name)
      next
    end
    cookies = cookies.put(name, pair.slice(at + 1, pair.length - at - 1).strip)
  end
  return cookies
end

## Writes the value of a `Set-Cookie` header: `name=value`, then the attributes in Rack's order (`Domain`, `Path`,
## `Max-Age`, `Expires`, `Secure`, `HttpOnly`, `SameSite`). Returns an `error` naming the field when:
##
## - the name is not an RFC 7230 token;
## - the value has a byte that RFC 6265 does not allow (a space, `"`, `,`, `;`, `\`, a control or a non-ASCII byte);
##   the error gives the position of the byte and never the value;
## - `path`, `domain` or `expires` has a control, a non-ASCII byte or `;`, `domain` has a space, or `path` or `expires`
##   starts or ends with one;
## - `same_site` is not `Strict`, `Lax` or `None`, or is `None` without `secure`;
## - the name starts with `__Secure-` and `secure` is false, or with `__Host-` and `secure` is false, `path` is not `/`
##   or `domain` is set (browsers compare the prefix without regard to case, so this does too).
##
## The text of an error about a name or an attribute has its control bytes removed.
export def set_cookie_header(cookie: Cookie) -> Result[String]
  try check_cookie(cookie)
  parts = ["#{cookie.name}=#{cookie.value}"]
  parts = try add_attribute(parts, "Domain", "domain", cookie.domain)
  parts = try add_attribute(parts, "Path", "path", cookie.path)
  if cookie.max_age != NO_MAX_AGE
    parts = parts.push("Max-Age=#{max_of(cookie.max_age, 0)}")
  end
  parts = try add_attribute(parts, "Expires", "expires", cookie.expires)
  if cookie.secure
    parts = parts.push("Secure")
  end
  if cookie.http_only
    parts = parts.push("HttpOnly")
  end
  if cookie.same_site != ""
    parts = parts.push("SameSite=#{cookie.same_site}")
  end
  return ok(parts.join("; "))
end

# The text after one `&` up to the next one: the decoded entity followed by the rest, or the `&` and the piece again.
def unescape_piece(piece: String) -> String
  end_at = piece.index_of(";")
  if !end_at.ok?
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
  bytes = name.to_bytes
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

# The checks of `set_cookie_header` that are not about one attribute alone. Returns the first error.
def check_cookie(cookie: Cookie) -> Result[Bool]
  if !valid_name?(cookie.name)
    return error("invalid cookie name (#{printable(cookie.name)})")
  end
  bad_at = bad_value_position(cookie.value)
  if bad_at >= 0
    return error("invalid cookie value (byte #{bad_at})")
  end
  if cookie.domain.include?(" ")
    return error("invalid cookie domain (#{printable(cookie.domain)})")
  end
  if cookie.same_site != "" and !SAME_SITE_VALUES.include?(cookie.same_site)
    return error("invalid cookie same_site (#{printable(cookie.same_site)})")
  end
  if cookie.same_site == "None" and !cookie.secure
    return error("invalid cookie same_site (None needs secure)")
  end
  lower = cookie.name.downcase
  if lower.start_with?("__host-") and !(cookie.secure and cookie.path == "/" and cookie.domain == "")
    return error("invalid cookie name (__Host- needs secure, path / and no domain)")
  end
  if lower.start_with?("__secure-") and !cookie.secure
    return error("invalid cookie name (__Secure- needs secure)")
  end
  return ok(true)
end

def valid_name?(name: String) -> Bool
  bytes = name.to_bytes
  return !bytes.empty? and bytes.all? do |byte| token_byte?(byte) end
end

def token_byte?(byte: Int) -> Bool
  if TOKEN_SYMBOLS.include?(byte)
    return true
  end
  return (byte >= 48 and byte <= 57) or (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122)
end

# The position of the first byte of `value` that is not an RFC 6265 cookie-octet (printable ASCII except space, `"`,
# `,`, `;` and `\`), or -1.
def bad_value_position(value: String) -> Int
  bytes = value.to_bytes
  i = 0
  while i < bytes.size
    byte = bytes[i]
    if byte <= SPACE or byte >= DEL or byte == QUOTE or byte == COMMA or byte == SEMICOLON or byte == BACKSLASH
      return i
    end
    i = i + 1
  end
  return -1
end

# Adds `Label=text` to `parts`, or nothing when `text` is empty. An attribute value is printable ASCII without `;`,
# and does not start or end with a space.
def add_attribute(parts: List[String], label: String, field: String, text: String) -> Result[List[String]]
  if text == ""
    return ok(parts)
  end
  if text != text.strip or !text.to_bytes.all? do |byte| byte >= SPACE and byte < DEL and byte != SEMICOLON end
    return error("invalid cookie #{field} (#{printable(text)})")
  end
  return ok(parts.push("#{label}=#{text}"))
end

# `text` without control bytes, for an error message. Removing ASCII bytes keeps valid UTF-8 valid.
def printable(text: String) -> String
  kept = text.to_bytes.select do |byte| byte >= SPACE and byte != DEL end
  return String.from_bytes(kept).unwrap_or("")
end

def max_of(a: Int, b: Int) -> Int
  if a > b
    return a
  end
  return b
end
