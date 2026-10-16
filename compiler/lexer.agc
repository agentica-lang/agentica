import Diag from "diagnostic"
import Source from "source"
import Tokens from "token"
import Unicode from "unicode"

## The token kind of each operator and bracket.
OPERATOR_KINDS = {
  "->": "arrow", "==": "equal", "!=": "not-equal", "<=": "less-equal", ">=": "greater-equal",
  "&&": "and", "||": "or", "!": "not", "+=": "plus-assign", "-=": "minus-assign",
  "*=": "multiply-assign", "/=": "divide-assign", "%=": "modulo-assign",
  "(": "left-paren", ")": "right-paren", "[": "left-bracket", "]": "right-bracket",
  "{": "left-brace", "}": "right-brace", ",": "comma", ":": "colon", ".": "dot",
  "..": "dot-dot", "...": "dot-dot-dot", "=": "assign", "+": "plus", "-": "minus",
  "*": "multiply", "/": "divide", "%": "modulo", "<": "less", ">": "greater",
  "&": "ampersand", "|": "pipe", "|>": "pipe-forward",
}

## What a word does: 1 for a keyword, 2 for a keyword that opens a block (`end` closes it), 3 for `end`. A name is
## not in the map (0).
WORD_ACTIONS = {
  "import": 1, "export": 1, "def": 2, "struct": 2, "enum": 2, "case": 1, "do": 2, "end": 3, "if": 2, "elsif": 1,
  "else": 1, "while": 2, "for": 2, "in": 1, "return": 1, "try": 1, "true": 1, "false": 1, "nil": 1, "and": 1,
  "or": 1, "not": 1,
}

## The characters of a name after its first one: letters, digits and `_`. Never the sentinel `""`: a name scan stops at
## the end of the text only because the sentinel is in no set.
NAME_CHARS = Set.new("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_".split(""))

## The characters of a number: digits and `_`. Never the sentinel `""`, as for NAME_CHARS.
NUMBER_CHARS = Set.new("0123456789_".split(""))

## Where a comment or a doc line ends: a line break, or the sentinel that follows the last character of the text.
LINE_ENDS = Set.new(["\n", "\r", ""])

## Where the plain text of a string ends: `"`, `#`, `\`, a line break, or the sentinel.
STRING_STOPS = Set.new(["\"", "#", "\\", "\n", "\r", ""])

## What follows a `\` in a string, and the character it stands for.
ESCAPES = {"\"": "\"", "\\": "\\", "#": "#", "n": "\n", "r": "\r", "t": "\t"}

## The class of each ASCII character; any other character is `Other`.
CLASSES: Map[String, CharClass] = (0..127).to_a.reduce({}) do |classes, code|
  character = String.from_code(code)
  kind = CharClass.Other
  if code == 32 or code == 9
    kind = CharClass.Blank
  elsif code == 10 or code == 13
    kind = CharClass.Newline
  elsif code == 35
    kind = CharClass.Hash
  elsif code >= 65 and code <= 90
    kind = CharClass.NameUpper
  elsif (code >= 97 and code <= 122) or code == 95
    kind = CharClass.NameLower
  elsif code >= 48 and code <= 57
    kind = CharClass.Digit
  elsif code == 34
    kind = CharClass.Quote
  elsif code == 40 or code == 91 or code == 123
    kind = CharClass.Opening
  elsif code == 41 or code == 93
    kind = CharClass.Closing
  elsif code == 125
    kind = CharClass.CloseBrace
  elsif ",:.=+-*/%<>&|!".contains?(character)
    kind = CharClass.Operator
  end
  classes.put(character, kind)
end

## The operators and brackets of one character.
SINGLE_LEXEMES = ["(", ")", "[", "]", "{", "}", ",", ":", ".", "=", "+", "-", "*", "/", "%", "<", ">", "&", "|", "!"]

## The operators of two characters.
PAIR_LEXEMES = ["->", "==", "!=", "<=", ">=", "&&", "||", "+=", "-=", "*=", "/=", "%=", "..", "|>"]

