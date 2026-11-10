## The expansion of an `<<~EAG` template (docs/future/51-templates.md): the lines of its body, as the lexer kept them,
## in the tokens of an expression that builds its text, so that the parser and the checker see ordinary code.
##
## The body is text with tags. `<%= code %>` inserts the value of `code`, as `"#{code}"` does, `<% code %>` is a
## statement, `<%# note %>` is dropped, `<%%` is the text `<%`, and `-%>` removes the line break after the tag. A line
## that holds only one `<% %>` or `<%# %>` tag, with spaces around it, is removed whole, so a loop leaves no blank
## lines; `<%-` removes the spaces before the tag when only spaces come before it on its line. The text is raw: no
## escape and no `#{}`. A tag ends on the line where it starts, at the first `%>`, as in Ruby's ERB.
##
## `<%== code %>` always inserts the value as it is. A directive `<%@ escape function %>` on the first line gives the
## template an escaper, a `Fn[String, String]` that every `<%= %>` applies to its text: the block binds the function,
## `eag#e: Fn[String, String] = function`, and the push is `eag#t.push(eag#e.call("#{code}"))`, so the checker sees
## ordinary code and reports a function of another type at the directive.
##
## The expansion is
##
##     [0].map do |eag#n: Int|
##       eag#t: List[String] = []
##       eag#t = eag#t.push("text")
##       eag#t = eag#t.push("#{code}")
##       <statement>
##       eag#t.join("")
##     end.first
##
## which is an expression anywhere, since the language has no block expression, whose locals do not leak, and whose
## statements may be `if`, `for` or any other. The two names have a `#`, which no identifier has, so a tag can neither
## write them nor read them. Every token of a tag is lexed again from the tag's own text and keeps its place in the
## template; the tokens that glue them together take the place of their tag, or of the opener.

import Diag from "../diagnostics/diagnostic"
import Ast from "ast"
import Lexer from "lexer"
import Source from "source"
import Tokens from "token"

# The code of the error for a tag with no end on its line.
UNTERMINATED_TAG = "PARSE-EAG-UNTERMINATED-TAG"

# The code of the error for a tag whose `end` has nothing to close, or whose block the template never ends. The blocks
# are counted here, from the first word of a tag (`if`, `for`, `while`, `case`) and its `do`s, so that a template that
# does not balance is reported at its tag and not at the end of the expansion.
UNBALANCED = "PARSE-EAG-BLOCK"

# The words that open a block when they start the code of a tag.
OPENERS = Set.new(["if", "for", "while", "case"])

# The code of the error for a directive that is not `escape function`, is not on the first line, or is given twice.
DIRECTIVE = "PARSE-EAG-DIRECTIVE"

# The one word that a directive takes.
ESCAPE = "escape"

# One part of a body line: `kind` is "text", "expr" (`<%=`), "raw" (`<%==`), "stmt", "comment" or "directive"; `text`
# is the text or the code of the tag;
# `start` is the index of the code in the line as written; `trim` is whether the tag ended with `-%>`.
struct Part
  kind: String
  text: String
  start: Int
  trim: Bool
end

# What the lines so far gave: the tokens, the text that waits to become one push (in pieces, joined when it is used)
# with the line where it starts, the place of each block of a tag that no `end` has closed yet, whether the line at
# hand is the first of the body, and the escaper of the template: the tokens of its function (none when the template
# has no escaper) and the place of its directive.
struct Built
  tokens: List[Tokens.Token]
  text: List[String]
  text_at: Source.Span
  open: List[Source.Span]
  first: Bool
  escaper: List[Tokens.Token]
  escaper_at: Source.Span
end

