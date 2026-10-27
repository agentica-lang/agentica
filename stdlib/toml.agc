## Reads and writes TOML 1.0 documents.
##
## Import it with `import Toml from "std/toml"`. `Toml.parse` turns text into a `Toml.Value`, `Toml.encode` writes a
## `Toml.Value` back as text, and `Toml.to_json` bridges to typed decoding (`JSON.decode(json, T)`). Every
## function returns a `Result` and never halts. A parse error starts with the place, for example
## `line 3, column 7: expected '=' after key`; lines and columns count from 1, and a column counts characters. Arrays
## and inline tables nest at most 256 levels, and a key (a header or a dotted key) has at most 256 parts; a deeper
## input is an error at the opening bracket or the key.

## A TOML value. The root of a document is always a `Table`.
## A `Map` keeps the order its keys were first written in, so `encode` is deterministic.
export enum Value
  ## A string of any kind (basic, literal, multi-line).
  Str(String)
  ## A 64-bit integer. A value outside the signed 64-bit range is a parse error.
  Int(Int)
  ## A float; `inf` and `nan` are floats too.
  Float(Float)
  ## `true` or `false`.
  Bool(Bool)
  ## A date-time kept as the text it was written with: an offset date-time, a local date-time, a local date or a local
  ## time.
  DateTime(String)
  ## An array; TOML 1.0 allows mixed types.
  Array(List[Value])
  ## A table, an inline table, or the document itself.
  Table(Map[String, Value])
end

# How a table came to exist. A table can be opened by a `[header]` only while it is Implicit
# (made on the way to a deeper header). Dotted keys fix the shape of what they build.
enum Origin
  Implicit
  Header
  Dotted
end

# The tree built while reading. Unlike Value it knows which tables may still be extended:
# a Leaf (a scalar, a static array, an inline table) is sealed, and Rows is an array of tables
# whose last element is the one that later headers and keys extend.
enum Node
  Leaf(Value)
  Tab(Tbl)
  Rows(List[Node])
end

# `stamp` is the number of the section ([header]) that built a Dotted table: only that section
# may add more keys to it.
struct Tbl
  entries: Map[String, Node]
  origin: Origin
  stamp: Int
end

# The input as code points, with a class table (see class_table) for fast tests.
struct Src
  text: String
  codes: List[Int]
  n: Int
  cls: List[Int]
end

struct Parsed
  value: Value
  pos: Int
end

struct Scan
  text: String
  pos: Int
end

struct Key
  parts: List[String]
  pos: Int
end

## Reads a TOML document. Returns the root `Value.Table`, or an error that starts with `line L, column C: `.
## It checks all of TOML 1.0: a duplicate key, a table defined twice, extending an inline table or a static array, and
## a bad escape, number or date are errors. A CRLF line ending counts as one LF, also inside multi-line strings.
export def parse(text: String) -> Result[Value]
  src = make_src(text)
  root = Node.Tab(empty_tbl(Origin.Header, 0))
  header: List[String] = []
  section = 0
  p = 0
  while true
    p = skip_ws(src, p)
    c = at(src, p)
    if c == -1
      break
    elsif c == 10
      p += 1
    elsif c == 35
      p = try skip_comment(src, p)
    elsif c == 91
      is_array = at(src, p + 1) == 91
      first = p + 1
      if is_array
        first = p + 2
      end
      key = try parse_key(src, first)
      closing = "]"
      if is_array
        closing = "]]"
      end
      close_at = key.pos
      if piece(src, close_at, close_at + closing.length) != closing
        return error(place(src, close_at, "expected '#{closing}' to end the table header"))
      end
      section += 1
      opened = open_table(root, key.parts, is_array)
      if !opened.ok?
        return error(place(src, p, opened.message))
      end
      root = opened.unwrap!
      header = key.parts
      p = try end_of_line(src, close_at + closing.length)
    else
      key = try parse_key(src, p)
      if at(src, key.pos) != 61
        return error(place(src, key.pos, "expected '=' after key"))
      end
      value_at = skip_ws(src, key.pos + 1)
      parsed = try parse_value(src, value_at, 0)
      stored = put_key(root, header.concat(key.parts), header.size, parsed.value, section)
      if !stored.ok?
        return error(place(src, p, stored.message))
      end
      root = stored.unwrap!
      p = try end_of_line(src, parsed.pos)
    end
  end
  return ok(to_value(root))
end

## Writes a `Value.Table` as a TOML document ending in a newline. Any other root is an error.
## The output is deterministic: keys appear in the order of the `Map` (its insertion order). In each table, first the
## plain `key = value` lines of a table, then its sub-tables as `[a.b]` sections, and an array that holds only tables,
## when it is a direct entry of a table, as `[[a.b]]` sections, whatever the order of the `Map`; each group keeps the
## insertion order. Any other array or table (inside an array) is written inline. A key that is not a bare key
## (`A-Za-z0-9_-`) is quoted. Strings are basic strings with escapes. A float is written so that it reads back as the
## same float (`inf`, `-inf` and `nan` too). A `DateTime` whose text is not a valid TOML date-time is an error.
## `parse(encode(v))` gives back the same values and the same Map entries for every table `v` this function accepts,
## but the keys of a Map may be regrouped (plain entries first, then sub-tables, then arrays of tables). A table path
## of more than 256 parts or an inline value nested more than 256 levels is an error (the reader refuses such text), so
## the text that `encode` writes can always be read back. No value halts the function.
export def encode(value: Value) -> Result[String]
  case value
    Value.Table(entries) ->
      lines = try emit_table(entries, [], [], class_table())
      if lines.size == 0
        return ok("")
      end
      return ok("#{lines.join("\n")}\n")
    _ -> return error("the root of a TOML document must be a table")
  end