## The operator or bracket that a character writes alone, by that character.
SINGLE_OPS: Map[String, Op] = SINGLE_LEXEMES.reduce({}) do |ops, lexeme|
  value = Tokens.Value.Text(lexeme)
  ops.put(lexeme, Op(kind: OPERATOR_KINDS.get(lexeme, ""), lexeme: lexeme, value: value, width: 1))
end

## The operators of two characters, by their text.
PAIR_OPS: Map[String, Op] = PAIR_LEXEMES.reduce({}) do |ops, lexeme|
  value = Tokens.Value.Text(lexeme)
  ops.put(lexeme, Op(kind: OPERATOR_KINDS.get(lexeme, ""), lexeme: lexeme, value: value, width: 2))
end

## The second characters of the operators of two characters, so that one lookup tells an operator that stops at one
## character.
PAIR_SECONDS = Set.new(["=", ">", "&", "|", "."])

## The only operator of three characters.
ELLIPSIS = Op(kind: "dot-dot-dot", lexeme: "...", value: Tokens.Value.Text("..."), width: 3)

## The opener that each closing bracket needs on top of the frames.
OPENERS = {")": "(", "]": "[", "}": "{"}

## The default of a table lookup that cannot miss.
NO_OP = Op(kind: "", lexeme: "", value: Tokens.Value.NoValue, width: 1)

## The frame on top of an empty stack: the top level counts as a block, so a line break there is a statement break.
ROOT = Frame(kind: "kw", start: Source.Position(offset: 0, line: 1, column: 1), inside: -1)

# An open bracket (`(`, `[`, `{`), an interpolation (`#`) or a block (`kw`), and
# where it opened. `inside` is the stack index of the innermost `#` frame at or
# below this one (-1 if none), fixed when the frame is pushed. It keeps the
# per-line "am I inside an interpolation" check O(1): scanning the stack for
# it on every line break made a deeply nested file quadratic.
struct Frame
  kind: String
  start: Source.Position
  inside: Int
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

# What a string piece changes in the main loop: the tokens and frames so far, and where scanning goes on.
struct Progress
  tokens: List[Tokens.Token]
  delimiters: List[Frame]
  index: Int
end

# An operator or bracket, with its token kind and value ready: the main loop makes no string or value for it.
struct Op
  kind: String
  lexeme: String
  value: Tokens.Value
  width: Int
end

# The kind of a character at the start of a token; `lex` dispatches on it.
# `Operator` is every operator character but the brackets.
enum CharClass
  Blank
  Newline
  Hash
  NameUpper
  NameLower
  Digit
  Quote
  Opening
  Closing
  CloseBrace
  Operator
  Other
end

# What never changes while one text is lexed: the text and its characters
# (positions count characters), followed by three sentinels (""), so a scan or a
# look-ahead of up to two characters needs no bounds check: "" is in no
# character set. `size` is the number of characters, without the sentinels.
# `lines` are the lines of the text, for a comment or a doc line to end at the
# length of its line instead of a scan; it is empty when the text has a CR,
# which can end a line early (`by_lines` is false then).
struct Input
  text: String
  chars: List[String]
  size: Int
  lines: List[String]
  by_lines: Bool
end