## The tokens of the expression for the template `body`, opened by the token `opener`, ending with an EOF token; or the
## first problem of a tag: `PARSE-EAG-UNTERMINATED-TAG`, `PARSE-EAG-BLOCK`, or the lexer's own for the code of a tag.
export def expand(opener: Tokens.Token, body: Tokens.EagBody) -> Diag.Outcome[List[Tokens.Token]]
  built = Built(
    tokens: [],
    text: [],
    text_at: opener.span,
    open: [],
    first: true,
    escaper: [],
    escaper_at: opener.span,
  )

  for line in body.lines
    case line_built(opener.span, body.indent, line, built)
      Diag.Outcome.Failed(problem) -> return Diag.Outcome.Failed(problem)
      Diag.Outcome.Done(next) -> built = next.with(first: false)
    end
  end

  return Diag.Outcome.Failed(unclosed(built.open[built.open.size - 1])) if built.open.size > 0

  at = opener.span
  head = block_head(built, at)
  tail = [
    name(Ast.EAG_PIECES, at),
    word("dot", ".", at),
    name("join", at),
    word("left-paren", "(", at),
    Tokens.Token(kind: "string", lexeme: "\"\"", value: Tokens.Value.Text(""), span: at),
    word("right-paren", ")", at),
    word("NL", "\n", at),
    word("end", "end", at),
    word("dot", ".", at),
    name("first", at),
    word("EOF", "", at),
  ]

  return Diag.Outcome.Done(appended(appended(head, flush(built, at).tokens), tail))
end

# The tokens up to the first line of the block: `[0].map do |eag#n: Int|`, then the binding of the escaper when the
# template has one, `eag#e: Fn[String, String] = function`, and the list of pieces `eag#t: List[String] = []`. The
# binding stands at the place of the directive, and the tokens of the function keep theirs, so the checker reports a
# function of another type there.
def block_head(built: Built, at: Source.Span) -> List[Tokens.Token]
  head = [
    word("left-bracket", "[", at),
    number(0, at),
    word("right-bracket", "]", at),
    word("dot", ".", at),
    name("map", at),
    word("do", "do", at),
    word("pipe", "|", at),
    name(Ast.EAG_SEED, at),
    word("colon", ":", at),
    word("type-name", "Int", at),
    word("pipe", "|", at),
    word("NL", "\n", at),
  ]

  if built.escaper.size > 0
    here = built.escaper_at
    bound = [
      name(Ast.EAG_ESCAPER, here),
      word("colon", ":", here),
      word("type-name", "Fn", here),
      word("left-bracket", "[", here),
      word("type-name", "String", here),
      word("comma", ",", here),
      word("type-name", "String", here),
      word("right-bracket", "]", here),
      word("assign", "=", here),
    ]

    head = appended(appended(head, bound), built.escaper).push(word("NL", "\n", here))
  end

  return appended(
    head,
    [
      name(Ast.EAG_PIECES, at),
      word("colon", ":", at),
      word("type-name", "List", at),
      word("left-bracket", "[", at),
      word("type-name", "String", at),
      word("right-bracket", "]", at),
      word("assign", "=", at),
      word("left-bracket", "[", at),
      word("right-bracket", "]", at),
      word("NL", "\n", at),
    ],
  )
end

# One body line: its parts become tokens (and text, which the next tag or the end turns into a push).
def line_built(at: Source.Span, indent: Int, line: Tokens.EagLine, built: Built) -> Diag.Outcome[Built]
  cut = indent
  if line.text.strip == ""
    cut = line.text.length
  end

  case split(line, cut)
    Diag.Outcome.Failed(problem) -> return Diag.Outcome.Failed(problem)
    Diag.Outcome.Done(parts) -> return emit(at, line, parts, built)
  end
end

