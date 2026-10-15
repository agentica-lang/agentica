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

export def lex(text: String) -> Diag.Outcome[List[Tokens.Token]]
  codes = text.split("").map do |character| String.code(character) end
  size = codes.size
  keywords = keyword_table()
  operators = operator_table()
  tokens: List[Tokens.Token] = []
  delimiters: List[Frame] = []
  last_kind = ""
  open_strings = 0
  index = 0
  line = 1
  line_start = 0
  while true
    if index == size
      here = Source.position(index, line, line_start)
      if statement_level?(delimiters) and last_kind != "NL"
        tokens = tokens.push(token(text, "NL", Tokens.Value.NoValue, here, here))
      end
      opening = innermost(delimiters, false)
      if opening >= 0
        frame = delimiters[opening]
        if frame.kind == "#"
          return Diag.Outcome.Failed(unterminated(frame.start, here))
        end
        help = Diag.Help.NoHelp
        if frame.kind == "{"
          help = Diag.Help.Hint("add the missing \"}\" of a map literal; if \"{\" was meant to open a block, remove it: blocks have no braces and end with \"end\"")
        end
        return Diag.Outcome.Failed(Diag.fail("LEX-UNCLOSED-DELIMITER", "unclosed " + frame.kind + " delimiter", span(frame.start, here), help))
      end
      tokens = tokens.push(token(text, "EOF", Tokens.Value.NoValue, here, here))
      return Diag.Outcome.Done(tokens)
    end
    code = codes[index]
    if blank?(code)
      index += 1
    elsif newline?(code)
      start = Source.position(index, line, line_start)
      if code == 13 and at(codes, size, index + 1) != 10
        return Diag.Outcome.Failed(Diag.fail("LEX-UNEXPECTED-CHAR", "unexpected carriage return", span(start, start), Diag.Help.NoHelp))
      end
      if open_strings > 0
        return Diag.Outcome.Failed(unterminated(delimiters[innermost(delimiters, true)].start, start))
      end
      index += 1
      if code == 13
        index += 1
      end
      line += 1
      line_start = index
      if statement_level?(delimiters)
        tokens = tokens.push(token(text, "NL", Tokens.Value.NoValue, start, Source.position(index, line, line_start)))
        last_kind = "NL"
      end
    elsif code == 35
      if at(codes, size, index + 1) == 35 and only_blanks?(codes, line_start, index)
        start = Source.position(index, line, line_start)
        scan = scan_doc(text, codes, size, index, line, line_start)
        block = Tokens.DocBlock(text: scan.text, next: scan.next)
        tokens = tokens.push(token(text, "DOC", Tokens.Value.Doc(block), start, Source.position(scan.stop, scan.line, scan.line_start)))
        last_kind = "DOC"
        index = scan.stop
        line = scan.line
        line_start = scan.line_start
      else
        index = skip_line(codes, size, index)
      end
    elsif letter?(code) or code == 95
      start = Source.position(index, line, line_start)
      first = index
      index = skip_name(codes, size, index + 1)
      if !(code >= 65 and code <= 90) and index < size and (codes[index] == 63 or codes[index] == 33)
        if !(codes[index] == 33 and at(codes, size, index + 1) == 61)
          index += 1
        end
      end
      lexeme = text.slice(first, index - first)
      # A keyword's token kind is its own text, so the table only answers membership.
      kind = lexeme
      if !keywords.include?(lexeme)
        kind = "name"
        if code >= 65 and code <= 90
          kind = "type-name"
        end
      end
      if kind == "def" or kind == "struct" or kind == "enum" or kind == "if" or kind == "while" or kind == "for" or kind == "do"
        delimiters = delimiters.push(Frame(kind: "kw", start: start))
      elsif kind == "end" and delimiters.size > 0 and delimiters[delimiters.size - 1].kind == "kw"
        delimiters = pop(delimiters)
      end
      tokens = tokens.push(Tokens.Token(kind: kind, lexeme: lexeme, value: Tokens.Value.Text(lexeme), span: span(start, Source.position(index, line, line_start))))
      last_kind = kind
    elsif digit?(code)
      start = Source.position(index, line, line_start)
      first = index
      index = skip_number(codes, size, index)
      is_float = at(codes, size, index) == 46 and number_char?(at(codes, size, index + 1))
      if is_float
        index = skip_number(codes, size, index + 1)
      end
      stop = Source.position(index, line, line_start)
      if invalid_separator?(codes, first, index)
        return Diag.Outcome.Failed(Diag.fail("LEX-INVALID-NUMBER", "a \"_\" in a number must sit between two digits", span(start, stop), Diag.Help.Hint("write digit groups like 1_000 or 0.000_5; remove the extra \"_\"")))
      end
      digits = text.slice(first, index - first).replace("_", "")
      if is_float
        tokens = tokens.push(token(text, "float", Tokens.Value.Real(digits.to_f!), start, stop))
        last_kind = "float"
      else
        tokens = tokens.push(token(text, "integer", integer_value(digits), start, stop))
        last_kind = "integer"
      end
    elsif code == 34 or (code == 125 and delimiters.size > 0 and delimiters[delimiters.size - 1].kind == "#")
      start = Source.position(index, line, line_start)
      string_start = start
      first = true
      if code == 125
        string_start = delimiters[delimiters.size - 1].start
        first = false
        delimiters = pop(delimiters)
        open_strings -= 1
      end
      outcome = scan_string(text, codes, size, index + 1, string_start, start, line, line_start, first)
      case outcome
        Diag.Outcome.Failed(problem) -> return Diag.Outcome.Failed(problem)
        Diag.Outcome.Done(piece) ->
          tokens = tokens.push(token(text, piece.kind, Tokens.Value.Text(piece.value), start, Source.position(piece.token_end, line, line_start)))
          last_kind = piece.kind
          if piece.opens
            delimiters = delimiters.push(Frame(kind: "#", start: string_start))
            open_strings += 1
          end
          index = piece.next
      end
    else
      start = Source.position(index, line, line_start)
      lexeme = text.slice(index, 1)
      if code == 46 and at(codes, size, index + 1) == 46 and at(codes, size, index + 2) == 46
        lexeme = "..."
      elsif index + 1 < size
        pair = text.slice(index, 2)
        if operators.has_key?(pair)
          lexeme = pair
        end
      end
      kind = operators.get(lexeme, "")
      if kind == ""
        return Diag.Outcome.Failed(unexpected_character(code, lexeme, start, Source.position(index + 1, line, line_start)))
      end
      index += lexeme.length
      stop = Source.position(index, line, line_start)
      if kind == "left-paren" or kind == "left-bracket" or kind == "left-brace"
        delimiters = delimiters.push(Frame(kind: lexeme, start: start))
      elsif kind == "right-paren" or kind == "right-bracket" or kind == "right-brace"
        if delimiters.size == 0 or delimiters[delimiters.size - 1].kind != expected_opener(kind)
          help = Diag.Help.NoHelp
          if lexeme == "}" and statement_level?(delimiters)
            help = Diag.Help.Hint("blocks end with \"end\", not \"}\"")
          end
          return Diag.Outcome.Failed(Diag.fail("LEX-UNMATCHED-DELIMITER", "unmatched " + lexeme + " delimiter", span(start, stop), help))
        end
        delimiters = pop(delimiters)
      end
      tokens = tokens.push(Tokens.Token(kind: kind, lexeme: lexeme, value: Tokens.Value.Text(lexeme), span: span(start, stop)))
      last_kind = kind
    end
  end
  return Diag.Outcome.Failed(unterminated(Source.position(0, 1, 0), Source.position(0, 1, 0)))
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

