import "diagnostic" as Diag
import "source" as Source
import "token" as Tokens
import "unicode" as Unicode

struct Frame
  kind: String
  start: Source.Position
end

struct StringPiece
  kind: String
  value: String
  token_end: Int
  next: Int
  opens: Bool
end

struct DocScan
  stop: Int
  line: Int
  line_start: Int
  text: String
  next: String
end

# The kinds of character that start a token; the lexer dispatches on them.
enum CharClass
  Blank
  Newline
  Hash
  NameStart
  Digit
  Quote
  Opening
  Closing
  Other
end

# What never changes while one text is lexed: the text, its character codes and
# the lookup tables. Sets and Maps answer in one builtin call, where a chain of
# `letter?`/`digit?` calls costs several function calls per character.
struct Input
  text: String
  codes: List[Int]
  size: Int
  keywords: Set[String]
  block_openers: Set[String]
  operators: Map[String, String]
  classes: Map[Int, CharClass]
  name_codes: Set[Int]
  number_codes: Set[Int]
  line_ends: Set[Int]
  string_stops: Set[Int]
end

# Where the scan is. Each `scan_*` function returns the next `step` with an
# updated copy (`state.with(...)`); the old state is never changed. The hot
# paths call `Source.position` and `state.with` in place instead of through a
# helper: one more call per token made the lexer about 3% slower.
struct State
  index: Int
  line: Int
  line_start: Int
  tokens: List[Tokens.Token]
  delimiters: List[Frame]
  open_strings: Int
end

# One string literal in progress: where it began, whether it is the first
# piece (no `}` before it), the start of the text not yet copied, and the
# pieces already decoded (escapes split the copy).
struct StringScan
  start: Source.Position
  first: Bool
  segment: Int
  parts: List[String]
end

## Lexes a source text into its tokens, or the first `LEX-` diagnostic.
export def lex(text: String) -> Diag.Outcome[List[Tokens.Token]]
  codes = text.split("").map do |character| String.code(character) end
  input = new_input(text, codes)
  return step(input, State(index: 0, line: 1, line_start: 0, tokens: [], delimiters: [], open_strings: 0))
end

def new_input(text: String, codes: List[Int]) -> Input
  letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
  return Input(
    text: text,
    codes: codes,
    size: codes.size,
    keywords: keyword_table(),
    block_openers: Set.new(["def", "struct", "enum", "if", "while", "for", "do"]),
    operators: operator_table(),
    classes: char_classes(),
    name_codes: code_set(letters + "0123456789_"),
    number_codes: code_set("0123456789_"),
    line_ends: code_set("\n\r"),
    string_stops: code_set("\"#\\\n\r")
  )
end

# The main loop. Every hop is a direct `return f(...)`, so the VM replaces the
# frame (a tail call) and the depth stays flat on any input size.
def step(input: Input, state: State) -> Diag.Outcome[List[Tokens.Token]]
  if state.index == input.size
    return finish(input, state)
  end
  code = input.codes[state.index]
  case input.classes.get(code, CharClass.Other)
    CharClass.Blank -> return step(input, state.with(index: skip_blanks(input.codes, input.size, state.index)))
    CharClass.Newline -> return scan_newline(input, state, code)
    CharClass.Hash -> return scan_hash(input, state)
    CharClass.NameStart -> return scan_name(input, state, code)
    CharClass.Digit -> return scan_number(input, state)
    CharClass.Quote -> return scan_string_token(input, state, code)
    CharClass.Opening -> return scan_opening(input, state)
    CharClass.Closing -> return scan_closing(input, state, code)
    CharClass.Other -> return scan_operator(input, state, code)
  end
end

# The end of the text: a last NL at statement level, then EOF, unless a
# delimiter is still open.
def finish(input: Input, state: State) -> Diag.Outcome[List[Tokens.Token]]
  here = Source.position(state.index, state.line, state.line_start)
  tokens = state.tokens
  if statement_level?(state.delimiters) and !ends_with_newline?(tokens)
    tokens = tokens.push(token(input.text, "NL", Tokens.Value.NoValue, here, here))
  end
  opening = innermost(state.delimiters, false)
  if opening >= 0
    return Diag.Outcome.Failed(unclosed(state.delimiters[opening], here))
  end
  return Diag.Outcome.Done(tokens.push(token(input.text, "EOF", Tokens.Value.NoValue, here, here)))
end