# The parts of the line after `cut` leading characters: text and tags, in order. The line is cut at each `<%` once, so
# the work is linear in its length. `column` is the index, in the cut line, of the `<%` that starts the piece at hand.
def split(line: Tokens.EagLine, cut: Int) -> Diag.Outcome[List[Part]]
  pieces = line.text.slice(cut, line.text.length - cut).split("<%")
  # The last piece with a `%>`: a tag whose code has none before it, and no later piece has one, never ends.
  last_closing = 0
  index = 0
  while index < pieces.size
    if pieces[index].include?("%>")
      last_closing = index
    end

    index += 1
  end

  parts: List[Part] = []
  buffer = [pieces[0]]
  column = pieces[0].length
  at = 1
  while at < pieces.size
    piece = pieces[at]
    mark = ""
    if piece.length > 0
      mark = piece.slice(0, 1)
    end

    if mark == "%"
      # `<%%` is the text `<%`.
      buffer = buffer.push("<%").push(piece.slice(1, piece.length - 1))
      column += 2 + piece.length
      at += 1
    else
      width = 0
      kind = "stmt"
      if mark == "=" or mark == "#" or mark == "-" or mark == "@"
        width = 1
      end

      if mark == "="
        kind = "expr"
        if piece.slice(1, 1) == "="
          kind = "raw"
          width = 2
        end
      elsif mark == "#"
        kind = "comment"
      elsif mark == "@"
        kind = "directive"
      end

      # A tag ends at the first `%>`, even when its code holds a `<%`, which the cut above split in two: the pieces up
      # to the one with the `%>` are joined once.
      inside = piece.slice(width, piece.length - width)
      if !inside.include?("%>")
        return Diag.Outcome.Failed(unterminated_tag(line, cut + column)) if last_closing <= at

        chunks = [inside]
        at += 1
        while !pieces[at].include?("%>")
          chunks = chunks.push(pieces[at])
          at += 1
        end

        inside = chunks.push(pieces[at]).join("<%")
      end

      closed = inside.index_of("%>")

      code = inside.slice(0, closed.unwrap!)
      trim = code.ends_with?("-")
      if trim
        code = code.slice(0, code.length - 1)
      end

      before = buffer.join("")
      if mark == "-" and parts.size == 0 and before.strip == ""
        before = ""
      end

      if before != ""
        parts = parts.push(Part(kind: "text", text: before, start: 0, trim: false))
      end

      parts = parts.push(Part(kind: kind, text: code, start: cut + column + 2 + width, trim: trim))
      buffer = [inside.slice(closed.unwrap! + 2, inside.length - closed.unwrap! - 2)]
      column += 2 + width + inside.length
      at += 1
    end
  end

  rest = buffer.join("")
  if rest != ""
    parts = parts.push(Part(kind: "text", text: rest, start: 0, trim: false))
  end

  return Diag.Outcome.Done(parts)
end

# The error for the `<%` at index `open_at` of the line as written: the span runs to the end of the line.
def unterminated_tag(line: Tokens.EagLine, open_at: Int) -> Diag.Diagnostic
  start = Source.Position(offset: line.start.offset + open_at, line: line.start.line, column: open_at + 1)
  stop = Source.Position(
    offset: line.start.offset + line.text.length,
    line: line.start.line,
    column: line.text.length + 1,
  )

  return Diag.fail(
    UNTERMINATED_TAG,
    "a tag has no end on its line",
    Source.Span(start: start, stop: stop),
    Diag.Help.Hint("end the tag with %> on the same line; write <%% for the text <%"),
  )
end

# Adds the tokens of the parts of one line. A line that holds only one statement or comment tag, with spaces around it,
# gives nothing else; any other line ends with a line break, unless its last tag ended with `-%>`.
def emit(at: Source.Span, line: Tokens.EagLine, parts: List[Part], built: Built) -> Diag.Outcome[Built]
  tags = parts.select do |part: Part| part.kind != "text" end
  alone = tags.size == 1 and !writes?(tags[0]) and blank_around?(parts)
  current = built
  for part in parts
    if part.kind == "text"
      if !alone
        current = current.with(text: current.text.push(part.text), text_at: text_start(current, line))
      end
    elsif part.kind == "directive"
      case directed(line, part, current)
        Diag.Outcome.Failed(problem) -> return Diag.Outcome.Failed(problem)
        Diag.Outcome.Done(next) -> current = next
      end
    elsif part.kind != "comment"
      case code_tokens(line, part)
        Diag.Outcome.Failed(problem) -> return Diag.Outcome.Failed(problem)
        Diag.Outcome.Done(code) ->
          case counted(current, part, code)
            Diag.Outcome.Failed(problem) -> return Diag.Outcome.Failed(problem)
            Diag.Outcome.Done(open) -> current = with_code(at, line, current.with(open: open), part, code)
          end
      end
    end
  end

  trimmed = parts.size > 0 and parts[parts.size - 1].kind != "text" and parts[parts.size - 1].trim
  if !alone and !trimmed
    current = current.with(text: current.text.push("\n"), text_at: text_start(current, line))
  end

  return Diag.Outcome.Done(current)
end