end

## Converts a `Value` to `Json`, for typed decoding: `JSON.decode(json, Config)`.
## A `DateTime` becomes its string. An `inf` or `nan` float is an error, since `Json` cannot hold it. An integer stays
## an integer and a float stays a float (`1.0` is not `1`). A value nested more than 2,048 levels (no document `parse`
## reads is that deep) is an error, not a halt.
export def to_json(value: Value) -> Result[Json]
  return json_of(value, 0)
end

## Looks up a value by a dotted path of keys: `Toml.get(doc, "package.name")`. A segment of plain ASCII digits without
## a leading zero also indexes an array (`"bin.0.path"`). Returns an error that names the missing key. A key that holds
## a dot cannot be reached this way: use `case` on the `Table`.
export def get(value: Value, path: String) -> Result[Value]
  current = value
  for part in path.split(".")
    case current
      Value.Table(entries) ->
        if !entries.has_key?(part)
          return error("no key \"#{part}\" in \"#{path}\"")
        end
        current = entries[part]
      Value.Array(items) ->
        index = part.to_i
        if !index_segment?(part) or !index.ok? or index.unwrap! >= items.size
          return error("no index \"#{part}\" in \"#{path}\"")
        end
        current = items[index.unwrap!]
      _ -> return error("\"#{part}\" in \"#{path}\" is not inside a table or an array")
    end
  end
  return ok(current)
end

# A plain run of ASCII digits without a leading zero (`0`, `7`, `12`): not `01`, `+1` or `-0`.
def index_segment?(part: String) -> Bool
  if part.length == 0 or (part.length > 1 and String.code(part.at(0)) == 48)
    return false
  end
  for ch in part.split("")
    c = String.code(ch)
    if c < 48 or c > 57
      return false
    end
  end
  return true
end

# `depth` counts the arrays and tables above `value`. The deepest tree `parse` can build has under
# 1,100 levels (256 header tables, as many arrays of tables, 256 dotted-key tables, 256 inline
# levels), so the limit of 2,048 never refuses a parsed document.
def json_of(value: Value, depth: Int) -> Result[Json]
  case value
    Value.Str(s) -> return ok(JSON.from(s))
    Value.Int(n) -> return ok(JSON.from(n))
    Value.Bool(b) -> return ok(JSON.from(b))
    Value.DateTime(s) -> return ok(JSON.from(s))
    Value.Float(x) ->
      if !finite?(x)
        return error("cannot convert #{float_text(x)} to JSON")
      end
      return ok(JSON.from(x))
    Value.Array(items) ->
      if depth >= 2048
        return error("a value nests more than 2048 levels")
      end
      out: List[Json] = []
      for item in items
        j = try json_of(item, depth + 1)
        out = out.push(j)
      end
      return ok(JSON.array(out))
    Value.Table(entries) ->
      if depth >= 2048
        return error("a value nests more than 2048 levels")
      end
      out: Map[String, Json] = {}
      for k in entries.keys
        j = try json_of(entries[k], depth + 1)
        out = out.put(k, j)
      end
      return ok(JSON.object(out))
  end
end

# Nesting limit of arrays, inline tables and keys. The recursion of the reader, the encoder and
# to_json is about three frames per level, far under the VM's call limit of 10,000.
def max_depth() -> Int
  return 256
end

def empty_tbl(origin: Origin, stamp: Int) -> Tbl
  entries: Map[String, Node] = {}
  return Tbl(entries: entries, origin: origin, stamp: stamp)
end

# Bits of the class table, indexed by code point (0 .. 127; other code points have none).
#   1 digit   2 bare-key character   4 hex digit   8 number character (digit, letter, _ . + -)
#   16 control character that TOML forbids in strings and comments (tab and LF are not)
#   32 ends a run of plain string characters (quote, apostrophe, backslash, LF)
def class_table() -> List[Int]
  table = List.repeat(0, 128)
  for i in 0...128
    bits = 0
    if i >= 48 and i <= 57
      bits = 1 + 2 + 4 + 8
    elsif (i >= 97 and i <= 102) or (i >= 65 and i <= 70)
      bits = 2 + 4 + 8
    elsif (i >= 97 and i <= 122) or (i >= 65 and i <= 90) or i == 95 or i == 45
      bits = 2 + 8
    elsif i == 46 or i == 43
      bits = 8
    elsif i == 34 or i == 39 or i == 92 or i == 10
      bits = 32
    end
    if i <= 8 or (i >= 11 and i <= 31) or i == 127
      bits = 16
    end
    table = table.set(i, bits)
  end
  return table
end

def make_src(text: String) -> Src
  clean = text.replace("\r\n", "\n")
  codes = clean.split("").map do |c| String.code(c) end
  return Src(text: clean, codes: codes, n: codes.size, cls: class_table())
end

# The code point at `pos`, or -1 past the end.
def at(src: Src, pos: Int) -> Int
  if pos >= 0 and pos < src.n
    return src.codes[pos]
  end
  return -1
end

