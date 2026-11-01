## Regular expressions with a linear-time matcher.
##
## Import it with `import Regex from "std/regex"`. `Regex.compile` turns a pattern into a `Regex.Regex`; `match?`,
## `match`, `find_all`, `replace` and `split` search a text with it. The syntax is the subset of RE2 and Go (no
## backreferences, no lookaround), the match is leftmost-first, and positions count characters. A search runs a Pike
## VM over the code points, in the VM: its cost grows with the text length times the pattern size, whatever the
## input. A compile error starts with the place, for example `character 9: missing ')' for the group at character 1`;
## characters count from 1. Nothing halts.

MAX_PATTERN = 4096
MAX_COUNT = 1000
MAX_INSTS = 10000
MAX_DEPTH = 256
MAX_GROUPS = 256
MAX_CODE = 0x10FFFF
# Instruction codes of `Program.ops`, as vm/regex.c reads them.
OP_CHAR = 0
OP_CLASS = 1
OP_ANY = 2
OP_ANY_NL = 3
OP_SPLIT = 4
OP_JUMP = 5
OP_SAVE = 6
OP_ASSERT = 7
OP_MATCH = 8
# Kinds of OP_ASSERT.
BEGIN_TEXT = 0
END_TEXT = 1
BEGIN_LINE = 2
END_LINE = 3
WORD_EDGE = 4
NOT_WORD_EDGE = 5
# What RegexEngine.search returns: the end of a match ([] for none), the groups of the first match, or the groups of
# every match one after the other.
MODE_TEST = 0
MODE_FIRST = 1
MODE_ALL = 2
# Classes as sorted, disjoint [low, high] pairs of code points.
DIGIT_RANGES = [48, 57]
WORD_RANGES = [48, 57, 65, 90, 95, 95, 97, 122]
SPACE_RANGES = [9, 10, 12, 13, 32, 32]
WORD_ASCII = (0...128).to_a.map do |c|
  (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or c == 95 or (c >= 97 and c <= 122)
end
HEX_DIGITS = "0123456789abcdef"
SPECIAL = Set.new(["\\", ".", "+", "*", "?", "(", ")", "|", "[", "]", "{", "}", "^", "$"])

## A compiled pattern, made by `compile`.
export struct Regex
  ## The pattern it was compiled from.
  source: String
  ## Private: only `compile` makes it.
  program: Program
end

## One match of a search. Positions are character indexes; `stop` is the index after the last character.
export struct Match
  ## The whole match, the same as `groups[0].text`.
  text: String
  start: Int
  stop: Int
  ## `groups[0]` is the whole match, then one entry per group in the order of its `(`.
  groups: List[Group]
  ## Each group name with its index in `groups`.
  names: Map[String, Int]
end

## One group of a match. A group that did not take part has `matched` false, `text` "" and both positions -1.
export struct Group
  text: String
  start: Int
  stop: Int
  matched: Bool
end

# The compiled pattern. Instruction pc is (ops[pc], xs[pc], ys[pc]): CHAR code, CLASS index into classes, SPLIT
# preferred-pc other-pc, JUMP pc, SAVE slot, ASSERT kind. The last instruction is MATCH. RegexEngine.search
# (vm/regex.c) runs it and checks it first. `seal` is always empty: JSON.decode cannot build a Set, so it cannot build
# a Regex either, and `compile` stays the only maker of a Program (an importer cannot name the type or update a value
# of it).
struct Program
  ops: List[Int]
  xs: List[Int]
  ys: List[Int]
  classes: List[List[Int]]
  ncap: Int
  names: Map[String, Int]
  seal: Set[Int]
end

# The parse tree. Class holds sorted, disjoint [low, high] pairs, after case folding and negation. Rep is body, min,
# max (-1 when unbounded) and greedy.
enum Node
  Empty
  Lit(Int)
  Class(List[Int])
  Any(Bool)
  Assert(Int)
  Cat(List[Node])
  Alt(List[Node])
  Rep(Node, Int, Int, Bool)
  Group(Node, Int)
end

struct Pat
  chars: List[String]
  codes: List[Int]
  n: Int
end

struct Flags
  fold: Bool
  multi: Bool
  dotall: Bool
end

struct St
  pos: Int
  flags: Flags
  groups: Int
  names: Map[String, Int]
end

# `bare` marks a flag group such as `(?i)`, which sets flags and matches nothing, so it cannot be repeated.
struct Out
  node: Node
  st: St
  bare: Bool = false
end

struct Quant
  min: Int
  max: Int
  stop: Int
end

struct Num
  value: Int
  stop: Int
end

# What an escape stands for: an assertion (kind >= 0), one code point (code >= 0) or a class (ranges).
struct Esc
  kind: Int
  code: Int
  ranges: List[Int]
  stop: Int
end

struct Code
  ops: List[Int]
  xs: List[Int]
  ys: List[Int]
  classes: List[List[Int]]
end

enum Piece
  Text(String)
  Ref(Int)
end

struct FlagScan
  flags: Flags
  stop: Int
  scoped: Bool
end

## Parses and compiles a pattern. An error starts with `character N: `, N counted from 1: this prefix is a contract,
## since the checker reads it to place CHECK-INVALID-REGEX in a regex literal (compiler/check/check_regex.agc). Limits:
## 4096 characters, a repetition count of 1000, 10000 instructions after repetitions are expanded, groups nested 256
## levels deep and 256 groups.
export def compile(pattern: String) -> Result[Regex]
  chars = pattern.split("")
  if chars.size > MAX_PATTERN
    return error(place(MAX_PATTERN, "the pattern is longer than #{MAX_PATTERN} characters"))
  end
  pat = Pat(chars: chars, codes: chars.map do |c| c.code end, n: chars.size)
  start = St(pos: 0, flags: Flags(fold: false, multi: false, dotall: false), groups: 0, names: {})
  out = try parse_alt(pat, start, 0)
  # parse_alt stops only at the end or at a `)` that closes no group.
  if out.st.pos < pat.n
    return error(place(out.st.pos, "unexpected ')'"))
  end
  if size_of(out.node) > MAX_INSTS
    return error(place(0, "the pattern needs more than #{MAX_INSTS} instructions"))
  end
  return ok(Regex(source: pattern, program: build(out.node, out.st.groups, out.st.names)))
end

## Whether the pattern matches anywhere in `text`. It keeps no groups, so it is the cheapest search.
export def match?(text: String, re: Regex) -> Bool
  return run(text, re.program, MODE_TEST).size > 0
end

## The leftmost-first match in `text`, or `error("no match")`.
export def match(text: String, re: Regex) -> Result[Match]
  caps = run(text, re.program, MODE_FIRST)
  if caps.size == 0
    return error("no match")
  end
  return ok(make_match(text, caps, 0, re.program))
end

## Every match from left to right, without overlaps. After an empty match the search moves one character on, and an
## empty match right where the previous match ended is dropped (Go's rule).
export def find_all(text: String, re: Regex) -> List[Match]
  prog = re.program
  caps = run(text, prog, MODE_ALL)
  found: List[Match] = []
  at = 0
  while at < caps.size
    found = found.push(make_match(text, caps, at, prog))
    at += prog.ncap
  end
  return found
end

## Replaces every match that `find_all` finds. In `template`, `$0` is the whole match, `$N` group N (the
## longest run of digits), `${N}` and `${name}` a group, and `$$` a dollar sign; a group that did not take part gives
## "". The template is checked before any text is replaced: another `$` form or a missing group is an error.
export def replace(text: String, re: Regex, template: String) -> Result[String]
  pieces = try parse_template(template, re.program)
  ncap = re.program.ncap
  caps = run(text, re.program, MODE_ALL)
  out: List[String] = []
  last = 0
  at = 0
  while at < caps.size
    out = out.push(slice(text, last, caps[at]))
    for piece in pieces
      case piece
        Piece.Text(s) -> out = out.push(s)
        Piece.Ref(g) ->
          start = caps[at + 2 * g]
          stop = caps[at + 2 * g + 1]
          if start >= 0 and stop >= start
            out = out.push(slice(text, start, stop))
          end
      end
    end
    last = caps[at + 1]
    at += ncap
  end
  out = out.push(slice(text, last, text.length))
  return ok(out.join(""))
end

## The parts of `text` between the matches that take at least one character. Empty parts are kept, and an empty
## match separates nothing.
export def split(text: String, re: Regex) -> List[String]
  ncap = re.program.ncap
  caps = run(text, re.program, MODE_ALL)
  parts: List[String] = []
  last = 0
  at = 0
  while at < caps.size
    if caps[at + 1] > caps[at]
      parts = parts.push(slice(text, last, caps[at]))
      last = caps[at + 1]
    end
    at += ncap
  end
  return parts.push(slice(text, last, text.length))
end

## A pattern that matches `text` literally. A backslash goes before each of the characters `\.+*?()|[]{}^$`.
export def escape(text: String) -> String
  return text.split("").map(&escape_char).join("")
end

## The group of `m` with that name, or an error when the pattern has no such group.
export def named(m: Match, name: String) -> Result[Group]
  case m.names.get(name)
    some(index) if index >= 0 and index < m.groups.size -> return ok(m.groups[index])
    _ -> return error("no group named \"#{name}\"")
  end
end

def place(pos: Int, message: String) -> String
  return "character #{pos + 1}: #{message}"
end

def ch(pat: Pat, pos: Int) -> String
  if pos < pat.n
    return pat.chars[pos]
  end
  return ""
end

def piece_of(pat: Pat, from: Int, to: Int) -> String
  return pat.chars.drop(from).take(to - from).join("")
end

def parse_alt(pat: Pat, st: St, depth: Int) -> Result[Out]
  branches: List[Node] = []
  cur = st
  while true
    out = try parse_cat(pat, cur, depth)
    branches = branches.push(out.node)
    cur = out.st
    if ch(pat, cur.pos) != "|"
      break
    end
    cur = cur.with(pos: cur.pos + 1)
  end
  if branches.size == 1
    return ok(Out(node: branches[0], st: cur))
  end
  return ok(Out(node: Node.Alt(branches), st: cur))
end

def parse_cat(pat: Pat, st: St, depth: Int) -> Result[Out]
  items: List[Node] = []
  cur = st
  while true
    c = ch(pat, cur.pos)
    if c == "" or c == "|" or c == ")"
      break
    end
    if quantifier(pat, cur.pos).some?
      return error(place(cur.pos, "nothing to repeat before '#{c}'"))
    end
    atom = try parse_atom(pat, cur, depth)
    cur = atom.st
    if !atom.bare
      rep = try parse_repeat(pat, atom)
      items = items.push(rep.node)
      cur = rep.st
    end
  end
  if items.size == 0
    return ok(Out(node: Node.Empty, st: cur))
  elsif items.size == 1
    return ok(Out(node: items[0], st: cur))
  end
  return ok(Out(node: Node.Cat(items), st: cur))
end

def parse_repeat(pat: Pat, atom: Out) -> Result[Out]
  at = atom.st.pos
  case quantifier(pat, at)
    none -> return ok(atom)
    some(q) ->
      if q.max != -1 and q.max < q.min
        return error(place(at, "invalid repetition '#{piece_of(pat, at, q.stop)}'"))
      elsif q.min > MAX_COUNT or q.max > MAX_COUNT
        return error(place(at, "repetition count over #{MAX_COUNT} in '#{piece_of(pat, at, q.stop)}'"))
      end
      greedy = ch(pat, q.stop) != "?"
      stop = q.stop
      if !greedy
        stop += 1
      end
      if quantifier(pat, stop).some?
        return error(place(stop, "nested repetition '#{piece_of(pat, at, stop + 1)}'"))
      end
      return ok(Out(node: Node.Rep(atom.node, q.min, q.max, greedy), st: atom.st.with(pos: stop)))
  end
end

# A repetition operator at `pos`. A `{` that starts no valid `{n}`, `{n,}` or `{n,m}` is not one: it is a literal.
def quantifier(pat: Pat, pos: Int) -> Optional[Quant]
  c = ch(pat, pos)
  if c == "*"
    return some(Quant(min: 0, max: -1, stop: pos + 1))
  elsif c == "+"
    return some(Quant(min: 1, max: -1, stop: pos + 1))
  elsif c == "?"
    return some(Quant(min: 0, max: 1, stop: pos + 1))
  elsif c != "{"
    return none
  end
  low = digits(pat, pos + 1)
  if low.stop == pos + 1
    return none
  end
  high = low.value
  p = low.stop
  if ch(pat, p) == ","
    more = digits(pat, p + 1)
    high = -1
    if more.stop > p + 1
      high = more.value
    end
    p = more.stop
  end
  if ch(pat, p) != "}"
    return none
  end
  return some(Quant(min: low.value, max: high, stop: p + 1))
end

# A decimal number; its value stops growing past MAX_COUNT, so a long run of digits cannot overflow.
def digits(pat: Pat, pos: Int) -> Num
  value = 0
  p = pos
  while p < pat.n and pat.codes[p] >= 48 and pat.codes[p] <= 57
    if value <= MAX_COUNT
      value = value * 10 + pat.codes[p] - 48
    end
    p += 1
  end
  return Num(value: value, stop: p)
end

def parse_atom(pat: Pat, st: St, depth: Int) -> Result[Out]
  pos = st.pos
  c = ch(pat, pos)
  after = st.with(pos: pos + 1)
  if c == "("
    return parse_group(pat, st, depth)
  elsif c == "["
    return parse_class(pat, st)
  elsif c == "\\"
    e = try escape_at(pat, pos, false)
    node = Node.Class(e.ranges)
    if e.kind >= 0
      node = Node.Assert(e.kind)
    elsif e.code >= 0
      node = literal(e.code, st.flags.fold)
    end
    return ok(Out(node: node, st: st.with(pos: e.stop)))
  elsif c == "."
    return ok(Out(node: Node.Any(st.flags.dotall), st: after))
  elsif c == "^"
    kind = BEGIN_TEXT
    if st.flags.multi
      kind = BEGIN_LINE
    end
    return ok(Out(node: Node.Assert(kind), st: after))
  elsif c == "$"
    kind = END_TEXT
    if st.flags.multi
      kind = END_LINE
    end
    return ok(Out(node: Node.Assert(kind), st: after))
  end
  return ok(Out(node: literal(pat.codes[pos], st.flags.fold), st: after))
end

def literal(code: Int, fold: Bool) -> Node
  if fold and ((code >= 65 and code <= 90) or (code >= 97 and code <= 122))
    return Node.Class(fold_ranges([code, code]))
  end
  return Node.Lit(code)
end

def parse_group(pat: Pat, st: St, depth: Int) -> Result[Out]
  open = st.pos
  if depth >= MAX_DEPTH
    return error(place(open, "groups nest more than #{MAX_DEPTH} levels"))
  end
  p = open + 1
  capture = true
  name = ""
  inner = st.flags
  if ch(pat, p) == "?"
    c = ch(pat, p + 1)
    c2 = ch(pat, p + 2)
    if c == ":"
      capture = false
      p += 2
    elsif (c == "P" and c2 == "=") or (c == "P" and c2 == ">")
      return error(place(open, "backreferences are not supported"))
    elsif c == "=" or c == "!" or (c == "<" and (c2 == "=" or c2 == "!"))
      return error(place(open, "lookaround is not supported"))
    elsif c == ">"
      return error(place(open, "atomic groups are not supported"))
    elsif c == "<" or (c == "P" and c2 == "<")
      first = p + 2
      if c == "P"
        first = p + 3
      end
      close = first
      while close < pat.n and pat.chars[close] != ">"
        close += 1
      end
      name = piece_of(pat, first, close)
      if close >= pat.n or !group_name?(name)
        return error(place(open, "invalid group name '#{name}'"))
      elsif st.names.key?(name)
        return error(place(open, "duplicate group name \"#{name}\""))
      end
      p = close + 1
    else
      scan = try parse_flags(pat, p + 1, st.flags, open)
      if !scan.scoped
        return ok(Out(node: Node.Empty, st: st.with(pos: scan.stop, flags: scan.flags), bare: true))
      end
      capture = false
      inner = scan.flags
      p = scan.stop
    end
  end
  index = st.groups
  names = st.names
  if capture
    index += 1
    if index > MAX_GROUPS
      return error(place(open, "more than #{MAX_GROUPS} groups"))
    end
    if name != ""
      names = names.put(name, index)
    end
  end
  out = try parse_alt(pat, St(pos: p, flags: inner, groups: index, names: names), depth + 1)
  close_at = out.st.pos
  if ch(pat, close_at) != ")"
    return error(place(close_at, "missing ')' for the group at character #{open + 1}"))
  end
  node = out.node
  if capture
    node = Node.Group(out.node, index)
  end
  # Flags set inside a group end with it.
  return ok(Out(node: node, st: out.st.with(pos: close_at + 1, flags: st.flags)))
end

def group_name?(name: String) -> Bool
  codes = name.split("").map do |c| c.code end
  if codes.size == 0 or (codes[0] >= 48 and codes[0] <= 57)
    return false
  end
  return codes.all? do |c| c < 128 and WORD_ASCII[c] end
end

# `(?flags)` or `(?flags:`, from the first flag letter: i, m and s, and after one `-` the flags to turn off.
def parse_flags(pat: Pat, pos: Int, flags: Flags, open: Int) -> Result[FlagScan]
  out = flags
  on = true
  letters = 0
  p = pos
  while true
    c = ch(pat, p)
    if c == "i"
      out = out.with(fold: on)
    elsif c == "m"
      out = out.with(multi: on)
    elsif c == "s"
      out = out.with(dotall: on)
    elsif c == "-" and on
      on = false
      letters = 0
      p += 1
      next
    elsif (c == ")" or c == ":") and letters > 0
      return ok(FlagScan(flags: out, stop: p + 1, scoped: c == ":"))
    elsif c == ""
      return error(place(pat.n, "missing ')' for the group at character #{open + 1}"))
    elsif c == ")" or c == ":"
      return error(place(p, "missing flag after '(?' or '-'"))
    else
      return error(place(p, "unknown flag '#{c}'"))
    end
    letters += 1
    p += 1
  end
  return error(place(p, "unknown flag"))
end

def parse_class(pat: Pat, st: St) -> Result[Out]
  open = st.pos
  p = open + 1
  negate = ch(pat, p) == "^"
  if negate
    p += 1
  end
  ranges: List[Int] = []
  first = true
  while true
    c = ch(pat, p)
    if c == ""
      return error(place(pat.n, "missing ']' for the class at character #{open + 1}"))
    elsif c == "]" and !first
      break
    elsif c == "[" and ch(pat, p + 1) == ":" and closes_posix?(pat, p + 2)
      return error(place(p, "POSIX classes such as [:alpha:] are not supported"))
    end
    first = false
    low = try class_item(pat, p)
    p = low.stop
    dash = ch(pat, p) == "-" and ch(pat, p + 1) != "]" and ch(pat, p + 1) != ""
    if low.code < 0 and dash
      return error(place(p, "invalid class range: a class such as \\d cannot end a range"))
    elsif low.code < 0
      ranges = ranges.concat(low.ranges)
    elsif dash
      high = try class_item(pat, p + 1)
      if high.code < low.code
        return error(place(p - 1, "invalid class range '#{piece_of(pat, low.stop - 1, high.stop)}'"))
      end
      ranges = ranges.concat([low.code, high.code])
      p = high.stop
    else
      ranges = ranges.concat([low.code, low.code])
    end
  end
  set = normalize(ranges)
  if st.flags.fold
    set = fold_ranges(set)
  end
  if negate
    set = complement(set)
  end
  return ok(Out(node: Node.Class(set), st: st.with(pos: p + 1)))
end

# Whether a `:]` follows in the class, so that `[:` starts a POSIX class such as `[:alpha:]` (as Go reads it).
def closes_posix?(pat: Pat, pos: Int) -> Bool
  p = pos
  while p + 1 < pat.n and pat.chars[p] != "]"
    if pat.chars[p] == ":" and pat.chars[p + 1] == "]"
      return true
    end
    p += 1
  end
  return false
end

# One item of a class: a code point, or a class escape such as `\d` (code -1).
def class_item(pat: Pat, pos: Int) -> Result[Esc]
  if ch(pat, pos) == "\\"
    return escape_at(pat, pos, true)
  end
  return ok(Esc(kind: -1, code: pat.codes[pos], ranges: [], stop: pos + 1))
end

def escape_at(pat: Pat, pos: Int, in_class: Bool) -> Result[Esc]
  e = ch(pat, pos + 1)
  stop = pos + 2
  code = -1
  if e == ""
    return error(place(pos, "trailing backslash"))
  elsif e == "d" or e == "D" or e == "w" or e == "W" or e == "s" or e == "S"
    ranges = DIGIT_RANGES
    if e == "w" or e == "W"
      ranges = WORD_RANGES
    elsif e == "s" or e == "S"
      ranges = SPACE_RANGES
    end
    if e == "D" or e == "W" or e == "S"
      ranges = complement(ranges)
    end
    return ok(Esc(kind: -1, code: -1, ranges: ranges, stop: stop))
  elsif !in_class and (e == "A" or e == "z" or e == "b" or e == "B")
    kind = BEGIN_TEXT
    if e == "z"
      kind = END_TEXT
    elsif e == "b"
      kind = WORD_EDGE
    elsif e == "B"
      kind = NOT_WORD_EDGE
    end
    return ok(Esc(kind: kind, code: -1, ranges: [], stop: stop))
  elsif e == "n"
    code = 10
  elsif e == "r"
    code = 13
  elsif e == "t"
    code = 9
  elsif e == "f"
    code = 12
  elsif e == "v"
    code = 11
  elsif e == "x"
    return hex_escape(pat, pos)
  elsif (digit?(e) and e != "0") or (e == "k" and ch(pat, pos + 2) == "<")
    return error(place(pos, "backreferences are not supported"))
  elsif e == "p" or e == "P"
    return error(place(pos, "\\#{e} is not supported yet"))
  elsif e == "Q" or e == "E"
    return error(place(pos, "\\Q...\\E is not supported"))
  elsif punctuation?(pat.codes[pos + 1])
    code = pat.codes[pos + 1]
  else
    return error(place(pos, "invalid escape \\#{e}"))
  end
  return ok(Esc(kind: -1, code: code, ranges: [], stop: stop))
end

def digit?(c: String) -> Bool
  return c != "" and c.code >= 48 and c.code <= 57
end

def punctuation?(c: Int) -> Bool
  return (c >= 33 and c <= 47) or (c >= 58 and c <= 64) or (c >= 91 and c <= 96) or (c >= 123 and c <= 126)
end

# `\xHH` (two hex digits) or `\x{H...}` (a Unicode scalar value).
def hex_escape(pat: Pat, pos: Int) -> Result[Esc]
  braced = ch(pat, pos + 2) == "{"
  first = pos + 2
  if braced
    first = pos + 3
  end
  value = 0
  p = first
  while p < pat.n and HEX_DIGITS.index_of(pat.chars[p].downcase).some? and (braced or p < first + 2)
    if value <= MAX_CODE
      value = value * 16 + HEX_DIGITS.index_of(pat.chars[p].downcase).unwrap_or(0)
    end
    p += 1
  end
  count = p - first
  if braced
    if count == 0 or ch(pat, p) != "}"
      return error(place(pos, "invalid escape \\x: write \\xHH or \\x{H...}"))
    end
    if value > MAX_CODE or (value >= 0xD800 and value <= 0xDFFF)
      return error(place(pos, "#{piece_of(pat, pos, p + 1)} is not a Unicode scalar value"))
    end
    return ok(Esc(kind: -1, code: value, ranges: [], stop: p + 1))
  end
  if count != 2
    return error(place(pos, "invalid escape \\x: write \\xHH or \\x{H...}"))
  end
  return ok(Esc(kind: -1, code: value, ranges: [], stop: p))
end

# Sorts [low, high] pairs and joins the ones that overlap or touch.
def normalize(ranges: List[Int]) -> List[Int]
  pairs = (0...(ranges.size / 2)).to_a.map do |i| [ranges[2 * i], ranges[2 * i + 1]] end
  sorted = pairs.sort_by do |pair| pair[0] end
  out: List[Int] = []
  for pair in sorted
    if out.size > 0 and pair[0] <= out.last + 1
      if pair[1] > out.last
        out = out.set(out.size - 1, pair[1])
      end
    else
      out = out.concat(pair)
    end
  end
  return out
end

# Adds the other ASCII case of every letter in the ranges.
def fold_ranges(ranges: List[Int]) -> List[Int]
  out = ranges
  i = 0
  while i < ranges.size
    low = ranges[i]
    high = ranges[i + 1]
    if low <= 90 and high >= 65
      out = out.concat([max_of(low, 65) + 32, min_of(high, 90) + 32])
    end
    if low <= 122 and high >= 97
      out = out.concat([max_of(low, 97) - 32, min_of(high, 122) - 32])
    end
    i += 2
  end
  return normalize(out)
end

def complement(ranges: List[Int]) -> List[Int]
  out: List[Int] = []
  next_low = 0
  i = 0
  while i < ranges.size
    if ranges[i] > next_low
      out = out.concat([next_low, ranges[i] - 1])
    end
    next_low = ranges[i + 1] + 1
    i += 2
  end
  if next_low <= MAX_CODE
    out = out.concat([next_low, MAX_CODE])
  end
  return out
end

def max_of(a: Int, b: Int) -> Int
  if a > b
    return a
  end
  return b
end

def min_of(a: Int, b: Int) -> Int
  if a < b
    return a
  end
  return b
end

# The number of instructions `emit_node` writes, at most MAX_INSTS + 1, so a nested repetition cannot overflow.
def size_of(node: Node) -> Int
  total = 0
  case node
    Node.Empty -> total = 0
    Node.Lit(_) -> total = 1
    Node.Class(_) -> total = 1
    Node.Any(_) -> total = 1
    Node.Assert(_) -> total = 1
    Node.Cat(items) ->
      for item in items
        total = min_of(total + size_of(item), MAX_INSTS + 1)
      end
    Node.Alt(branches) ->
      total = 2 * (branches.size - 1)
      for branch in branches
        total = min_of(total + size_of(branch), MAX_INSTS + 1)
      end
    Node.Rep(body, low, high, _) ->
      s = size_of(body)
      if high == -1 and low == 0
        total = s + 2
      elsif high == -1
        total = low * s + 1
      else
        total = low * s + (high - low) * (s + 1)
      end
    Node.Group(body, _) -> total = size_of(body) + 2
  end
  return min_of(total, MAX_INSTS + 1)
end

def build(node: Node, groups: Int, names: Map[String, Int]) -> Program
  code = emit(Code(ops: [], xs: [], ys: [], classes: []), OP_SAVE, 0, 0)
  code = emit(emit_node(code, node), OP_SAVE, 1, 0)
  code = emit(code, OP_MATCH, 0, 0)
  return Program(
    ops: code.ops,
    xs: code.xs,
    ys: code.ys,
    classes: code.classes,
    ncap: 2 * (groups + 1),
    names: names,
    seal: Set.new([]),
  )
end

def emit(code: Code, op: Int, x: Int, y: Int) -> Code
  return code.with(ops: code.ops.push(op), xs: code.xs.push(x), ys: code.ys.push(y))
end

def emit_node(code: Code, node: Node) -> Code
  case node
    Node.Empty -> return code
    Node.Lit(c) -> return emit(code, OP_CHAR, c, 0)
    Node.Class(ranges) ->
      if ranges.size == 2 and ranges[0] == ranges[1]
        return emit(code, OP_CHAR, ranges[0], 0)
      end
      return emit(code.with(classes: code.classes.push(ranges)), OP_CLASS, code.classes.size, 0)
    Node.Any(all) ->
      if all
        return emit(code, OP_ANY_NL, 0, 0)
      end
      return emit(code, OP_ANY, 0, 0)
    Node.Assert(kind) -> return emit(code, OP_ASSERT, kind, 0)
    Node.Cat(items) ->
      out = code
      for item in items
        out = emit_node(out, item)
      end
      return out
    Node.Alt(branches) -> return emit_alt(code, branches)
    Node.Rep(body, low, high, greedy) -> return emit_rep(code, body, low, high, greedy)
    Node.Group(body, index) ->
      return emit(emit_node(emit(code, OP_SAVE, 2 * index, 0), body), OP_SAVE, 2 * index + 1, 0)
  end
end

# b1|b2|b3 is: SPLIT to b1 or the next SPLIT, b1, JUMP to the end; ...; the last branch.
def emit_alt(code: Code, branches: List[Node]) -> Code
  out = code
  jumps: List[Int] = []
  for branch in branches.take(branches.size - 1)
    split = out.ops.size
    out = emit_node(emit(out, OP_SPLIT, split + 1, 0), branch)
    jumps = jumps.push(out.ops.size)
    out = emit(out, OP_JUMP, 0, 0)
    out = out.with(ys: out.ys.set(split, out.ops.size))
  end
  out = emit_node(out, branches.last)
  end_pc = out.ops.size
  for jump in jumps
    out = out.with(xs: out.xs.set(jump, end_pc))
  end
  return out
end

# x{n,m} is n copies of x, then m - n optional copies, each reached only after the one before it matched. x* is
# (x+)? when x can match the empty text, as Go compiles it, so that an empty iteration ends the loop instead of
# being cut by the marks of the Pike VM (golang.org/issue/46123).
def emit_rep(code: Code, body: Node, low: Int, high: Int, greedy: Bool) -> Code
  out = code
  if high == -1 and low == 0 and nullable?(body)
    quest = out.ops.size
    out = emit_rep(emit(out, OP_SPLIT, 0, 0), body, 1, -1, greedy)
    return set_split(out, quest, quest + 1, out.ops.size, greedy)
  elsif high == -1 and low == 0
    loop = out.ops.size
    out = emit_node(emit(out, OP_SPLIT, 0, 0), body)
    out = emit(out, OP_JUMP, loop, 0)
    return set_split(out, loop, loop + 1, out.ops.size, greedy)
  end
  copies = low
  if high == -1
    copies = low - 1
  end
  for _ in 0...copies
    out = emit_node(out, body)
  end
  if high == -1
    again = out.ops.size
    out = emit_node(out, body)
    split = out.ops.size
    out = emit(out, OP_SPLIT, 0, 0)
    return set_split(out, split, again, split + 1, greedy)
  end
  splits: List[Int] = []
  for _ in 0...(high - low)
    splits = splits.push(out.ops.size)
    out = emit_node(emit(out, OP_SPLIT, 0, 0), body)
  end
  end_pc = out.ops.size
  for split in splits
    out = set_split(out, split, split + 1, end_pc, greedy)
  end
  return out
end

def nullable?(node: Node) -> Bool
  case node
    Node.Empty -> return true
    Node.Lit(_) -> return false
    Node.Class(_) -> return false
    Node.Any(_) -> return false
    Node.Assert(_) -> return true
    Node.Cat(items) -> return items.all?(&nullable?)
    Node.Alt(branches) -> return branches.any?(&nullable?)
    Node.Rep(body, low, _, _) -> return low == 0 or nullable?(body)
    Node.Group(body, _) -> return nullable?(body)
  end
end

# A greedy SPLIT prefers `body`; a lazy one prefers `exit`.
def set_split(code: Code, at: Int, body: Int, exit: Int, greedy: Bool) -> Code
  if greedy
    return code.with(xs: code.xs.set(at, body), ys: code.ys.set(at, exit))
  end
  return code.with(xs: code.xs.set(at, exit), ys: code.ys.set(at, body))
end

# A search with the compiled program: see MODE_TEST, MODE_FIRST and MODE_ALL. Each match gives `ncap` positions, two
# per group, -1 for a group that did not take part.
def run(text: String, prog: Program, mode: Int) -> List[Int]
  return RegexEngine.search(text, prog.ops, prog.xs, prog.ys, prog.classes, prog.ncap, mode)
end

# The match whose positions start at caps[at].
def make_match(text: String, caps: List[Int], at: Int, prog: Program) -> Match
  groups: List[Group] = []
  slot = at
  while slot < at + prog.ncap
    groups = groups.push(make_group(text, caps[slot], caps[slot + 1]))
    slot += 2
  end
  return Match(text: groups[0].text, start: groups[0].start, stop: groups[0].stop, groups: groups, names: prog.names)
end

def make_group(text: String, start: Int, stop: Int) -> Group
  if start < 0 or stop < start
    return Group(text: "", start: -1, stop: -1, matched: false)
  end
  return Group(text: slice(text, start, stop), start: start, stop: stop, matched: true)
end

def slice(text: String, from: Int, to: Int) -> String
  if to <= from
    return ""
  end
  return String.slice(text, from, to - from)
end

def escape_char(c: String) -> String
  if SPECIAL.include?(c)
    return "\\#{c}"
  end
  return c
end

# The pieces of a replacement template, checked against the groups of the pattern.
def parse_template(template: String, prog: Program) -> Result[List[Piece]]
  chars = template.split("")
  n = chars.size
  groups = prog.ncap / 2 - 1
  pieces: List[Piece] = []
  text: List[String] = []
  i = 0
  while i < n
    c = chars[i]
    d = ""
    if i + 1 < n
      d = chars[i + 1]
    end
    if c != "$"
      text = text.push(c)
      i += 1
    elsif d == "$"
      text = text.push("$")
      i += 2
    else
      ref = -1
      stop = i + 1
      label = ""
      if digit?(d)
        while stop < n and digit?(chars[stop])
          stop += 1
        end
        label = chars.drop(i + 1).take(stop - i - 1).join("")
        ref = group_number(label)
      elsif d == "{"
        close = i + 2
        while close < n and chars[close] != "}"
          close += 1
        end
        inner = chars.drop(i + 2).take(close - i - 2)
        if close >= n or inner.size == 0
          return error("template character #{i + 1}: '${' needs a group number or name and a '}'")
        end
        stop = close + 1
        label = inner.join("")
        if inner.all?(&digit?)
          ref = group_number(label)
        else
          case prog.names.get(label)
            some(index) -> ref = index
            none -> return error("no group named \"#{label}\"")
          end
        end
      else
        return error("template character #{i + 1}: '$' starts no group; write $$ for a dollar sign")
      end
      if ref > groups
        return error("no group #{label}")
      end
      if text.size > 0
        pieces = pieces.push(Piece.Text(text.join("")))
        text = []
      end
      pieces = pieces.push(Piece.Ref(ref))
      i = stop
    end
  end
  if text.size > 0
    pieces = pieces.push(Piece.Text(text.join("")))
  end
  return ok(pieces)
end

# A group number from its digits; it stops growing past MAX_GROUPS, which is already no group.
def group_number(digits_text: String) -> Int
  value = 0
  for d in digits_text.split("")
    if value <= MAX_GROUPS
      value = value * 10 + d.code - 48
    end
  end
  return value
end