def unclosed(frame: Frame, here: Source.Position) -> Diag.Diagnostic
  if frame.kind == "#"
    return unterminated(frame.start, here)
  end
  help = Diag.Help.NoHelp
  if frame.kind == "{"
    help = Diag.Help.Hint("add the missing \"}\" of a map literal; if \"{\" was meant to open a block, remove it: blocks have no braces and end with \"end\"")
  end
  return Diag.fail("LEX-UNCLOSED-DELIMITER", "unclosed " + frame.kind + " delimiter", span(frame.start, here), help)
end

# A NL token is only made at statement level; inside brackets a line break is
# blank space. A CR must come with its LF.
def scan_newline(input: Input, state: State, code: Int) -> Diag.Outcome[List[Tokens.Token]]
  start = Source.position(state.index, state.line, state.line_start)
  if code == 13 and at(input.codes, input.size, state.index + 1) != 10
    return Diag.Outcome.Failed(Diag.fail("LEX-UNEXPECTED-CHAR", "unexpected carriage return", span(start, start), Diag.Help.NoHelp))
  end
  if state.open_strings > 0
    return Diag.Outcome.Failed(unterminated(state.delimiters[innermost(state.delimiters, true)].start, start))
  end
  next = state.index + 1
  if code == 13
    next += 1
  end
  if statement_level?(state.delimiters)
    stop = Source.position(next, state.line + 1, next)
    tok = token(input.text, "NL", Tokens.Value.NoValue, start, stop)
    return step(input, state.with(index: next, line: state.line + 1, line_start: next, tokens: state.tokens.push(tok)))
  end
  return step(input, state.with(index: next, line: state.line + 1, line_start: next))
end

# `##` alone on its line starts a doc block; any other `#` is a comment.
def scan_hash(input: Input, state: State) -> Diag.Outcome[List[Tokens.Token]]
  codes = input.codes
  size = input.size
  if at(codes, size, state.index + 1) == 35 and only_blanks?(codes, state.line_start, state.index)
    return scan_doc_token(input, state)
  end
  return step(input, state.with(index: skip_until(codes, size, state.index, input.line_ends)))
end

def scan_doc_token(input: Input, state: State) -> Diag.Outcome[List[Tokens.Token]]
  start = Source.position(state.index, state.line, state.line_start)
  scan = scan_doc(input, state.index, state.line, state.line_start, [])
  block = Tokens.DocBlock(text: scan.text, next: scan.next)
  stop = Source.position(scan.stop, scan.line, scan.line_start)
  tok = token(input.text, "DOC", Tokens.Value.Doc(block), start, stop)
  return step(input, state.with(index: scan.stop, line: scan.line, line_start: scan.line_start, tokens: state.tokens.push(tok)))
end

def scan_name(input: Input, state: State, code: Int) -> Diag.Outcome[List[Tokens.Token]]
  codes = input.codes
  size = input.size
  first = state.index
  index = name_suffix(codes, size, code, skip_in(codes, size, first + 1, input.name_codes))
  lexeme = input.text.slice(first, index - first)
  kind = word_kind(input.keywords, lexeme, code)
  start = Source.position(first, state.line, state.line_start)
  delimiters = track_block(input.block_openers, state.delimiters, kind, start)
  tok = Tokens.Token(kind: kind, lexeme: lexeme, value: Tokens.Value.Text(lexeme), span: span(start, Source.position(index, state.line, state.line_start)))
  return step(input, state.with(index: index, tokens: state.tokens.push(tok), delimiters: delimiters))
end

# A name may end in `?` or `!`, except `!=` is the operator, and a type name
# (upper-case first letter) never takes the suffix.
def name_suffix(codes: List[Int], size: Int, first_code: Int, index: Int) -> Int
  if first_code >= 65 and first_code <= 90
    return index
  end
  mark = at(codes, size, index)
  if mark == 63 or (mark == 33 and at(codes, size, index + 1) != 61)
    return index + 1
  end
  return index
end

# A keyword's token kind is its own text, so the table only answers membership.
def word_kind(keywords: Set[String], lexeme: String, first_code: Int) -> String
  if keywords.include?(lexeme)
    return lexeme
  end
  if first_code >= 65 and first_code <= 90
    return "type-name"
  end
  return "name"
end