def has(src: Src, c: Int, bit: Int) -> Bool
  return c >= 0 and c < 128 and src.cls[c].bit_and(bit) != 0
end

# The text of the characters `from` up to, not including, `to`.
def piece(src: Src, from: Int, to: Int) -> String
  stop = to
  if stop > src.n
    stop = src.n
  end
  if stop <= from
    return ""
  end
  return String.slice(src.text, from, stop - from)
end

# A message with its place. It runs only on the error path, so it may scan from the start.
def place(src: Src, pos: Int, message: String) -> String
  line = 1
  column = 1
  limit = pos
  if limit > src.n
    limit = src.n
  end
  i = 0
  while i < limit
    if src.codes[i] == 10
      line += 1
      column = 1
    else
      column += 1
    end
    i += 1
  end
  return "line #{line}, column #{column}: #{message}"
end

def skip_ws(src: Src, pos: Int) -> Int
  p = pos
  while at(src, p) == 32 or at(src, p) == 9
    p += 1
  end
  return p
end

# Skips a comment and returns the position of the LF that ends it (or of the end of input).
def skip_comment(src: Src, pos: Int) -> Result[Int]
  p = pos
  while at(src, p) != 10 and at(src, p) != -1
    if has(src, at(src, p), 16)
      return error(place(src, p, "control character in a comment"))
    end
    p += 1
  end
  return ok(p)
end

# Skips spaces, tabs, line ends and comments (inside an array).
def skip_trivia(src: Src, pos: Int) -> Result[Int]
  p = pos
  while true
    c = at(src, p)
    if c == 32 or c == 9 or c == 10
      p += 1
    elsif c == 35
      p = try skip_comment(src, p)
    else
      return ok(p)
    end
  end
  return ok(p)
end

# After a statement only a comment may follow on the line. Returns the position after the LF.
def end_of_line(src: Src, pos: Int) -> Result[Int]
  p = skip_ws(src, pos)
  if at(src, p) == 35
    p = try skip_comment(src, p)
  end
  c = at(src, p)
  if c == -1
    return ok(p)
  elsif c == 10
    return ok(p + 1)
  end
  return error(place(src, p, "expected a line end after the value"))
end

# A dotted key. `pos` of the result is after the key and the spaces that follow it.
def parse_key(src: Src, pos: Int) -> Result[Key]
  parts: List[String] = []
  p = skip_ws(src, pos)
  while true
    c = at(src, p)
    if c == 34
      quoted = try basic_string(src, p)
      parts = parts.push(quoted.text)
      p = quoted.pos
    elsif c == 39
      literal = try literal_string(src, p)
      parts = parts.push(literal.text)
      p = literal.pos
    elsif has(src, c, 2)
      e = p
      while has(src, at(src, e), 2)
        e += 1
      end
      parts = parts.push(piece(src, p, e))
      p = e
    else
      return error(place(src, p, "expected a key"))
    end
    if parts.size > max_depth()
      return error(place(src, pos, "a key has more than 256 parts"))
    end
    p = skip_ws(src, p)
    if at(src, p) == 46
      p = skip_ws(src, p + 1)
    else
      return ok(Key(parts: parts, pos: p))
    end
  end
  return error("unreachable")
end

def parse_value(src: Src, pos: Int, depth: Int) -> Result[Parsed]
  c = at(src, pos)
  if c == 34
    if at(src, pos + 1) == 34 and at(src, pos + 2) == 34
      long = try multi_basic(src, pos)
      return ok(Parsed(value: Value.Str(long.text), pos: long.pos))
    end
    short = try basic_string(src, pos)
    return ok(Parsed(value: Value.Str(short.text), pos: short.pos))
  elsif c == 39
    if at(src, pos + 1) == 39 and at(src, pos + 2) == 39
      long = try multi_literal(src, pos)
      return ok(Parsed(value: Value.Str(long.text), pos: long.pos))
    end
    short = try literal_string(src, pos)
    return ok(Parsed(value: Value.Str(short.text), pos: short.pos))
  elsif c == 91
    return parse_array(src, pos, depth)
  elsif c == 123
    return parse_inline_table(src, pos, depth)
  elsif c == 116 and word_at(src, pos, "true")
    return ok(Parsed(value: Value.Bool(true), pos: pos + 4))
  elsif c == 102 and word_at(src, pos, "false")
    return ok(Parsed(value: Value.Bool(false), pos: pos + 5))
  elsif c >= 48 and c <= 57 and date_time_start?(src, pos)
    stop = try date_time_end(src, pos)
    return ok(Parsed(value: Value.DateTime(piece(src, pos, stop)), pos: stop))
  elsif (c >= 48 and c <= 57) or c == 43 or c == 45 or c == 105 or c == 110
    return parse_number(src, pos)
  end
  return error(place(src, pos, "expected a value"))
end

# `word` at `pos`, not followed by another number character (so `truex` is not `true`).
def word_at(src: Src, pos: Int, word: String) -> Bool
  return piece(src, pos, pos + word.length) == word and !has(src, at(src, pos + word.length), 8)
end

def parse_array(src: Src, pos: Int, depth: Int) -> Result[Parsed]
  if depth >= max_depth()
    return error(place(src, pos, "arrays and inline tables nest more than 256 levels"))
  end
  items: List[Value] = []
  p = try skip_trivia(src, pos + 1)
  while true
    if at(src, p) == 93
      return ok(Parsed(value: Value.Array(items), pos: p + 1))
    end
    parsed = try parse_value(src, p, depth + 1)
    items = items.push(parsed.value)
    p = try skip_trivia(src, parsed.pos)
    c = at(src, p)
    if c == 44
      p = try skip_trivia(src, p + 1)
    elsif c != 93
      return error(place(src, p, "expected ',' or ']' in an array"))
    end
  end
  return error("unreachable")