# Whether a tag writes its value into the output.
def writes?(part: Part) -> Bool
  return part.kind == "expr" or part.kind == "raw"
end

# The template with the escaper that the directive `<%@ escape function %>` names. A directive is valid on the first
# line of the body, once, and holds the word `escape` and the tokens of a function.
def directed(line: Tokens.EagLine, part: Part, built: Built) -> Diag.Outcome[Built]
  here = tag_span(line, part)
  if !built.first
    return Diag.Outcome.Failed(directive_error("an escape directive belongs on the first line of the template", here))
  end

  if built.escaper.size > 0
    return Diag.Outcome.Failed(directive_error("this template already has an escape directive", here))
  end

  case code_tokens(line, part)
    Diag.Outcome.Failed(problem) -> return Diag.Outcome.Failed(problem)
    Diag.Outcome.Done(code) ->
      if code.size < 2 or code[0].kind != "name" or code[0].lexeme != ESCAPE
        return Diag.Outcome.Failed(
          directive_error("a directive is <%@ escape function %>, with the function to apply", here),
        )
      end

      return Diag.Outcome.Done(built.with(escaper: code.drop(1), escaper_at: here))
  end
end

def directive_error(message: String, at: Source.Span) -> Diag.Diagnostic
  return Diag.fail(
    DIRECTIVE,
    message,
    at,
    Diag.Help.Hint("write <%@ escape &function %> alone on the first line, as in <%@ escape &EAG.html_escape %>"),
  )
end

# The place where the waiting text starts: the line of its first piece, so the push of a text has that line's place.
def text_start(built: Built, line: Tokens.EagLine) -> Source.Span
  return built.text_at if built.text.size > 0

  start = line.start
  stop = Source.Position(offset: start.offset + line.text.length, line: start.line, column: line.text.length + 1)
  return Source.Span(start: start, stop: stop)
end

# Whether the text parts of a line are all spaces.
def blank_around?(parts: List[Part]) -> Bool
  return parts.all? do |part: Part| part.kind != "text" or part.text.strip == "" end
end

# The blocks still open after the code of a tag: one more for each opener word at its start and each `do`, one fewer
# for each `end`. An `end` with no block open is the error.
def counted(built: Built, part: Part, code: List[Tokens.Token]) -> Diag.Outcome[List[Source.Span]]
  return Diag.Outcome.Done(built.open) if part.kind != "stmt" or code.size == 0

  here = Source.Span(start: code[0].span.start, stop: code[code.size - 1].span.stop)
  open = built.open
  if OPENERS.include?(code[0].kind)
    open = open.push(here)
  end

  for token in code
    if token.kind == "do"
      open = open.push(here)
    elsif token.kind == "end"
      return Diag.Outcome.Failed(stray_end(token.span)) if open.size == 0

      open = open.take(open.size - 1)
    end
  end

  return Diag.Outcome.Done(open)
end

def stray_end(at: Source.Span) -> Diag.Diagnostic
  return Diag.fail(
    UNBALANCED,
    "an end with no if, for, while, case or do to close in this template",
    at,
    Diag.Help.Hint("a template closes its own blocks: remove this end, or open the block in a tag before it"),
  )
end

def unclosed(at: Source.Span) -> Diag.Diagnostic
  return Diag.fail(
    UNBALANCED,
    "this tag opens a block that the template never ends",
    at,
    Diag.Help.Hint("close it with a tag <% end %> before the end of the template"),
  )
end

# The tokens of a tag after the text before it: `eag#t = eag#t.push("#{code}")` for `<%=` and `<%==` (for `<%=` with an
# escaper, `eag#e.call("#{code}")` stands inside the push), the code and a line break for `<% %>`. A tag without code
# gives none, but an empty `<%= %>` keeps the glue, so the parser reports it at the tag.
def with_code(at: Source.Span, line: Tokens.EagLine, built: Built, part: Part, code: List[Tokens.Token]) -> Built
  flushed = flush(built, at)
  if part.kind == "stmt"
    return flushed if code.size == 0

    return flushed.with(tokens: appended(flushed.tokens, code).push(word("NL", "\n", code[code.size - 1].span)))
  end

  here = tag_span(line, part)
  opened = Tokens.Token(kind: "interp-start", lexeme: "<%=", value: Tokens.Value.Text(""), span: here)
  closed = Tokens.Token(kind: "interp-end", lexeme: "%>", value: Tokens.Value.Text(""), span: here)
  head = push_head(here)
  tail = [closed, word("right-paren", ")", here)]
  if part.kind == "expr" and built.escaper.size > 0
    head = appended(
      head,
      [name(Ast.EAG_ESCAPER, here), word("dot", ".", here), name("call", here), word("left-paren", "(", here)],
    )

    tail = [closed, word("right-paren", ")", here), word("right-paren", ")", here)]
  end

  pushed = appended(appended(head.push(opened), code), tail)
  return flushed.with(tokens: appended(flushed.tokens, pushed).push(word("NL", "\n", here)))