def name_char?(code: Int) -> Bool
  return letter?(code) or digit?(code) or code == 95
end

def number_char?(code: Int) -> Bool
  return digit?(code) or code == 95
end

def at(codes: List[Int], size: Int, index: Int) -> Int
  if index < size
    return codes[index]
  end
  return -1
end

def skip_name(codes: List[Int], size: Int, from: Int) -> Int
  index = from
  while index < size and name_char?(codes[index])
    index += 1
  end
  return index
end

def skip_number(codes: List[Int], size: Int, from: Int) -> Int
  index = from
  while index < size and number_char?(codes[index])
    index += 1
  end
  return index
end

def skip_line(codes: List[Int], size: Int, from: Int) -> Int
  index = from
  while index < size and !newline?(codes[index])
    index += 1
  end
  return index
end

def skip_blanks(codes: List[Int], size: Int, from: Int) -> Int
  index = from
  while index < size and blank?(codes[index])
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

def scan_doc(text: String, codes: List[Int], size: Int, from: Int, line: Int, line_start: Int) -> DocScan
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
    index = skip_line(codes, size, index)
    lines = lines.push(text.slice(text_start, index - text_start))
    following = next_line_start(codes, size, index)
    if following >= 0 and doc_marker?(codes, size, skip_blanks(codes, size, following))
      current_line += 1
      current_start = following
      index = skip_blanks(codes, size, following)
    else
      collecting = false
    end
  end
  return DocScan(stop: index, line: current_line, line_start: current_start, text: lines.join("\n"), next: line_after_doc(codes, size, index))
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

