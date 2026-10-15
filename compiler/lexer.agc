import Diag from "diagnostic"
import Source from "source"
import Tokens from "token"
import Unicode from "unicode"

# An open bracket (`(`, `[`, `{`), an interpolation (`#`) or a block (`kw`), and
# where it opened.
struct Frame
  kind: String
  start: Source.Position
end

# One piece of a string literal: from the opening quote (or the `}` that ends
# an interpolation) to the closing quote or the next `#{`. `start` is where the
# whole literal began, for the "unterminated" span.
struct StringPiece
  kind: String
  value: String
  token_end: Int
  next: Int
  opens: Bool
  start: Source.Position
end

# A scanned `##` block: where it stops, the line state there, its text and what
# follows it.
struct DocScan
  stop: Int
  line: Int
  line_start: Int
  text: String
  next: String
end

# The kind of a character at the start of a token; `lex` dispatches on it.
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

## Lexes a source text into its tokens, or the first `LEX-` diagnostic.
export def lex(text: String) -> Diag.Outcome[List[Tokens.Token]]
  input = new_input(text)
  codes = input.codes
  size = input.size
  tokens: List[Tokens.Token] = []
  delimiters: List[Frame] = []
  index = 0
  line = 1
  line_start = 0
  while index < size
    code = codes[index]
    kind = input.classes.get(code, CharClass.Other)
    # A `}` that closes an interpolation continues the string, not a map.
    if code == 125 and in_interpolation?(delimiters)
      kind = CharClass.Quote
    end
    case kind
      CharClass.Blank -> index = skip_blanks(codes, size, index)
      CharClass.Newline ->
        start = Source.position(index, line, line_start)
        case after_newline(input, delimiters, index, code, start)
          Diag.Outcome.Failed(problem) -> return Diag.Outcome.Failed(problem)
          Diag.Outcome.Done(next) ->
            if statement_level?(delimiters)
              tokens = tokens.push(
                token(text, "NL", Tokens.Value.NoValue, start, Source.position(next, line + 1, next)),
              )
            end
            index = next
            line += 1
            line_start = next
        end
      CharClass.Hash ->
        if at(codes, size, index + 1) == 35 and only_blanks?(codes, line_start, index)
          scan = scan_doc(input, index, line, line_start)
          tokens = tokens.push(doc_token(input, scan, index, line, line_start))
          index = scan.stop
          line = scan.line
          line_start = scan.line_start
        else
          index = skip_until(codes, size, index, input.line_ends)
        end
      CharClass.NameStart ->
        word = scan_name(input, index, code, line, line_start)
        delimiters = track_block(input.block_openers, delimiters, word.kind, word.span.start)
        tokens = tokens.push(word)
        index = word.span.stop.offset
      CharClass.Digit ->
        case scan_number(input, index, line, line_start)
          Diag.Outcome.Failed(problem) -> return Diag.Outcome.Failed(problem)
          Diag.Outcome.Done(number) ->
            tokens = tokens.push(number)
            index = number.span.stop.offset
        end
      CharClass.Quote ->
        case scan_string(input, delimiters, index, code, line, line_start)
          Diag.Outcome.Failed(problem) -> return Diag.Outcome.Failed(problem)
          Diag.Outcome.Done(piece) ->
            if code == 125
              delimiters = pop(delimiters)
            end
            tokens = tokens.push(piece_token(input, piece, index, line, line_start))
            if piece.opens
              delimiters = delimiters.push(Frame(kind: "#", start: piece.start))
            end
            index = piece.next
        end
      CharClass.Opening ->
        opening = scan_opening(input, index, line, line_start)
        delimiters = delimiters.push(Frame(kind: opening.lexeme, start: opening.span.start))
        tokens = tokens.push(opening)
        index = opening.span.stop.offset
      CharClass.Closing ->
        case scan_closing(input, delimiters, index, code, line, line_start)
          Diag.Outcome.Failed(problem) -> return Diag.Outcome.Failed(problem)
          Diag.Outcome.Done(closing) ->
            delimiters = pop(delimiters)
            tokens = tokens.push(closing)
            index = closing.span.stop.offset
        end
      CharClass.Other ->
        case scan_operator(input, index, code, line, line_start)
          Diag.Outcome.Failed(problem) -> return Diag.Outcome.Failed(problem)
          Diag.Outcome.Done(operator) ->
            tokens = tokens.push(operator)
            index = operator.span.stop.offset
        end
    end
  end
  return finish(input, tokens, delimiters, Source.position(index, line, line_start))