end

# The place of the code of a tag in the template, empty code included.
def tag_span(line: Tokens.EagLine, part: Part) -> Source.Span
  start = Source.Position(offset: line.start.offset + part.start, line: line.start.line, column: part.start + 1)
  stop = Source.Position(
    offset: start.offset + part.text.length,
    line: start.line,
    column: start.column + part.text.length,
  )

  return Source.Span(start: start, stop: stop)
end

# The tokens `eag#t = eag#t.push(`.
def push_head(at: Source.Span) -> List[Tokens.Token]
  return [
    name(Ast.EAG_PIECES, at),
    word("assign", "=", at),
    name(Ast.EAG_PIECES, at),
    word("dot", ".", at),
    name("push", at),
    word("left-paren", "(", at),
  ]
end

# The pending text as one push of a string, when there is any.
def flush(built: Built, at: Source.Span) -> Built
  return built if built.text.size == 0

  where = built.text_at
  literal = Tokens.Token(kind: "string", lexeme: "\"\"", value: Tokens.Value.Text(built.text.join("")), span: where)
  pushed = push_head(where).push(literal).push(word("right-paren", ")", where)).push(word("NL", "\n", where))
  return built.with(tokens: appended(built.tokens, pushed), text: [])
end

# The tokens of the code of a tag, lexed from its own text and moved to where it stands in the template, without the
# line break and the end that the lexer adds.
def code_tokens(line: Tokens.EagLine, part: Part) -> Diag.Outcome[List[Tokens.Token]]
  origin = Source.Position(offset: line.start.offset + part.start, line: line.start.line, column: part.start + 1)
  case Lexer.lex(part.text)
    Diag.Outcome.Failed(problem) -> return Diag.Outcome.Failed(problem.with(span: moved_span(origin, problem.span)))
    Diag.Outcome.Done(tokens) ->
      kept = tokens.select do |token: Tokens.Token| token.kind != "NL" and token.kind != "EOF" end
      return Diag.Outcome.Done(kept.map do |token: Tokens.Token| token.with(span: moved_span(origin, token.span)) end)
  end
end

def moved_span(origin: Source.Position, span: Source.Span) -> Source.Span
  return Source.Span(start: moved(origin, span.start), stop: moved(origin, span.stop))
end

# A position of the code of a tag, counted from the start of that code, as a position of the template. The code is on
# one line, so the column moves by the column of the origin.
def moved(origin: Source.Position, at: Source.Position) -> Source.Position
  return Source.Position(
    offset: origin.offset + at.offset,
    line: origin.line + at.line - 1,
    column: origin.column + at.column - 1,
  )
end

# The list with the items added at its end, one `push` each: `concat` would copy the whole token list for every tag.
def appended(list: List[Tokens.Token], items: List[Tokens.Token]) -> List[Tokens.Token]
  out = list
  for item in items
    out = out.push(item)
  end

  return out
end

def word(kind: String, lexeme: String, at: Source.Span) -> Tokens.Token
  return Tokens.Token(kind: kind, lexeme: lexeme, value: Tokens.Value.Text(lexeme), span: at)
end

def name(text: String, at: Source.Span) -> Tokens.Token
  return Tokens.Token(kind: "name", lexeme: text, value: Tokens.Value.Text(text), span: at)
end

def number(value: Int, at: Source.Span) -> Tokens.Token
  return Tokens.Token(kind: "integer", lexeme: "#{value}", value: Tokens.Value.Whole(value), span: at)
end