def scan_string(text: String, codes: List[Int], size: Int, from: Int, string_start: Source.Position, piece_start: Source.Position, line: Int, line_start: Int, first: Bool) -> Diag.Outcome[StringPiece]
  parts: List[String] = []
  index = from
  segment = from
  while true
    if index == size
      return Diag.Outcome.Failed(unterminated(string_start, Source.position(index, line, line_start)))
    end
    code = codes[index]
    if newline?(code)
      return Diag.Outcome.Failed(unterminated(string_start, Source.position(index, line, line_start)))
    end
    if code == 34
      parts = parts.push(text.slice(segment, index - segment))
      kind = "interp-end"
      if first
        kind = "string"
      end
      return Diag.Outcome.Done(StringPiece(kind: kind, value: parts.join(""), token_end: index + 1, next: index + 1, opens: false))
    end
    if code == 35 and at(codes, size, index + 1) == 123
      parts = parts.push(text.slice(segment, index - segment))
      kind = "interp-middle"
      if first
        kind = "interp-start"
      end
      return Diag.Outcome.Done(StringPiece(kind: kind, value: parts.join(""), token_end: index, next: index + 2, opens: true))
    end
    if code == 92
      escape_start = Source.position(index, line, line_start)
      if index + 1 == size
        return Diag.Outcome.Failed(Diag.fail("LEX-INVALID-ESCAPE", "incomplete string escape", span(escape_start, Source.position(index + 1, line, line_start)), Diag.Help.NoHelp))
      end
      decoded = decoded_escape(codes[index + 1])
      if decoded == ""
        stop = Source.position(index + 2, line, line_start)
        if codes[index + 1] == 10
          stop = Source.Position(offset: index + 2, line: line + 1, column: 1)
        end
        return Diag.Outcome.Failed(Diag.fail("LEX-INVALID-ESCAPE", "unsupported escape \\" + text.slice(index + 1, 1), span(escape_start, stop), Diag.Help.NoHelp))
      end
      parts = parts.push(text.slice(segment, index - segment))
      parts = parts.push(decoded)
      index += 2
      segment = index
    else
      index += 1
    end
  end
  return Diag.Outcome.Failed(unterminated(string_start, Source.position(index, line, line_start)))
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

def expected_opener(kind: String) -> String
  case kind
    "right-paren" -> return "("
    "right-bracket" -> return "["
    _ -> return "{"
  end
end