# Keywords that open a block push a "kw" frame and `end` pops it, so a NL
# still counts as a statement break there but not inside brackets.
def track_block(openers: Set[String], delimiters: List[Frame], kind: String, start: Source.Position) -> List[Frame]
  if openers.include?(kind)
    return delimiters.push(Frame(kind: "kw", start: start))
  elsif kind == "end" and delimiters.size > 0 and delimiters[delimiters.size - 1].kind == "kw"
    return pop(delimiters)
  end
  return delimiters
end

def scan_number(input: Input, state: State) -> Diag.Outcome[List[Tokens.Token]]
  codes = input.codes
  size = input.size
  first = state.index
  index = skip_in(codes, size, first, input.number_codes)
  is_float = at(codes, size, index) == 46 and input.number_codes.include?(at(codes, size, index + 1))
  if is_float
    index = skip_in(codes, size, index + 1, input.number_codes)
  end
  start = Source.position(first, state.line, state.line_start)
  stop = Source.position(index, state.line, state.line_start)
  if invalid_separator?(codes, first, index)
    return Diag.Outcome.Failed(Diag.fail("LEX-INVALID-NUMBER", "a \"_\" in a number must sit between two digits", span(start, stop), Diag.Help.Hint("write digit groups like 1_000 or 0.000_5; remove the extra \"_\"")))
  end
  digits = input.text.slice(first, index - first).replace("_", "")
  if is_float
    return step(input, state.with(index: index, tokens: state.tokens.push(token(input.text, "float", Tokens.Value.Real(digits.to_f!), start, stop))))
  end
  return step(input, state.with(index: index, tokens: state.tokens.push(token(input.text, "integer", integer_value(digits), start, stop))))
end

# A string piece starts at `"` or, after an interpolation, at its closing `}`.
def scan_string_token(input: Input, state: State, code: Int) -> Diag.Outcome[List[Tokens.Token]]
  start = Source.position(state.index, state.line, state.line_start)
  if code == 125
    frame = state.delimiters[state.delimiters.size - 1]
    inner = state.with(delimiters: pop(state.delimiters), open_strings: state.open_strings - 1)
    return string_piece(input, inner, StringScan(start: frame.start, first: false, segment: state.index + 1, parts: []), start)
  end
  return string_piece(input, state, StringScan(start: start, first: true, segment: state.index + 1, parts: []), start)
end

def string_piece(input: Input, state: State, scan: StringScan, start: Source.Position) -> Diag.Outcome[List[Tokens.Token]]
  case scan_string(input, state, scan, scan.segment)
    Diag.Outcome.Failed(problem) -> return Diag.Outcome.Failed(problem)
    Diag.Outcome.Done(piece) ->
      tok = token(input.text, piece.kind, Tokens.Value.Text(piece.value), start, Source.position(piece.token_end, state.line, state.line_start))
      if piece.opens
        frame = Frame(kind: "#", start: scan.start)
        return step(input, state.with(index: piece.next, tokens: state.tokens.push(tok), delimiters: state.delimiters.push(frame), open_strings: state.open_strings + 1))
      end
      return step(input, state.with(index: piece.next, tokens: state.tokens.push(tok)))
  end
end

def scan_operator(input: Input, state: State, code: Int) -> Diag.Outcome[List[Tokens.Token]]
  start = Source.position(state.index, state.line, state.line_start)
  lexeme = operator_lexeme(input, state.index, code)
  kind = input.operators.get(lexeme, "")
  if kind == ""
    return Diag.Outcome.Failed(unexpected_character(code, lexeme, start, Source.position(state.index + 1, state.line, state.line_start)))
  end
  stop = Source.position(state.index + lexeme.length, state.line, state.line_start)
  tok = Tokens.Token(kind: kind, lexeme: lexeme, value: Tokens.Value.Text(lexeme), span: span(start, stop))
  return step(input, state.with(index: stop.offset, tokens: state.tokens.push(tok)))
end

# `(`, `[` and `{` are always one character; each opens a frame that its
# closing character must match.
def scan_opening(input: Input, state: State) -> Diag.Outcome[List[Tokens.Token]]
  lexeme = input.text.slice(state.index, 1)
  start = Source.position(state.index, state.line, state.line_start)
  stop = Source.position(state.index + 1, state.line, state.line_start)
  tok = Tokens.Token(kind: input.operators.get(lexeme, ""), lexeme: lexeme, value: Tokens.Value.Text(lexeme), span: span(start, stop))
  return step(input, state.with(index: stop.offset, tokens: state.tokens.push(tok), delimiters: state.delimiters.push(Frame(kind: lexeme, start: start))))