end

# An inline table lives on one line and has no trailing comma. It is read with the same rules as
# a document, so dotted keys and duplicates behave the same, then sealed into a Value.
def parse_inline_table(src: Src, pos: Int, depth: Int) -> Result[Parsed]
  if depth >= max_depth()
    return error(place(src, pos, "arrays and inline tables nest more than 256 levels"))
  end
  node = Node.Tab(empty_tbl(Origin.Header, 0))
  p = skip_ws(src, pos + 1)
  if at(src, p) == 125
    return ok(Parsed(value: to_value(node), pos: p + 1))
  end
  while true
    key = try parse_key(src, p)
    if at(src, key.pos) != 61
      return error(place(src, key.pos, "expected '=' after key"))
    end
    parsed = try parse_value(src, skip_ws(src, key.pos + 1), depth + 1)
    stored = put_key(node, key.parts, 0, parsed.value, 0)
    if !stored.ok?
      return error(place(src, p, stored.message))
    end
    node = stored.unwrap!
    p = skip_ws(src, parsed.pos)
    c = at(src, p)
    if c == 44
      p = skip_ws(src, p + 1)
      if at(src, p) == 125
        return error(place(src, p, "an inline table cannot end with a comma"))
      end
    elsif c == 125
      return ok(Parsed(value: to_value(node), pos: p + 1))
    else
      return error(place(src, p, "expected ',' or '}' in an inline table"))
    end
  end
  return error("unreachable")
end

# ---- strings ----

# A basic string on one line. `pos` is at the opening quote.
def basic_string(src: Src, pos: Int) -> Result[Scan]
  parts: List[String] = []
  start = pos + 1
  i = pos + 1
  while true
    c = at(src, i)
    if !has(src, c, 48) and c != -1
      i += 1
    elsif c == 34
      parts = parts.push(piece(src, start, i))
      return ok(Scan(text: parts.join(""), pos: i + 1))
    elsif c == 92
      parts = parts.push(piece(src, start, i))
      escaped = try read_escape(src, i + 1)
      parts = parts.push(escaped.text)
      i = escaped.pos
      start = i
    elsif c == -1 or c == 10
      return error(place(src, pos, "unterminated string"))
    elsif has(src, c, 16)
      return error(place(src, i, "control character in a string"))
    else
      i += 1
    end
  end
  return error("unreachable")
end

def literal_string(src: Src, pos: Int) -> Result[Scan]
  i = pos + 1
  while true
    c = at(src, i)
    if !has(src, c, 48) and c != -1
      i += 1
    elsif c == 39
      return ok(Scan(text: piece(src, pos + 1, i), pos: i + 1))
    elsif c == -1 or c == 10
      return error(place(src, pos, "unterminated string"))
    elsif has(src, c, 16)
      return error(place(src, i, "control character in a string"))
    else
      i += 1
    end
  end
  return error("unreachable")
end

# Counts the run of `quote` characters at `pos`, up to 6.
def quote_run(src: Src, pos: Int, quote: Int) -> Int
  n = 0
  while n < 6 and at(src, pos + n) == quote
    n += 1
  end
  return n
end

# A multi-line basic string. `pos` is at the first of the three opening quotes.
def multi_basic(src: Src, pos: Int) -> Result[Scan]
  parts: List[String] = []
  i = pos + 3
  if at(src, i) == 10
    i += 1
  end
  start = i
  while true
    c = at(src, i)
    if !has(src, c, 48) and c != -1
      i += 1
    elsif c == 34
      run = quote_run(src, i, 34)
      if run < 3
        i += run
      elsif run > 5
        return error(place(src, i, "too many quotes in a multi-line string"))
      else
        # One or two quotes before the closing three belong to the text.
        parts = parts.push(piece(src, start, i + run - 3))
        return ok(Scan(text: parts.join(""), pos: i + run))
      end
    elsif c == 92
      parts = parts.push(piece(src, start, i))
      after = skip_ws(src, i + 1)
      if at(src, after) == 10
        # A backslash that ends a line removes the line end and the white space after it.
        k = after
        while at(src, k) == 32 or at(src, k) == 9 or at(src, k) == 10
          k += 1
        end
        i = k
      else
        escaped = try read_escape(src, i + 1)
        parts = parts.push(escaped.text)
        i = escaped.pos
      end
      start = i
    elsif c == -1
      return error(place(src, pos, "unterminated string"))
    elsif c == 10
      i += 1
    elsif has(src, c, 16)
      return error(place(src, i, "control character in a string"))
    else
      i += 1
    end
  end
  return error("unreachable")
end

def multi_literal(src: Src, pos: Int) -> Result[Scan]
  i = pos + 3
  if at(src, i) == 10
    i += 1
  end
  start = i
  while true
    c = at(src, i)
    if !has(src, c, 48) and c != -1
      i += 1
    elsif c == 39
      run = quote_run(src, i, 39)
      if run < 3
        i += run
      elsif run > 5
        return error(place(src, i, "too many quotes in a multi-line string"))
      else
        return ok(Scan(text: piece(src, start, i + run - 3), pos: i + run))
      end
    elsif c == -1
      return error(place(src, pos, "unterminated string"))
    elsif c == 10
      i += 1
    elsif has(src, c, 16)
      return error(place(src, i, "control character in a string"))
    else
      i += 1
    end
  end
  return error("unreachable")