## Lexes a source text into its tokens, or the first `LEX-` diagnostic.
export def lex(text: String) -> Diag.Outcome[List[Tokens.Token]]
  input = new_input(text)
  chars = input.chars
  size = input.size
  tokens: List[Tokens.Token] = []
  delimiters: List[Frame] = []
  # The size of `delimiters` and its last frame (ROOT when empty), kept beside it so that a bracket or a line break
  # reads them without a call.
  depth = 0
  top = ROOT
  index = 0
  line = 1
  line_start = 0
  # The column of a character is its offset plus this, a sum where the line start would need a subtraction and an
  # addition; it changes where `line_start` does.
  column_base = 1
  # The arms for names, operators, brackets and line breaks (nine of ten tokens) do their work in place: a call
  # costs a few VM steps, and the lexer makes a token every 5 characters or so (docs/vm-benchmarks.md, "Speed
  # pass, second part"). The arms for strings, numbers and docs call a function: they are rare.
  # An arm may read up to `index + 2` with no bounds test: the sentinels after the text (see Input) cover it.
  while index < size
    char = chars[index]
    case CLASSES.get(char, CharClass.Other)
      CharClass.NameLower ->
        start = Source.Position(offset: index, line: line, column: index + column_base)
        stop = index + 1
        while NAME_CHARS.include?(chars[stop])
          stop += 1
        end
        # A name may end in `?` or `!`, except that `!=` is the operator.
        mark = chars[stop]
        if mark == "?" or (mark == "!" and chars[stop + 1] != "=")
          stop += 1
          mark = chars[stop]
        end
        lexeme = text.slice(index, stop - index)
        kind = "name"
        action = WORD_ACTIONS.get(lexeme, 0)
        if action > 0
          kind = lexeme
          if action == 2
            top = Frame(kind: "kw", start: start, inside: top.inside)
            delimiters = delimiters.push(top)
            depth += 1
          elsif action == 3 and depth > 0 and top.kind == "kw"
            depth -= 1
            delimiters = delimiters.take(depth)
            top = frame_on_top(delimiters, depth)
          end
        end
        tokens = tokens.push(
          Tokens.Token(
            kind: kind,
            lexeme: lexeme,
            value: Tokens.Value.Text(lexeme),
            span: Source.Span(
              start: start,
              stop: Source.Position(offset: stop, line: line, column: stop + column_base),
            ),
          ),
        )
        index = stop
        if mark == " "
          index += 1
        end
      CharClass.Blank ->
        index += 1
        while chars[index] == " " or chars[index] == "\t"
          index += 1
        end
      CharClass.Operator ->
        op = SINGLE_OPS.get(char, NO_OP)
        ahead = chars[index + 1]
        mark = ahead
        if PAIR_SECONDS.include?(ahead)
          op = PAIR_OPS.get(char + ahead, op)
          if op.width == 2 and char == "." and chars[index + 2] == "."
            op = ELLIPSIS
          end
          mark = chars[index + op.width]
        end
        stop = index + op.width
        tokens = tokens.push(
          Tokens.Token(
            kind: op.kind,
            lexeme: op.lexeme,
            value: op.value,
            span: Source.Span(
              start: Source.Position(offset: index, line: line, column: index + column_base),
              stop: Source.Position(offset: stop, line: line, column: stop + column_base),
            ),
          ),
        )
        index = stop
        if mark == " "
          index += 1
        end
      CharClass.NameUpper ->
        word = type_name_token(input, index, line, column_base)
        tokens = tokens.push(word)
        index = word.span.stop.offset
      CharClass.Opening ->
        op = SINGLE_OPS.get(char, NO_OP)
        opening = operator_token(op, index, line, column_base)
        top = Frame(kind: op.lexeme, start: opening.span.start, inside: top.inside)
        delimiters = delimiters.push(top)
        depth += 1
        tokens = tokens.push(opening)
        index += 1
      CharClass.Closing ->
        if top.kind != OPENERS.get(char, "")
          return Diag.Outcome.Failed(unmatched(delimiters, index, char, line, column_base))
        end
        tokens = tokens.push(operator_token(SINGLE_OPS.get(char, NO_OP), index, line, column_base))
        depth -= 1
        delimiters = delimiters.take(depth)
        top = frame_on_top(delimiters, depth)
        index += 1
      CharClass.CloseBrace ->
        # A `}` that closes an interpolation continues the string, not a map.
        case close_brace(input, tokens, delimiters, index, line, line_start)
          Diag.Outcome.Failed(problem) -> return Diag.Outcome.Failed(problem)
          Diag.Outcome.Done(progress) ->
            tokens = progress.tokens
            delimiters = progress.delimiters
            depth = delimiters.size
            top = frame_on_top(delimiters, depth)
            index = progress.index
        end
      CharClass.Quote ->
        case scan_piece(input, tokens, delimiters, index, line, line_start)
          Diag.Outcome.Failed(problem) -> return Diag.Outcome.Failed(problem)
          Diag.Outcome.Done(progress) ->
            tokens = progress.tokens
            delimiters = progress.delimiters
            depth = delimiters.size
            top = frame_on_top(delimiters, depth)
            index = progress.index
        end
      CharClass.Newline ->
        start = Source.Position(offset: index, line: line, column: index + column_base)
        # A CR must come with its LF, and a line break cannot sit inside a string interpolation (any `#`
        # frame on the stack: only string pieces push or pop them).
        lexeme = "\n"
        next = index + 1
        if char == "\r"
          if chars[next] != "\n"
            return Diag.Outcome.Failed(
              Diag.fail("LEX-UNEXPECTED-CHAR", "unexpected carriage return", span(start, start), Diag.Help.NoHelp),
            )
          end
          lexeme = "\r\n"
          next += 1
        end
        if top.inside >= 0
          return Diag.Outcome.Failed(unterminated(delimiters[top.inside].start, start))
        end
        if top.kind == "kw"
          tokens = tokens.push(
            Tokens.Token(
              kind: "NL",
              lexeme: lexeme,
              value: Tokens.Value.NoValue,
              span: Source.Span(start: start, stop: Source.Position(offset: next, line: line + 1, column: 1)),
            ),
          )
        end
        index = next
        line += 1
        line_start = next
        column_base = 1 - next
      CharClass.Hash ->
        if chars[index + 1] == "#" and only_blanks?(chars, line_start, index)
          scan = scan_doc(input, index, line, line_start)
          tokens = tokens.push(doc_token(input, scan, index, line, line_start))
          index = scan.stop
          line = scan.line
          line_start = scan.line_start
          column_base = 1 - line_start
        else
          index = line_end(input, index, line, line_start)
        end
      CharClass.Digit ->
        case scan_number(input, index, line, line_start)
          Diag.Outcome.Failed(problem) -> return Diag.Outcome.Failed(problem)
          Diag.Outcome.Done(number) ->
            tokens = tokens.push(number)
            index = number.span.stop.offset
        end
      CharClass.Other ->
        start = Source.Position(offset: index, line: line, column: index + column_base)
        return Diag.Outcome.Failed(unexpected_character(char, start, Source.position(index + 1, line, line_start)))
    end
  end
  return finish(input, tokens, delimiters, Source.position(index, line, line_start))