end

# `}` also ends an interpolation, which is a string piece, not a delimiter.
def scan_closing(input: Input, state: State, code: Int) -> Diag.Outcome[List[Tokens.Token]]
  delimiters = state.delimiters
  if code == 125 and in_interpolation?(delimiters)
    return scan_string_token(input, state, code)
  end
  lexeme = input.text.slice(state.index, 1)
  start = Source.position(state.index, state.line, state.line_start)
  stop = Source.position(state.index + 1, state.line, state.line_start)
  if delimiters.size == 0 or delimiters[delimiters.size - 1].kind != expected_opener(code)
    help = Diag.Help.NoHelp
    if code == 125 and statement_level?(delimiters)
      help = Diag.Help.Hint("blocks end with \"end\", not \"}\"")
    end
    return Diag.Outcome.Failed(Diag.fail("LEX-UNMATCHED-DELIMITER", "unmatched " + lexeme + " delimiter", span(start, stop), help))
  end
  tok = Tokens.Token(kind: input.operators.get(lexeme, ""), lexeme: lexeme, value: Tokens.Value.Text(lexeme), span: span(start, stop))
  return step(input, state.with(index: stop.offset, tokens: state.tokens.push(tok), delimiters: pop(delimiters)))
end

# The longest operator at `index`: `...`, then two characters, then one.
def operator_lexeme(input: Input, index: Int, code: Int) -> String
  if code == 46 and at(input.codes, input.size, index + 1) == 46 and at(input.codes, input.size, index + 2) == 46
    return "..."
  end
  if index + 1 < input.size
    pair = input.text.slice(index, 2)
    if input.operators.has_key?(pair)
      return pair
    end
  end
  return input.text.slice(index, 1)
end

def ends_with_newline?(tokens: List[Tokens.Token]) -> Bool
  return tokens.size > 0 and tokens[tokens.size - 1].kind == "NL"
end

def in_interpolation?(delimiters: List[Frame]) -> Bool
  return delimiters.size > 0 and delimiters[delimiters.size - 1].kind == "#"
end

def code_set(characters: String) -> Set[Int]
  return Set.new(characters.split("").map do |character| String.code(character) end)
end

# The class of each ASCII code, from `classify`; a code past 127 is `Other`.
def char_classes() -> Map[Int, CharClass]
  classes: Map[Int, CharClass] = {}
  for code in 0..127
    classes = classes.put(code, classify(code))
  end
  return classes
end

def classify(code: Int) -> CharClass
  if blank?(code)
    return CharClass.Blank
  elsif newline?(code)
    return CharClass.Newline
  elsif code == 35
    return CharClass.Hash
  elsif letter?(code) or code == 95
    return CharClass.NameStart
  elsif digit?(code)
    return CharClass.Digit
  elsif code == 34
    return CharClass.Quote
  elsif code == 40 or code == 91 or code == 123
    return CharClass.Opening
  elsif code == 41 or code == 93 or code == 125
    return CharClass.Closing
  end
  return CharClass.Other
end

def keyword_table() -> Set[String]
  return Set.new([
    "import", "export", "def", "struct", "enum", "case", "do", "end", "if", "elsif", "else",
    "while", "for", "in", "return", "try", "true", "false", "nil", "and", "or", "not"
  ])
end

def operator_table() -> Map[String, String]
  return {
    "->": "arrow", "==": "equal", "!=": "not-equal", "<=": "less-equal", ">=": "greater-equal",
    "&&": "and", "||": "or", "!": "not", "+=": "plus-assign", "-=": "minus-assign",
    "*=": "multiply-assign", "/=": "divide-assign", "%=": "modulo-assign",
    "(": "left-paren", ")": "right-paren", "[": "left-bracket", "]": "right-bracket",
    "{": "left-brace", "}": "right-brace", ",": "comma", ":": "colon", ".": "dot",
    "..": "dot-dot", "...": "dot-dot-dot", "=": "assign", "+": "plus", "-": "minus",
    "*": "multiply", "/": "divide", "%": "modulo", "<": "less", ">": "greater",
    "&": "ampersand", "|": "pipe", "|>": "pipe-forward"
  }
end

def blank?(code: Int) -> Bool
  return code == 32 or code == 9
end