end

# The escape after a backslash; `pos` is at the character after it.
def read_escape(src: Src, pos: Int) -> Result[Scan]
  c = at(src, pos)
  if c == 98
    return ok(Scan(text: String.from_code(8), pos: pos + 1))
  elsif c == 116
    return ok(Scan(text: String.from_code(9), pos: pos + 1))
  elsif c == 110
    return ok(Scan(text: String.from_code(10), pos: pos + 1))
  elsif c == 102
    return ok(Scan(text: String.from_code(12), pos: pos + 1))
  elsif c == 114
    return ok(Scan(text: String.from_code(13), pos: pos + 1))
  elsif c == 34
    return ok(Scan(text: "\"", pos: pos + 1))
  elsif c == 92
    return ok(Scan(text: "\\", pos: pos + 1))
  elsif c == 117
    return read_unicode(src, pos + 1, 4)
  elsif c == 85
    return read_unicode(src, pos + 1, 8)
  end
  return error(place(src, pos - 1, "invalid escape in a string"))
end

# `count` hex digits at `pos` that must name a Unicode scalar value (no surrogates).
def read_unicode(src: Src, pos: Int, count: Int) -> Result[Scan]
  code = 0
  for i in 0...count
    d = hex_value(at(src, pos + i))
    if d < 0
      return error(place(src, pos - 2, "a unicode escape needs #{count} hex digits"))
    end
    code = code * 16 + d
  end
  if code > 1114111 or (code >= 55296 and code <= 57343)
    return error(place(src, pos - 2, "a unicode escape must be a Unicode scalar value"))
  end
  return ok(Scan(text: String.from_code(code), pos: pos + count))
end

# 0 .. 15 for a hex digit, -1 for anything else.
def hex_value(c: Int) -> Int
  if c >= 48 and c <= 57
    return c - 48
  elsif c >= 97 and c <= 102
    return c - 87
  elsif c >= 65 and c <= 70
    return c - 55
  end
  return -1
end

# ---- numbers ----

# The end of a run of digits with single underscores between digits: `1_000`. Returns `pos` when
# there is no digit. A trailing or doubled underscore is not consumed, so the caller finds it.
def digit_run(src: Src, pos: Int) -> Int
  if !has(src, at(src, pos), 1)
    return pos
  end
  p = pos + 1
  while true
    c = at(src, p)
    if has(src, c, 1)
      p += 1
    elsif c == 95 and has(src, at(src, p + 1), 1)
      p += 2
    else
      return p
    end
  end
  return p
end

def parse_number(src: Src, pos: Int) -> Result[Parsed]
  stop = pos
  while has(src, at(src, stop), 8)
    stop += 1
  end
  p = pos
  c = at(src, p)
  negative = c == 45
  if c == 43 or c == 45
    p += 1
  end
  c = at(src, p)
  if c == 105 or c == 110
    word = piece(src, p, stop)
    if word == "inf"
      if negative
        return ok(Parsed(value: Value.Float(Float.from_bits(-4503599627370496)), pos: stop))
      end
      return ok(Parsed(value: Value.Float(Float.from_bits(9218868437227405312)), pos: stop))
    elsif word == "nan"
      return ok(Parsed(value: Value.Float(Float.from_bits(9221120237041090560)), pos: stop))
    end
    return error(place(src, pos, "invalid number"))
  end
  next = at(src, p + 1)
  if p == pos and c == 48 and (next == 120 or next == 111 or next == 98)
    radix = 16
    if next == 111
      radix = 8
    elsif next == 98
      radix = 2
    end
    return radix_integer(src, pos, p + 2, stop, radix)
  end
  whole = digit_run(src, p)
  if whole == p
    return error(place(src, pos, "invalid number"))
  end
  if whole - p > 1 and c == 48
    return error(place(src, pos, "a number cannot have leading zeros"))
  end
  j = whole
  is_float = false
  if at(src, j) == 46
    fraction = digit_run(src, j + 1)
    if fraction == j + 1
      return error(place(src, pos, "a float needs digits after the point"))
    end
    j = fraction
    is_float = true
  end
  if at(src, j) == 101 or at(src, j) == 69
    k = j + 1
    if at(src, k) == 43 or at(src, k) == 45
      k += 1
    end
    exponent = digit_run(src, k)
    if exponent == k
      return error(place(src, pos, "a float needs digits in its exponent"))
    end
    j = exponent
    is_float = true
  end
  if j != stop
    return error(place(src, pos, "invalid number"))
  end
  digits = piece(src, p, stop).replace("_", "")
  if is_float
    return decimal_float(src, pos, digits, negative, stop)
  end
  sign = ""
  if negative
    sign = "-"
  end
  value = String.to_int(sign + digits)
  if !value.ok?
    return error(place(src, pos, "integer out of the 64-bit range"))
  end
  return ok(Parsed(value: Value.Int(value.unwrap!), pos: stop))
end