end

# The text as a list of characters (positions count characters) and the sentinels
# that end it, and its lines when no CR can end one early.
def new_input(text: String) -> Input
  chars = text.split("")
  by_lines = !text.contains?("\r")
  lines: List[String] = []
  if by_lines
    lines = text.split("\n")
  end
  return Input(text: text, chars: chars.concat(["", "", ""]), size: chars.size, lines: lines, by_lines: by_lines)
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
  opening = innermost_bracket(delimiters)
  if opening >= 0
    return Diag.Outcome.Failed(unclosed(delimiters[opening], here))
  end
  return Diag.Outcome.Done(closed.push(token(input.text, "EOF", Tokens.Value.NoValue, here, here)))
end

# The offset where the comment or doc text that is at `from` ends: the line break, or the end of the text. A line
# knows its length, so this costs no scan of the characters.
def line_end(input: Input, from: Int, line: Int, line_start: Int) -> Int
  if input.by_lines
    return line_start + input.lines[line - 1].length
  end
  return skip_until(input.chars, from, LINE_ENDS)
end

# The DOC token of a scanned `##` block; its span ends where the block ends.
def doc_token(input: Input, scan: DocScan, first: Int, line: Int, line_start: Int) -> Tokens.Token
  block = Tokens.DocBlock(text: scan.text, next: scan.next)
  start = Source.position(first, line, line_start)
  stop = Source.position(scan.stop, scan.line, scan.line_start)
  return token(input.text, "DOC", Tokens.Value.Doc(block), start, stop)
