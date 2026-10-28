## Escapes and unescapes HTML text, and reads and writes HTTP cookies, with the names of Ruby's `CGI` and Rack.
##
## Import it with `import CGI from "std/cgi"`. `escape_html` and `unescape_html` are Ruby's `CGI.escape_html` and
## `CGI.unescape_html`. `Cookie`, `parse_cookies_header` and `set_cookie_header` are the cookie half: `Cookie` has the
## fields of Rack's cookie options (`max_age`, `http_only`, `same_site`) and the two functions are Rack's
## `Rack::Utils.parse_cookies_header` and `Rack::Utils.set_cookie_header`. Written in Agentica; nothing here halts.
##
## Unlike Ruby and Rack, the cookie functions never percent-encode or decode: `set_cookie_header` writes the value as
## it is and returns an `error` for a byte that RFC 6265 does not allow in it, and `parse_cookies_header` returns the
## value as the client sent it. Encode a value that needs it (a space, a comma, a non-ASCII character) before you set
## it and decode it after you read it. A value is never quoted.

# The code points of the characters the functions look at.
SEMICOLON = 59
LAST_CODE_POINT = 1114111

# The entities that Ruby's `unescape_html` decodes by name, as written between `&` and `;`.
NAMED_ENTITIES = {"amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'"}

# The bytes that RFC 6265 allows in a cookie name (an RFC 7230 token): letters, digits and !#$%&'*+-.^_`|~
TOKEN_SYMBOLS = Set.new("!#$%&'*+-.^_`|~".to_bytes)

# The same-site values that `set_cookie_header` writes.
SAME_SITE_VALUES = Set.new(["Strict", "Lax", "None"])

## A cookie to send. An empty `path`, `domain`, `expires` or `same_site`, a negative `max_age` and a false `secure` or
## `http_only` leave that attribute out; `max_age: 0` writes `Max-Age=0`, which deletes the cookie.
export struct Cookie
  name: String
  value: String
  path: String = ""
  domain: String = ""
  max_age: Int = -1
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
    split = pair.index_of("=")
    if !split.ok?
      next
    end
    at = split.unwrap!
    name = pair.slice(0, at).strip
    if name.empty? or cookies.key?(name)
      next
    end
    cookies = cookies.put(name, pair.slice(at + 1, pair.length - at - 1).strip)
  end
  return cookies
end

## Writes the value of a `Set-Cookie` header: `name=value`, then the attributes in Rack's order (`Domain`, `Path`,
## `Max-Age`, `Expires`, `Secure`, `HttpOnly`, `SameSite`). Returns an `error` naming the field when the name is not an
## RFC 7230 token, the value has a byte that RFC 6265 does not allow (a space, `"`, `,`, `;`, `\`, a control or a
## non-ASCII byte), `path`, `domain` or `expires` has a control, non-ASCII byte or `;`, or `same_site` is not one of
## `Strict`, `Lax` and `None`.
export def set_cookie_header(cookie: Cookie) -> Result[String]
  if !valid_name?(cookie.name)
    return error("invalid cookie name (#{cookie.name})")
  end
  if !valid_value?(cookie.value)
    return error("invalid cookie value (#{cookie.value})")
  end
  parts = ["#{cookie.name}=#{cookie.value}"]
  parts = try add_attribute(parts, "Domain", "domain", cookie.domain)
  parts = try add_attribute(parts, "Path", "path", cookie.path)
  if cookie.max_age >= 0
    parts = parts.push("Max-Age=#{cookie.max_age}")
  end
  parts = try add_attribute(parts, "Expires", "expires", cookie.expires)
  if cookie.secure
    parts = parts.push("Secure")
  end
  if cookie.http_only
    parts = parts.push("HttpOnly")
  end
  if cookie.same_site != ""
    if !SAME_SITE_VALUES.include?(cookie.same_site)
      return error("invalid cookie same_site (#{cookie.same_site})")
    end
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
  name = piece.slice(0, end_at.unwrap!)
  rest = piece.slice(end_at.unwrap! + 1, piece.length - end_at.unwrap! - 1)
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
  if bytes.size < 2 or bytes[0] != 35
    return -1
  end
  if bytes[1] == 120 or bytes[1] == 88
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
  if value >= 55296 and value <= 57343
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

# RFC 6265 cookie-octet: printable ASCII except space, `"`, `,`, `;` and `\`.
def valid_value?(value: String) -> Bool
  return value.to_bytes.all? do |byte|
    byte > 32 and byte < 127 and byte != 34 and byte != 44 and byte != 59 and byte != 92
  end
end

# Adds `Label=text` to `parts`, or nothing when `text` is empty. An attribute value is printable ASCII (a space is
# allowed) without `;`.
def add_attribute(parts: List[String], label: String, field: String, text: String) -> Result[List[String]]
  if text == ""
    return ok(parts)
  end
  if !text.to_bytes.all? do |byte| byte >= 32 and byte < 127 and byte != SEMICOLON end
    return error("invalid cookie #{field} (#{text})")
  end
  return ok(parts.push("#{label}=#{text}"))
end