# The JSON number grammar is the TOML float grammar without underscores and a leading plus, and
# its reader rounds correctly. A zero keeps its sign.
def decimal_float(src: Src, pos: Int, digits: String, negative: Bool, stop: Int) -> Result[Parsed]
  x = Float.from_bits(9218868437227405312)
  json = JSON.parse(digits)
  if json.ok?
    magnitude = JSON.float(json.unwrap!)
    if magnitude.ok?
      x = magnitude.unwrap!
    end
  end
  # The text is a valid float, so a reader error means a magnitude above the largest float. IEEE
  # rounding gives infinity then (1e400 is inf), and the peer parsers agree.
  if negative
    x = x * (0.0 - 1.0)
  end
  return ok(Parsed(value: Value.Float(x), pos: stop))
end

# `0x`, `0o` and `0b` integers: digits from `from` up to `stop`, no sign, leading zeros allowed.
def radix_integer(src: Src, pos: Int, from: Int, stop: Int, radix: Int) -> Result[Parsed]
  if from >= stop
    return error(place(src, pos, "an integer needs digits"))
  end
  limit = 9223372036854775807
  value = 0
  previous_digit = false
  for i in from...stop
    c = at(src, i)
    if c == 95
      if !previous_digit or i + 1 >= stop
        return error(place(src, pos, "misplaced underscore in a number"))
      end
      previous_digit = false
    else
      d = hex_value(c)
      if d < 0 or d >= radix
        return error(place(src, pos, "invalid digit in a number"))
      end
      if value > (limit - d) / radix
        return error(place(src, pos, "integer out of the 64-bit range"))
      end
      value = value * radix + d
      previous_digit = true
    end
  end
  return ok(Parsed(value: Value.Int(value), pos: stop))
end

# ---- dates and times ----

# The `count` digits at `pos` as a number, or -1 when one of them is not a digit.
def number_at(src: Src, pos: Int, count: Int) -> Int
  value = 0
  for i in 0...count
    c = at(src, pos + i)
    if c < 48 or c > 57
      return -1
    end
    value = value * 10 + c - 48
  end
  return value
end

def date_time_start?(src: Src, pos: Int) -> Bool
  return (
    (number_at(src, pos, 4) >= 0 and at(src, pos + 4) == 45) or
    (number_at(src, pos, 2) >= 0 and at(src, pos + 2) == 58)
  )
end

def days_in_month(year: Int, month: Int) -> Int
  if month == 2
    if (year % 4 == 0 and year % 100 != 0) or year % 400 == 0
      return 29
    end
    return 28
  elsif month == 4 or month == 6 or month == 9 or month == 11
    return 30
  end
  return 31
end

# Reads a local date, a local time, a local date-time or an offset date-time at `pos` and
# returns where it ends.
def date_time_end(src: Src, pos: Int) -> Result[Int]
  if at(src, pos + 2) == 58
    return time_end(src, pos)
  end
  year = number_at(src, pos, 4)
  month = number_at(src, pos + 5, 2)
  day = number_at(src, pos + 8, 2)
  if year < 0 or month < 1 or month > 12 or at(src, pos + 7) != 45 or day < 1 or day > days_in_month(year, month)
    return error(place(src, pos, "invalid date"))
  end
  stop = pos + 10
  c = at(src, stop)
  has_time = c == 84 or c == 116
  if c == 32 and number_at(src, stop + 1, 2) >= 0 and at(src, stop + 3) == 58
    has_time = true
  end
  if !has_time
    return ok(stop)
  end
  clock_end = try time_end(src, stop + 1)
  c = at(src, clock_end)
  if c == 90 or c == 122
    return ok(clock_end + 1)
  elsif c == 43 or c == 45
    hours = number_at(src, clock_end + 1, 2)
    minutes = number_at(src, clock_end + 4, 2)
    if hours < 0 or hours > 23 or at(src, clock_end + 3) != 58 or minutes < 0 or minutes > 59
      return error(place(src, clock_end, "invalid time offset"))
    end
    return ok(clock_end + 6)
  end
  return ok(clock_end)
end

# `HH:MM:SS` with optional fractional seconds; a leap second (60) is accepted, as TOML allows.
def time_end(src: Src, pos: Int) -> Result[Int]
  hour = number_at(src, pos, 2)
  minute = number_at(src, pos + 3, 2)
  second = number_at(src, pos + 6, 2)
  if (
    hour < 0 or
    hour > 23 or
    minute < 0 or
    minute > 59 or
    second < 0 or
    second > 60 or
    at(src, pos + 2) != 58 or
    at(src, pos + 5) != 58
  )
    return error(place(src, pos, "invalid time"))
  end
  stop = pos + 8
  if at(src, stop) == 46
    fraction = stop + 1
    while has(src, at(src, fraction), 1)
      fraction += 1
    end
    if fraction == stop + 1
      return error(place(src, stop, "a time needs digits after the point"))
    end
    stop = fraction
  end
  return ok(stop)
end

# True when `text` is exactly one TOML date-time (used by the encoder, which builds the class table
# once per document).
def valid_date_time?(text: String, cls: List[Int]) -> Bool
  codes = text.split("").map do |c| String.code(c) end
  src = Src(text: text, codes: codes, n: codes.size, cls: cls)
  if !date_time_start?(src, 0)
    return false
  end
  stop = date_time_end(src, 0)
  return stop.ok? and stop.unwrap! == src.n
end

# ---- the tree ----