end

# The text as character codes (positions count characters, as in Racket) with
# its lookup tables.
def new_input(text: String) -> Input
  codes = text.split("").map do |character| String.code(character) end
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

# The end of the text: a last NL at statement level, then EOF, unless a
# delimiter is still open.
def finish(
  input: Input,
  tokens: List[Tokens.Token],
  delimiters: List[Frame],
  here: Source.Position,
) -> Diag.Outcome[List[Tokens.Token]]
  closed = tokens
  if statement_level?(delimiters) and !ends_with_newline?(tokens)
    closed = closed.push(token(input.text, "NL", Tokens.Value.NoValue, here, here))
  end
  opening = innermost(delimiters, false)
  if opening >= 0
    return Diag.Outcome.Failed(unclosed(delimiters[opening], here))
  end
  return Diag.Outcome.Done(closed.push(token(input.text, "EOF", Tokens.Value.NoValue, here, here)))
end

# Checks the line break at `index` and returns the offset after it. A CR must
# come with its LF, and a line break cannot sit inside a string interpolation
# (any `#` frame on the stack: only string pieces push or pop them).
def after_newline(
  input: Input,
  delimiters: List[Frame],
  index: Int,
  code: Int,
  start: Source.Position,
) -> Diag.Outcome[Int]
  if code == 13 and at(input.codes, input.size, index + 1) != 10
    return Diag.Outcome.Failed(
      Diag.fail("LEX-UNEXPECTED-CHAR", "unexpected carriage return", span(start, start), Diag.Help.NoHelp),
    )
  end
  inside = innermost(delimiters, true)
  if inside >= 0
    return Diag.Outcome.Failed(unterminated(delimiters[inside].start, start))
  end
  if code == 13
    return Diag.Outcome.Done(index + 2)
  end
  return Diag.Outcome.Done(index + 1)
end

# The DOC token of a scanned `##` block; its span ends where the block ends.
def doc_token(input: Input, scan: DocScan, first: Int, line: Int, line_start: Int) -> Tokens.Token
  block = Tokens.DocBlock(text: scan.text, next: scan.next)
  start = Source.position(first, line, line_start)
  stop = Source.position(scan.stop, scan.line, scan.line_start)
  return token(input.text, "DOC", Tokens.Value.Doc(block), start, stop)
end

# A name or keyword starting at `first`. A keyword's kind is its own text, a
# name's is "name" or "type-name".
def scan_name(input: Input, first: Int, code: Int, line: Int, line_start: Int) -> Tokens.Token
  index = name_suffix(input.codes, input.size, code, skip_in(input.codes, input.size, first + 1, input.name_codes))
  lexeme = input.text.slice(first, index - first)
  span = Source.Span(start: Source.position(first, line, line_start), stop: Source.position(index, line, line_start))
  return Tokens.Token(
    kind: word_kind(input.keywords, lexeme, code),
    lexeme: lexeme,
    value: Tokens.Value.Text(lexeme),
    span: span,
  )
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

# An integer or float starting at `first`. A `_` must sit between two digits.
def scan_number(input: Input, first: Int, line: Int, line_start: Int) -> Diag.Outcome[Tokens.Token]
  codes = input.codes
  size = input.size
  index = skip_in(codes, size, first, input.number_codes)
  is_float = at(codes, size, index) == 46 and input.number_codes.include?(at(codes, size, index + 1))
  if is_float
    index = skip_in(codes, size, index + 1, input.number_codes)
  end
  start = Source.position(first, line, line_start)
  stop = Source.position(index, line, line_start)
  if invalid_separator?(codes, first, index)
    return Diag.Outcome.Failed(
      Diag.fail(
        "LEX-INVALID-NUMBER",
        "a \"_\" in a number must sit between two digits",
        span(start, stop),
        Diag.Help.Hint("write digit groups like 1_000 or 0.000_5; remove the extra \"_\""),
      ),
    )
  end
  digits = input.text.slice(first, index - first).replace("_", "")
  if is_float
    return Diag.Outcome.Done(token(input.text, "float", Tokens.Value.Real(digits.to_f!), start, stop))
  end
  return Diag.Outcome.Done(token(input.text, "integer", integer_value(digits), start, stop))
end