def newline?(code: Int) -> Bool
  return code == 10 or code == 13
end

def letter?(code: Int) -> Bool
  return (code >= 97 and code <= 122) or (code >= 65 and code <= 90)
end

def digit?(code: Int) -> Bool
  return code >= 48 and code <= 57
end

def at(codes: List[Int], size: Int, index: Int) -> Int
  if index < size
    return codes[index]
  end
  return -1
end

def skip_blanks(codes: List[Int], size: Int, from: Int) -> Int
  index = from
  while index < size and blank?(codes[index])
    index += 1
  end
  return index
end

# Index of the first code from `from` that is in `members` (or `size`). A
# while loop on purpose: the tail-recursive form measured 2-4% slower.
def skip_in(codes: List[Int], size: Int, from: Int, members: Set[Int]) -> Int
  index = from
  while index < size and members.include?(codes[index])
    index += 1
  end
  return index
end

# Index of the first code from `from` that is in `stops` (or `size`).
def skip_until(codes: List[Int], size: Int, from: Int, stops: Set[Int]) -> Int
  index = from
  while index < size and !stops.include?(codes[index])
    index += 1
  end
  return index
end

def only_blanks?(codes: List[Int], from: Int, stop: Int) -> Bool
  index = from
  while index < stop
    if !blank?(codes[index])
      return false
    end
    index += 1
  end
  return true
end

def doc_marker?(codes: List[Int], size: Int, index: Int) -> Bool
  return index + 1 < size and codes[index] == 35 and codes[index + 1] == 35
end

def next_line_start(codes: List[Int], size: Int, index: Int) -> Int
  if index >= size
    return -1
  end
  if codes[index] == 10
    return index + 1
  end
  if codes[index] == 13 and at(codes, size, index + 1) == 10
    return index + 2
  end
  return -1
end

def line_after_doc(codes: List[Int], size: Int, index: Int) -> String
  following = next_line_start(codes, size, index)
  if following < 0
    return "eof"
  end
  found = skip_blanks(codes, size, following)
  if found >= size
    return "eof"
  end
  if newline?(codes[found])
    return "blank"
  end
  if codes[found] == 35
    return "comment"
  end
  return "code"
end

# One `##` line per call; a following `##` line (after blanks) continues the
# block. `from` is the offset of the `##`.
def scan_doc(input: Input, from: Int, line: Int, line_start: Int, lines: List[String]) -> DocScan
  codes = input.codes
  size = input.size
  index = from + 2
  if index < size and codes[index] == 32
    index += 1
  end
  stop = skip_until(codes, size, index, input.line_ends)
  collected = lines.push(input.text.slice(index, stop - index))
  following = next_line_start(codes, size, stop)
  if following >= 0
    marker = skip_blanks(codes, size, following)
    if doc_marker?(codes, size, marker)
      return scan_doc(input, marker, line + 1, following, collected)
    end
  end
  return DocScan(stop: stop, line: line, line_start: line_start, text: collected.join("\n"), next: line_after_doc(codes, size, stop))
end

def span(start: Source.Position, stop: Source.Position) -> Source.Span
  return Source.Span(start: start, stop: stop)
end

def token(text: String, kind: String, value: Tokens.Value, start: Source.Position, stop: Source.Position) -> Tokens.Token
  return Tokens.Token(kind: kind, lexeme: text.slice(start.offset, stop.offset - start.offset), value: value, span: span(start, stop))
end

def unterminated(start: Source.Position, stop: Source.Position) -> Diag.Diagnostic
  return Diag.fail("LEX-UNTERMINATED-STRING", "unterminated string", span(start, stop), Diag.Help.NoHelp)
end

def decoded_escape(code: Int) -> String
  case code
    34 -> return "\""
    92 -> return "\\"
    35 -> return "#"
    110 -> return "\n"
    114 -> return "\r"
    116 -> return "\t"
    _ -> return ""
  end
end