# Applies a `[header]` or `[[header]]` to the tree and returns the new tree. The root is a Tab.
def open_table(root: Node, path: List[String], is_array: Bool) -> Result[Node]
  case root
    Node.Tab(table) -> return header_into(table, path, 0, is_array)
    _ -> return error("internal error: the root is not a table")
  end
end

def header_into(table: Tbl, path: List[String], i: Int, is_array: Bool) -> Result[Node]
  seg = path[i]
  entries = table.entries
  if i == path.size - 1
    made = try header_last(entries, seg, path.join("."), is_array)
    return ok(Node.Tab(table.with(entries: entries.put(seg, made))))
  end
  child = Node.Tab(empty_tbl(Origin.Implicit, 0))
  if entries.has_key?(seg)
    child = entries[seg]
  end
  case child
    Node.Tab(inner) ->
      sub = try header_into(inner, path, i + 1, is_array)
      return ok(Node.Tab(table.with(entries: entries.put(seg, sub))))
    Node.Rows(rows) ->
      sub = try header_into(last_row(rows), path, i + 1, is_array)
      replaced = Node.Rows(rows.set(rows.size - 1, sub))
      return ok(Node.Tab(table.with(entries: entries.put(seg, replaced))))
    Node.Leaf(_) ->
      held = path.join(".")
      return error("\"#{seg}\" is not a table, so it cannot hold \"#{held}\"")
  end
end

# The element of an array of tables that headers and keys extend.
def last_row(rows: List[Node]) -> Tbl
  case rows[rows.size - 1]
    Node.Tab(table) -> return table
    _ -> return empty_tbl(Origin.Header, 0)
  end
end

# The last segment of a header: what `seg` becomes in `entries`.
def header_last(entries: Map[String, Node], seg: String, name: String, is_array: Bool) -> Result[Node]
  if is_array
    if !entries.has_key?(seg)
      return ok(Node.Rows([Node.Tab(empty_tbl(Origin.Header, 0))]))
    end
    case entries[seg]
      Node.Rows(rows) -> return ok(Node.Rows(rows.push(Node.Tab(empty_tbl(Origin.Header, 0)))))
      _ -> return error("\"#{name}\" is already defined and is not an array of tables")
    end
  end
  if !entries.has_key?(seg)
    return ok(Node.Tab(empty_tbl(Origin.Header, 0)))
  end
  case entries[seg]
    Node.Tab(existing) ->
      case existing.origin
        Origin.Implicit -> return ok(Node.Tab(existing.with(origin: Origin.Header)))
        Origin.Header -> return error("table \"#{name}\" is already defined")
        Origin.Dotted -> return error("table \"#{name}\" is already defined by dotted keys")
      end
    Node.Rows(_) -> return error("\"#{name}\" is an array of tables, not a table")
    Node.Leaf(_) -> return error("\"#{name}\" is already defined")
  end
end

# Stores `value` at `full` (the current header, then the key). Segments before `header_size` walk
# the header; the others are dotted-key steps. A step may enter a table only if no `[header]` or
# earlier section made it, so `a.b = 1` and `[a]` cannot both define `a`.
def put_key(root: Node, full: List[String], header_size: Int, value: Value, section: Int) -> Result[Node]
  case root
    Node.Tab(table) -> return put_into(table, full, header_size, 0, value, section)
    _ -> return error("internal error: the root is not a table")
  end
end

def put_into(table: Tbl, full: List[String], header_size: Int, i: Int, value: Value, section: Int) -> Result[Node]
  seg = full[i]
  entries = table.entries
  if i == full.size - 1
    if entries.has_key?(seg)
      return error("key \"#{seg}\" is already defined")
    end
    return ok(Node.Tab(table.with(entries: entries.put(seg, Node.Leaf(value)))))
  end
  child = Node.Tab(empty_tbl(Origin.Dotted, section))
  if entries.has_key?(seg)
    child = entries[seg]
  end
  case child
    Node.Tab(inner) ->
      entered = inner
      if i >= header_size
        case inner.origin
          Origin.Header -> return error("cannot add keys to table \"#{seg}\", which a header defines")
          Origin.Dotted ->
            if inner.stamp != section
              return error("cannot add keys to table \"#{seg}\", which dotted keys defined in an earlier section")
            end
          Origin.Implicit -> entered = inner.with(origin: Origin.Dotted, stamp: section)
        end
      end
      sub = try put_into(entered, full, header_size, i + 1, value, section)
      return ok(Node.Tab(table.with(entries: entries.put(seg, sub))))
    Node.Rows(rows) ->
      if i >= header_size
        return error("cannot add keys to the array of tables \"#{seg}\" with dotted keys")
      end
      sub = try put_into(last_row(rows), full, header_size, i + 1, value, section)
      return ok(Node.Tab(table.with(entries: entries.put(seg, Node.Rows(rows.set(rows.size - 1, sub))))))
    Node.Leaf(_) -> return error("\"#{seg}\" is a value, not a table")
  end
end

def to_value(node: Node) -> Value
  case node
    Node.Leaf(value) -> return value
    Node.Rows(rows) -> return Value.Array(rows.map do |row| to_value(row) end)
    Node.Tab(table) ->
      out: Map[String, Value] = {}
      for k in table.entries.keys
        out = out.put(k, to_value(table.entries[k]))
      end
      return Value.Table(out)
  end
end

# ---- writing ----

def finite?(x: Float) -> Bool
  return x == x and x != Float.from_bits(9218868437227405312) and x != Float.from_bits(-4503599627370496)
end