# Scans one piece of a string literal. It starts after the opening `"`, or
# after the `}` that ends an interpolation (then the top frame is the `#`
# frame that holds the literal's start). The loop jumps from one special
# character to the next, so plain text costs one table lookup per character;
# only an escape, a `#` or the end of the piece needs a decision.
def scan_string(
  input: Input,
  delimiters: List[Frame],
  at_index: Int,
  code: Int,
  line: Int,
  line_start: Int,
) -> Diag.Outcome[StringPiece]
  codes = input.codes
  size = input.size
  first = code == 34
  string_start = Source.position(at_index, line, line_start)
  if !first
    string_start = delimiters[delimiters.size - 1].start
  end
  parts: List[String] = []
  index = at_index + 1
  segment = index
  while true
    index = skip_until(codes, size, index, input.string_stops)
    if index == size or newline?(codes[index])
      return Diag.Outcome.Failed(unterminated(string_start, Source.position(index, line, line_start)))
    end
    if codes[index] == 34
      kind = "interp-end"
      if first
        kind = "string"
      end
      value = parts.push(input.text.slice(segment, index - segment)).join("")
      return Diag.Outcome.Done(
        StringPiece(
          kind: kind,
          value: value,
          token_end: index + 1,
          next: index + 1,
          opens: false,
          start: string_start,
        ),
      )
    elsif codes[index] == 35 and at(codes, size, index + 1) == 123
      kind = "interp-middle"
      if first
        kind = "interp-start"
      end
      value = parts.push(input.text.slice(segment, index - segment)).join("")
      return Diag.Outcome.Done(
        StringPiece(kind: kind, value: value, token_end: index, next: index + 2, opens: true, start: string_start),
      )
    elsif codes[index] == 92
      decoded = ""
      if index + 1 < size
        decoded = decoded_escape(codes[index + 1])
      end
      if decoded == ""
        return Diag.Outcome.Failed(bad_escape(input, index, line, line_start))
      end
      parts = parts.push(input.text.slice(segment, index - segment)).push(decoded)
      index += 2
      segment = index
    else
      index += 1
    end
  end
  return Diag.Outcome.Failed(unterminated(string_start, Source.position(index, line, line_start)))
end

# The diagnostic for the `\` at `index`: it ends the text, or the next
# character is not an escape. An escaped line break ends on the next line.
def bad_escape(input: Input, index: Int, line: Int, line_start: Int) -> Diag.Diagnostic
  escape_start = Source.position(index, line, line_start)
  if index + 1 == input.size
    return Diag.fail(
      "LEX-INVALID-ESCAPE",
      "incomplete string escape",
      span(escape_start, Source.position(index + 1, line, line_start)),
      Diag.Help.NoHelp,
    )
  end
  stop = Source.position(index + 2, line, line_start)
  if input.codes[index + 1] == 10
    stop = Source.Position(offset: index + 2, line: line + 1, column: 1)
  end
  return Diag.fail(
    "LEX-INVALID-ESCAPE",
    "unsupported escape \\" + input.text.slice(index + 1, 1),
    span(escape_start, stop),
    Diag.Help.NoHelp,
  )
end

# The token of a string piece. A string cannot span lines, so the line is the
# one the piece started on.
def piece_token(input: Input, piece: StringPiece, first: Int, line: Int, line_start: Int) -> Tokens.Token
  start = Source.position(first, line, line_start)
  stop = Source.position(piece.token_end, line, line_start)
  return token(input.text, piece.kind, Tokens.Value.Text(piece.value), start, stop)
end

# An operator or punctuation token that is not a bracket; other characters
# are `LEX-UNEXPECTED-CHAR`.
def scan_operator(input: Input, index: Int, code: Int, line: Int, line_start: Int) -> Diag.Outcome[Tokens.Token]
  start = Source.position(index, line, line_start)
  lexeme = operator_lexeme(input, index, code)
  kind = input.operators.get(lexeme, "")
  if kind == ""
    return Diag.Outcome.Failed(unexpected_character(code, lexeme, start, Source.position(index + 1, line, line_start)))
  end
  stop = Source.position(index + lexeme.length, line, line_start)
  return Diag.Outcome.Done(
    Tokens.Token(kind: kind, lexeme: lexeme, value: Tokens.Value.Text(lexeme), span: span(start, stop)),
  )
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

# `(`, `[` and `{` are always one character; the caller opens a frame that the
# matching closing character must find on top.
def scan_opening(input: Input, index: Int, line: Int, line_start: Int) -> Tokens.Token
  lexeme = input.text.slice(index, 1)
  span = Source.Span(
    start: Source.position(index, line, line_start),
    stop: Source.position(index + 1, line, line_start),
  )
  return Tokens.Token(
    kind: input.operators.get(lexeme, ""),
    lexeme: lexeme,
    value: Tokens.Value.Text(lexeme),
    span: span,
  )