# Scans from `from` to the end of one piece: the closing quote, or the `#{` of
# an interpolation. Plain characters are skipped in one run; only an escape,
# a `#` or the end of the piece needs a decision.
def scan_string(input: Input, state: State, scan: StringScan, from: Int) -> Diag.Outcome[StringPiece]
  codes = input.codes
  index = skip_until(codes, input.size, from, input.string_stops)
  if index == input.size or newline?(codes[index])
    return Diag.Outcome.Failed(unterminated(scan.start, Source.position(index, state.line, state.line_start)))
  end
  code = codes[index]
  if code == 34
    kind = "interp-end"
    if scan.first
      kind = "string"
    end
    value = scan.parts.push(input.text.slice(scan.segment, index - scan.segment)).join("")
    return Diag.Outcome.Done(StringPiece(kind: kind, value: value, token_end: index + 1, next: index + 1, opens: false))
  elsif code == 35
    if at(codes, input.size, index + 1) == 123
      kind = "interp-middle"
      if scan.first
        kind = "interp-start"
      end
      value = scan.parts.push(input.text.slice(scan.segment, index - scan.segment)).join("")
      return Diag.Outcome.Done(StringPiece(kind: kind, value: value, token_end: index, next: index + 2, opens: true))
    end
    return scan_string(input, state, scan, index + 1)
  end
  return scan_escape(input, state, scan, index)
end

# The `\` at `index`: copy the text before it, then the decoded character.
def scan_escape(input: Input, state: State, scan: StringScan, index: Int) -> Diag.Outcome[StringPiece]
  escape_start = Source.position(index, state.line, state.line_start)
  if index + 1 == input.size
    return Diag.Outcome.Failed(Diag.fail("LEX-INVALID-ESCAPE", "incomplete string escape", span(escape_start, Source.position(index + 1, state.line, state.line_start)), Diag.Help.NoHelp))
  end
  decoded = decoded_escape(input.codes[index + 1])
  if decoded == ""
    stop = Source.position(index + 2, state.line, state.line_start)
    if input.codes[index + 1] == 10
      stop = Source.Position(offset: index + 2, line: state.line + 1, column: 1)
    end
    return Diag.Outcome.Failed(Diag.fail("LEX-INVALID-ESCAPE", "unsupported escape \\" + input.text.slice(index + 1, 1), span(escape_start, stop), Diag.Help.NoHelp))
  end
  parts = scan.parts.push(input.text.slice(scan.segment, index - scan.segment)).push(decoded)
  return scan_string(input, state, scan.with(segment: index + 2, parts: parts), index + 2)
end

def invalid_separator?(codes: List[Int], from: Int, stop: Int) -> Bool
  index = from
  while index < stop
    code = codes[index]
    if code == 95
      following = at(codes, stop, index + 1)
      if following == -1 or following == 95 or following == 46
        return true
      end
    elsif code == 46 and at(codes, stop, index + 1) == 95
      return true
    end
    index += 1
  end
  return false
end

def strip_zeros(digits: String) -> String
  start = 0
  while start < digits.length - 1 and digits.slice(start, 1) == "0"
    start += 1
  end
  return digits.slice(start, digits.length - start)
end

def integer_value(digits: String) -> Tokens.Value
  parsed = digits.to_i
  if parsed.ok?
    return Tokens.Value.Whole(parsed.unwrap!)
  end
  return Tokens.Value.Huge(strip_zeros(digits))
end

def statement_level?(delimiters: List[Frame]) -> Bool
  return delimiters.size == 0 or delimiters[delimiters.size - 1].kind == "kw"
end

def innermost(delimiters: List[Frame], wanted_string: Bool) -> Int
  index = delimiters.size - 1
  while index >= 0
    interpolation = delimiters[index].kind == "#"
    if wanted_string
      if interpolation
        return index
      end
    elsif delimiters[index].kind != "kw"
      return index
    end
    index -= 1
  end
  return -1
end

def pop(delimiters: List[Frame]) -> List[Frame]
  return delimiters.take(delimiters.size - 1)
end

def unexpected_character(code: Int, character: String, start: Source.Position, stop: Source.Position) -> Diag.Diagnostic
  message = "unexpected character " + Unicode.written(code)
  if Unicode.graphic?(code)
    message = "unexpected character \"" + character + "\""
  end
  help = Diag.Help.NoHelp
  if code == 59
    help = Diag.Help.Hint("Agentica has no semicolons; end the statement with a newline")
  elsif code == 39 or code == 96
    help = Diag.Help.Hint("strings use double quotes: \"abc\"; there is no char type, a character is a one-character String such as \"+\"")
  end
  return Diag.fail("LEX-UNEXPECTED-CHAR", message, span(start, stop), help)
end

def expected_opener(closing_code: Int) -> String
  case closing_code
    41 -> return "("
    93 -> return "["
    _ -> return "{"
  end
end