def float_text(x: Float) -> String
  if x != x
    return "nan"
  elsif x == Float.from_bits(9218868437227405312)
    return "inf"
  elsif x == Float.from_bits(-4503599627370496)
    return "-inf"
  end
  return String.from_float(x)
end

def hex_digit(n: Int) -> String
  return String.slice("0123456789ABCDEF", n, 1)
end

# The escape of one character that a basic string cannot hold as it is.
def escape_for(c: Int) -> String
  if c == 34
    return "\\\""
  elsif c == 92
    return "\\\\"
  elsif c == 8
    return "\\b"
  elsif c == 9
    return "\\t"
  elsif c == 10
    return "\\n"
  elsif c == 12
    return "\\f"
  elsif c == 13
    return "\\r"
  end
  return "\\u00#{hex_digit(c / 16)}#{hex_digit(c % 16)}"
end

# A basic string with escapes. Characters above 127 are written as they are. Runs of plain
# characters are copied as one slice, so a string with nothing to escape costs one slice.
def quote(s: String) -> String
  chars = s.split("")
  parts: List[String] = ["\""]
  start = 0
  i = 0
  while i < chars.size
    c = String.code(chars[i])
    if c < 32 or c == 34 or c == 92 or c == 127
      if i > start
        parts = parts.push(String.slice(s, start, i - start))
      end
      parts = parts.push(escape_for(c))
      start = i + 1
    end
    i += 1
  end
  if chars.size > start
    parts = parts.push(String.slice(s, start, chars.size - start))
  end
  parts = parts.push("\"")
  return parts.join("")
end

def bare_key?(key: String) -> Bool
  if key.length == 0
    return false
  end
  for ch in key.split("")
    c = String.code(ch)
    if !((c >= 97 and c <= 122) or (c >= 65 and c <= 90) or (c >= 48 and c <= 57) or c == 95 or c == 45)
      return false
    end
  end
  return true
end

def key_text(key: String) -> String
  if bare_key?(key)
    return key
  end
  return quote(key)
end

def path_text(path: List[String]) -> String
  return path.map do |k| key_text(k) end.join(".")
end

# `depth` counts the arrays and tables above `value`; the reader refuses more than 256, so the
# writer does too, and what it writes can be read back.
def inline(value: Value, cls: List[Int], depth: Int) -> Result[String]
  case value
    Value.Str(s) -> return ok(quote(s))
    Value.Int(n) -> return ok(n.to_s)
    Value.Float(x) -> return ok(float_text(x))
    Value.Bool(b) -> return ok(b.to_s)
    Value.DateTime(s) ->
      if !valid_date_time?(s, cls)
        return error("not a valid TOML date-time: #{quote(s)}")
      end
      return ok(s)
    Value.Array(items) ->
      if depth >= max_depth()
        return error("arrays and inline tables nest more than 256 levels")
      end
      texts: List[String] = []
      for item in items
        text = try inline(item, cls, depth + 1)
        texts = texts.push(text)
      end
      return ok("[#{texts.join(", ")}]")
    Value.Table(entries) ->
      if depth >= max_depth()
        return error("arrays and inline tables nest more than 256 levels")
      end
      texts: List[String] = []
      for k in entries.keys
        text = try inline(entries[k], cls, depth + 1)
        texts = texts.push("#{key_text(k)} = #{text}")
      end
      return ok("{#{texts.join(", ")}}")
  end
end

# An array that is written as `[[name]]` sections: not empty, and every item is a table.
def table_array?(value: Value) -> Bool
  case value
    Value.Array(items) ->
      if items.size == 0
        return false
      end
      for item in items
        case item
          Value.Table(_) -> next
          _ -> return false
        end
      end
      return true
    _ -> return false
  end
end

# Writes a table's plain entries, then its sections. `path` is the table's own path.
def emit_table(
  entries: Map[String, Value],
  path: List[String],
  out: List[String],
  cls: List[Int],
) -> Result[List[String]]
  if path.size > max_depth()
    return error("tables nest more than 256 levels")
  end
  lines = out
  for k in entries.keys
    v = entries[k]
    case v
      Value.Table(_) -> next
      _ ->
        if !table_array?(v)
          text = try inline(v, cls, 0)
          lines = lines.push("#{key_text(k)} = #{text}")
        end
    end
  end
  for k in entries.keys
    v = entries[k]
    sub_path = path.push(k)
    case v
      Value.Table(sub) ->
        # A table with only sub-tables needs no header of its own.
        if sub.size == 0 or has_plain?(sub)
          if lines.size > 0
            lines = lines.push("")
          end
          lines = lines.push("[#{path_text(sub_path)}]")
        end
        lines = try emit_table(sub, sub_path, lines, cls)
      Value.Array(items) ->
        if table_array?(v)
          for item in items
            case item
              Value.Table(row) ->
                if lines.size > 0
                  lines = lines.push("")
                end
                lines = lines.push("[[#{path_text(sub_path)}]]")
                lines = try emit_table(row, sub_path, lines, cls)
              _ -> next
            end
          end
        end
      _ -> next
    end
  end
  return ok(lines)
end

# True when a table has an entry that is written as a `key = value` line.
def has_plain?(entries: Map[String, Value]) -> Bool
  for k in entries.keys
    v = entries[k]
    case v
      Value.Table(_) -> next
      _ ->
        if !table_array?(v)
          return true
        end
    end
  end
  return false
end