end

# A name that starts with an upper-case letter: it takes no `?` or `!` and is never a keyword.
def type_name_token(input: Input, first: Int, line: Int, column_base: Int) -> Tokens.Token
  chars = input.chars
  stop = first + 1
  while NAME_CHARS.include?(chars[stop])
    stop += 1
  end
  lexeme = input.text.slice(first, stop - first)
  return Tokens.Token(
    kind: "type-name",
    lexeme: lexeme,
    value: Tokens.Value.Text(lexeme),
    span: Source.Span(
      start: Source.Position(offset: first, line: line, column: first + column_base),
      stop: Source.Position(offset: stop, line: line, column: stop + column_base),
    ),
  )
end

# An integer or float starting at `first`. A `_` must sit between two digits.
def scan_number(input: Input, first: Int, line: Int, line_start: Int) -> Diag.Outcome[Tokens.Token]
  chars = input.chars
  index = skip_in(chars, first, NUMBER_CHARS)
  is_float = chars[index] == "." and NUMBER_CHARS.include?(chars[index + 1])
  if is_float
    index = skip_in(chars, index + 1, NUMBER_CHARS)
  end
  start = Source.position(first, line, line_start)
  stop = Source.position(index, line, line_start)
  if invalid_separator?(chars, first, index)
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
  line: Int,
  line_start: Int,
) -> Diag.Outcome[StringPiece]
  chars = input.chars
  size = input.size
  first = chars[at_index] == "\""
  string_start = Source.position(at_index, line, line_start)
  if !first
    string_start = delimiters[delimiters.size - 1].start
  end
  parts: List[String] = []
  index = at_index + 1
  segment = index
  while true
    index = skip_until(chars, index, STRING_STOPS)
    stopper = chars[index]
    if index == size or stopper == "\n" or stopper == "\r"
      return Diag.Outcome.Failed(unterminated(string_start, Source.position(index, line, line_start)))
    end
    if stopper == "\""
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
    elsif stopper == "#" and chars[index + 1] == "{"
      kind = "interp-middle"
      if first
        kind = "interp-start"
      end
      value = parts.push(input.text.slice(segment, index - segment)).join("")
      return Diag.Outcome.Done(
        StringPiece(kind: kind, value: value, token_end: index, next: index + 2, opens: true, start: string_start),
      )
    elsif stopper == "\\"
      decoded = ""
      if index + 1 < size
        decoded = ESCAPES.get(chars[index + 1], "")
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
  if input.chars[index + 1] == "\n"
    stop = Source.Position(offset: index + 2, line: line + 1, column: 1)
  end
  # The message is a backslash followed by the escaped character, such as: unsupported escape \q
  return Diag.fail(
    "LEX-INVALID-ESCAPE",
    "unsupported escape \\#{input.chars[index + 1]}",
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

# The token of an operator or bracket of the table, from `index`.
def operator_token(op: Op, index: Int, line: Int, column_base: Int) -> Tokens.Token
  stop = index + op.width
  return Tokens.Token(
    kind: op.kind,
    lexeme: op.lexeme,
    value: op.value,
    span: Source.Span(
      start: Source.Position(offset: index, line: line, column: index + column_base),
      stop: Source.Position(offset: stop, line: line, column: stop + column_base),
    ),
  )
end

# The diagnostic for a `)`, `]` or `}` that finds a different frame on top: `LEX-UNMATCHED-DELIMITER`.
def unmatched(delimiters: List[Frame], index: Int, char: String, line: Int, column_base: Int) -> Diag.Diagnostic
  help = Diag.Help.NoHelp
  if char == "}" and statement_level?(delimiters)
    help = Diag.Help.Hint("blocks end with \"end\", not \"}\"")
  end
  return Diag.fail(
    "LEX-UNMATCHED-DELIMITER",
    "unmatched #{char} delimiter",
    span(
      Source.Position(offset: index, line: line, column: index + column_base),
      Source.Position(offset: index + 1, line: line, column: index + 1 + column_base),
    ),
    help,
  )
end

# A `}`: it ends a string interpolation when a `#` frame is on top, and closes a `{` otherwise.
def close_brace(
  input: Input,
  tokens: List[Tokens.Token],
  delimiters: List[Frame],
  index: Int,
  line: Int,
  line_start: Int,
) -> Diag.Outcome[Progress]
  if in_interpolation?(delimiters)
    return scan_piece(input, tokens, delimiters, index, line, line_start)
  end
  if delimiters.size == 0 or delimiters[delimiters.size - 1].kind != "{"
    return Diag.Outcome.Failed(unmatched(delimiters, index, "}", line, 1 - line_start))
  end
  closing = operator_token(SINGLE_OPS.get("}", NO_OP), index, line, 1 - line_start)
  return Diag.Outcome.Done(Progress(tokens: tokens.push(closing), delimiters: pop(delimiters), index: index + 1))
end

# One string piece, from the `"` or the `}` at `index`: its token, and the frames
# it closes (the `#` of the `}`) and opens (a `#{`).
def scan_piece(
  input: Input,
  tokens: List[Tokens.Token],
  delimiters: List[Frame],
  index: Int,
  line: Int,
  line_start: Int,
) -> Diag.Outcome[Progress]
  case scan_string(input, delimiters, index, line, line_start)
    Diag.Outcome.Failed(problem) -> return Diag.Outcome.Failed(problem)
    Diag.Outcome.Done(piece) ->
      frames = delimiters
      if input.chars[index] == "}"
        frames = pop(frames)
      end
      if piece.opens
        frames = open_frame(frames, "#", piece.start)
      end
      return Diag.Outcome.Done(
        Progress(
          tokens: tokens.push(piece_token(input, piece, index, line, line_start)),
          delimiters: frames,
          index: piece.next,
        ),
      )
  end
end

# A `##` doc block starting at `from`: one line per `##`, and the block goes on
# while the next line (after blanks) starts with `##` again. `next` tells the
# parser what follows the block (blank line, comment, code or end of file).
def scan_doc(input: Input, from: Int, line: Int, line_start: Int) -> DocScan
  chars = input.chars
  size = input.size
  lines: List[String] = []
  index = from
  current_line = line
  current_start = line_start
  collecting = true
  while collecting
    index += 2
    if index < size and chars[index] == " "
      index += 1
    end
    text_start = index
    index = line_end(input, index, current_line, current_start)
    lines = lines.push(input.text.slice(text_start, index - text_start))
    following = next_line_start(chars, size, index)
    if following >= 0 and doc_marker?(chars, size, skip_blanks(chars, size, following))
      current_line += 1
      current_start = following
      index = skip_blanks(chars, size, following)
    else
      collecting = false
    end
  end
  return DocScan(
    stop: index,
    line: current_line,
    line_start: current_start,
    text: lines.join("\n"),
    next: line_after_doc(chars, size, index),
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

# The stack index of the innermost `#` frame, or -1. O(1): the top frame
# already knows it.
def innermost_interpolation(delimiters: List[Frame]) -> Int
  if delimiters.size == 0
    return -1
  end
  return delimiters[delimiters.size - 1].inside
end

# The stack index of the innermost frame that is not a block, or -1. Walks the
# stack, so only `finish` calls it, once per text.
def innermost_bracket(delimiters: List[Frame]) -> Int
  index = delimiters.size - 1
  while index >= 0
    if delimiters[index].kind != "kw"
      return index
    end
    index -= 1
  end
  return -1
end

# Pushes a frame. The new frame is its own innermost `#` frame when it is one,
# otherwise it inherits the one below.
def open_frame(delimiters: List[Frame], kind: String, start: Source.Position) -> List[Frame]
  inside = innermost_interpolation(delimiters)
  if kind == "#"
    inside = delimiters.size
  end
  return delimiters.push(Frame(kind: kind, start: start, inside: inside))
end

def pop(delimiters: List[Frame]) -> List[Frame]
  return delimiters.take(delimiters.size - 1)
end

# The last frame of a stack of `depth` frames, or ROOT.
def frame_on_top(delimiters: List[Frame], depth: Int) -> Frame
  if depth == 0
    return ROOT
  end
  return delimiters[depth - 1]
end

def unclosed(frame: Frame, here: Source.Position) -> Diag.Diagnostic
  if frame.kind == "#"
    return unterminated(frame.start, here)
  end
  help = Diag.Help.NoHelp
  if frame.kind == "{"
    help = Diag.Help.Hint(
      (
        "add the missing \"}\" of a map literal; if \"{\" was meant to open a block, remove it: " +
        "blocks have no braces and end with \"end\""
      ),
    )
  end
  return Diag.fail("LEX-UNCLOSED-DELIMITER", "unclosed #{frame.kind} delimiter", span(frame.start, here), help)
end

def blank?(char: String) -> Bool
  return char == " " or char == "\t"
end

def newline?(char: String) -> Bool
  return char == "\n" or char == "\r"
end

# The character at `index`, or "" past the end of the text.
def at(chars: List[String], size: Int, index: Int) -> String
  if index < size
    return chars[index]
  end
  return ""
end

def skip_blanks(chars: List[String], size: Int, from: Int) -> Int
  index = from
  while index < size and blank?(chars[index])
    index += 1
  end
  return index
end

# Index of the first character from `from` that is not in `members` (`size` at
# the latest: the sentinel is in no set). A while loop on purpose: the
# tail-recursive form measured 2-4% slower.
def skip_in(chars: List[String], from: Int, members: Set[String]) -> Int
  index = from
  while members.include?(chars[index])
    index += 1
  end
  return index
end

# Index of the first character from `from` that is in `stops` (`size` at the
# latest: the stop sets hold the sentinel "").
def skip_until(chars: List[String], from: Int, stops: Set[String]) -> Int
  index = from
  while !stops.include?(chars[index])
    index += 1
  end
  return index
end

def only_blanks?(chars: List[String], from: Int, stop: Int) -> Bool
  index = from
  while index < stop
    if !blank?(chars[index])
      return false
    end
    index += 1
  end
  return true
end

def doc_marker?(chars: List[String], size: Int, index: Int) -> Bool
  return index + 1 < size and chars[index] == "#" and chars[index + 1] == "#"
end

def next_line_start(chars: List[String], size: Int, index: Int) -> Int
  if index >= size
    return -1
  end
  if chars[index] == "\n"
    return index + 1
  end
  if chars[index] == "\r" and at(chars, size, index + 1) == "\n"
    return index + 2
  end
  return -1
end

def line_after_doc(chars: List[String], size: Int, index: Int) -> String
  following = next_line_start(chars, size, index)
  if following < 0
    return "eof"
  end
  found = skip_blanks(chars, size, following)
  if found >= size
    return "eof"
  end
  if newline?(chars[found])
    return "blank"
  end
  if chars[found] == "#"
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

def invalid_separator?(chars: List[String], from: Int, stop: Int) -> Bool
  index = from
  while index < stop
    char = chars[index]
    if char == "_"
      following = at(chars, stop, index + 1)
      if following == "" or following == "_" or following == "."
        return true
      end
    elsif char == "." and at(chars, stop, index + 1) == "_"
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

def unexpected_character(character: String, start: Source.Position, stop: Source.Position) -> Diag.Diagnostic
  code = String.code(character)
  message = "unexpected character #{Unicode.written(code)}"
  if Unicode.graphic?(code)
    message = "unexpected character \"#{character}\""
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