end

# `)`, `]` or `}` must close the frame on top; otherwise `LEX-UNMATCHED-DELIMITER`.
# (A `}` that ends an interpolation never gets here: it is a string piece.)
def scan_closing(
  input: Input,
  delimiters: List[Frame],
  index: Int,
  code: Int,
  line: Int,
  line_start: Int,
) -> Diag.Outcome[Tokens.Token]
  lexeme = input.text.slice(index, 1)
  start = Source.position(index, line, line_start)
  stop = Source.position(index + 1, line, line_start)
  if delimiters.size == 0 or delimiters[delimiters.size - 1].kind != expected_opener(code)
    help = Diag.Help.NoHelp
    if code == 125 and statement_level?(delimiters)
      help = Diag.Help.Hint("blocks end with \"end\", not \"}\"")
    end
    return Diag.Outcome.Failed(
      Diag.fail("LEX-UNMATCHED-DELIMITER", "unmatched " + lexeme + " delimiter", span(start, stop), help),
    )
  end
  return Diag.Outcome.Done(
    Tokens.Token(
      kind: input.operators.get(lexeme, ""),
      lexeme: lexeme,
      value: Tokens.Value.Text(lexeme),
      span: span(start, stop),
    ),
  )
end

# A `##` doc block starting at `from`: one line per `##`, and the block goes on
# while the next line (after blanks) starts with `##` again. `next` tells the
# parser what follows the block (blank line, comment, code or end of file).
def scan_doc(input: Input, from: Int, line: Int, line_start: Int) -> DocScan
  codes = input.codes
  size = input.size
  lines: List[String] = []
  index = from
  current_line = line
  current_start = line_start
  collecting = true
  while collecting
    index += 2
    if index < size and codes[index] == 32
      index += 1
    end
    text_start = index
    index = skip_until(codes, size, index, input.line_ends)
    lines = lines.push(input.text.slice(text_start, index - text_start))
    following = next_line_start(codes, size, index)
    if following >= 0 and doc_marker?(codes, size, skip_blanks(codes, size, following))
      current_line += 1
      current_start = following
      index = skip_blanks(codes, size, following)
    else
      collecting = false
    end
  end
  return DocScan(
    stop: index,
    line: current_line,
    line_start: current_start,
    text: lines.join("\n"),
    next: line_after_doc(codes, size, index),
  )
end

def ends_with_newline?(tokens: List[Tokens.Token]) -> Bool
  return tokens.size > 0 and tokens[tokens.size - 1].kind == "NL"
end

def in_interpolation?(delimiters: List[Frame]) -> Bool
  return delimiters.size > 0 and delimiters[delimiters.size - 1].kind == "#"
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

def unclosed(frame: Frame, here: Source.Position) -> Diag.Diagnostic
  if frame.kind == "#"
    return unterminated(frame.start, here)
  end
  help = Diag.Help.NoHelp
  if frame.kind == "{"
    help = Diag.Help.Hint(
      (
        "add the missing \"}\" of a map literal; if \"{\" was meant to open a block, remove it: blocks have no " +
        "braces and end with \"end\""
      ),
    )
  end
  return Diag.fail("LEX-UNCLOSED-DELIMITER", "unclosed " + frame.kind + " delimiter", span(frame.start, here), help)
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

def span(start: Source.Position, stop: Source.Position) -> Source.Span
  return Source.Span(start: start, stop: stop)
end

def token(
  text: String,
  kind: String,
  value: Tokens.Value,
  start: Source.Position,
  stop: Source.Position,
) -> Tokens.Token
  return Tokens.Token(
    kind: kind,
    lexeme: text.slice(start.offset, stop.offset - start.offset),
    value: value,
    span: span(start, stop),
  )
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

def unexpected_character(
  code: Int,
  character: String,
  start: Source.Position,
  stop: Source.Position,
) -> Diag.Diagnostic
  message = "unexpected character " + Unicode.written(code)
  if Unicode.graphic?(code)
    message = "unexpected character \"" + character + "\""
  end
  help = Diag.Help.NoHelp
  if code == 59
    help = Diag.Help.Hint("Agentica has no semicolons; end the statement with a newline")
  elsif code == 39 or code == 96
    help = Diag.Help.Hint(
      "strings use double quotes: \"abc\"; there is no char type, a character is a one-character String such as \"+\"",
    )
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
