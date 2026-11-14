## format(...), Ruby's Kernel#format: the format string must be a one-line string literal, read at check time, so a
## bad conversion is CHECK-FORMAT-SPEC at its characters, the count of arguments is CHECK-ARITY and an argument of the
## wrong type is CHECK-TYPE-MISMATCH with a label at its conversion. The call is a String.

import Diag from "../diagnostics/diagnostic"
import Failure from "../diagnostics/problem"
import Ast from "../syntax/ast"
import Source from "../syntax/source"
import T from "../syntax/types"
import State from "check_state"
import CheckTypes from "check_types"
import Spec from "format_spec"

## Checks a call of format.
def check_format(cx: State.Cx, st: State.St, node: Ast.Call) -> Result[State.Out]
  if node.named.size > 0 or node.args.size == 0
    return error(
      State.fail_help(
        cx,
        st,
        "CHECK-ARITY",
        "format takes a format string and then one argument for each conversion",
        node.span,
        "format(\"%05.2f\", x)",
      ),
    )
  end

  text = try literal_text(cx, st, node.args[0])
  parsed = Spec.parse(text.value)
  if parsed.message != ""
    return error(State.fail(cx, st, "CHECK-FORMAT-SPEC", parsed.message, inside(text, parsed.start, parsed.stop)))
  end

  conversions = converts(parsed.pieces)
  if conversions.all? do |c: Spec.Conversion| Spec.bare?(c) end
    return error(
      State.fail_help(
        cx,
        st,
        "CHECK-FORMAT-SPEC",
        "this format only puts values in the text; format is for a width, a precision, a flag or hex",
        text.span,
        "use interpolation: #{interpolated(cx, parsed.pieces, node.args)}",
      ),
    )
  end

  if node.args.size - 1 != conversions.size
    span = node.span
    if node.args.size - 1 > conversions.size
      span = Ast.expr_span(node.args[conversions.size + 1])
    end

    message = (
      "the format has #{conversions.size} conversion(s), so format takes #{conversions.size} argument(s) " +
      "after it; found #{node.args.size - 1}"
    )

    return error(State.fail(cx, st, "CHECK-ARITY", message, span))
  end

  first = try State.expr(cx, st, node.args[0], T.Type.String)
  current = first.st
  index = 0
  while index < conversions.size
    conversion = conversions[index]
    arg = node.args[index + 1]
    out = try State.expr(cx, current, arg, T.Type.Unknown)
    place = inside(text, conversion.start, conversion.stop)
    try ensure_fits(cx, out.st, conversion, out.type, Ast.expr_span(arg), place)
    current = out.st
    index += 1
  end

  ok(State.Out(st: current, type: T.Type.String))
end

## The parts of the format string of a checked call of format: its literal is a plain string.
def pieces_of(node: Ast.Call) -> List[Spec.Piece]
  case node.args[0]
    Ast.Expr.Literal(literal) ->
      case literal.value
        Ast.LitValue.Text(value) -> Spec.parse(value).pieces
        _ -> []
      end

    _ -> []
  end
end

private

LITERAL_HELP = (
  "write the format as a \"...\" string on one line; to choose a format at run time, choose between literals"
)

# The value of the format string and where each of its characters is in the source: offsets[i] is the column of
# character i after the opening quote, and one more entry ends the last one. offsets is empty when the source text is
# not at hand; a problem then points at the whole literal.
struct Literal
  value: String
  span: Source.Span
  offsets: List[Int]
end

def literal_text(cx: State.Cx, st: State.St, arg: Ast.Expr) -> Result[Literal]
  span = Ast.expr_span(arg)
  value = text_value(arg)
  if value.none?
    message = "the format of format(...) must be a string literal"
    return error(State.fail_help(cx, st, "CHECK-FORMAT-LITERAL", message, span, LITERAL_HELP))
  end

  source = cx.texts.get(cx.file).unwrap_or("")
  raw = source.slice(span.start.offset, span.stop.offset - span.start.offset)
  if raw.start_with?("<<~") or span.start.line != span.stop.line
    message = "the format is not a one-line string"
    return error(State.fail_help(cx, st, "CHECK-FORMAT-LITERAL", message, span, LITERAL_HELP))
  end

  ok(Literal(value: value.unwrap!, span: span, offsets: offsets_of(raw, value.unwrap!)))
end

# The text of a string literal without #{...}.
def text_value(arg: Ast.Expr) -> Optional[String]
  case arg
    Ast.Expr.Literal(literal) ->
      case literal.value
        Ast.LitValue.Text(value) -> some(value)
        _ -> none
      end

    _ -> none
  end
end

# The column of each character of value in raw, the literal with its quotes; [] when raw is not that literal. Every
# escape of a string is two characters for one (syntax/lexer.agc, ESCAPES).
def offsets_of(raw: String, value: String) -> List[Int]
  return [] if !raw.start_with?("\"") or raw.length < 2

  chars = raw.split("")
  offsets: List[Int] = []
  index = 1
  while index < chars.size - 1
    offsets = offsets.push(index)
    if chars[index] == "\\"
      index += 1
    end

    index += 1
  end

  return [] if offsets.size != value.length

  offsets.push(chars.size - 1)
end

# The span of the characters start to stop of the format string.
def inside(text: Literal, start: Int, stop: Int) -> Source.Span
  return text.span if text.offsets.size == 0

  first = text.span.start
  Source.Span(start: at(first, text.offsets[start]), stop: at(first, text.offsets[stop]))
end

def at(first: Source.Position, column: Int) -> Source.Position
  Source.Position(offset: first.offset + column, line: first.line, column: first.column + column)
end

def converts(pieces: List[Spec.Piece]) -> List[Spec.Conversion]
  found: List[Spec.Conversion] = []
  for piece in pieces
    case piece
      Spec.Piece.Convert(c) -> found = found.push(c)
      Spec.Piece.Text(_) -> found = found
    end
  end

  found
end

# The type a conversion takes; a %s takes any value with to_s.
def wanted(c: Spec.Conversion) -> T.Type
  return T.Type.Float if c.kind == "f"
  return T.Type.Unknown if c.kind == "s"

  T.Type.Int
end

def ensure_fits(
  cx: State.Cx,
  st: State.St,
  c: Spec.Conversion,
  type: T.Type,
  span: Source.Span,
  place: Source.Span,
) -> Result[Bool]
  return ok(true) if T.unknown?(type)

  if c.kind == "s"
    return ok(true) if CheckTypes.data?(cx, type)

    message = "#{T.to_text(type)} has no to_s, so %s cannot write it"
    return error(mismatch(cx, st, message, span, place, "String", type, "only data values have to_s"))
  end

  expected = wanted(c)
  return ok(true) if T.same?(type, expected)

  help = "%#{c.kind} takes an Int"
  if c.kind == "f"
    help = "%f takes a Float; write n.to_f for an Int"
  elsif T.same?(type, T.Type.Float)
    help = "%#{c.kind} takes an Int; write %f for a Float, or x.round"
  end

  message = "expected #{T.to_text(expected)}, found #{T.to_text(type)}"
  error(mismatch(cx, st, message, span, place, T.to_text(expected), type, help))
end

def mismatch(
  cx: State.Cx,
  st: State.St,
  message: String,
  span: Source.Span,
  place: Source.Span,
  expected: String,
  actual: T.Type,
  help: String,
) -> String
  base = Failure.problem(cx.file, st.signature, "CHECK-TYPE-MISMATCH", message, span, Diag.Help.Hint(help))
  labels = [Failure.Label(span: place, text: "the conversion of this argument")]
  Failure.pack(base.with(expected: expected, actual: T.to_text(actual), labels: labels))
end

# The format written as an interpolated string, for the help of a format that needs no format.
def interpolated(cx: State.Cx, pieces: List[Spec.Piece], args: List[Ast.Expr]) -> String
  source = cx.texts.get(cx.file).unwrap_or("")
  parts: List[String] = []
  next_arg = 1
  for piece in pieces
    case piece
      Spec.Piece.Text(text) -> parts = parts.push(escaped(text))
      Spec.Piece.Convert(_) ->
        code = "..."
        if next_arg < args.size
          span = Ast.expr_span(args[next_arg])
          written = source.slice(span.start.offset, span.stop.offset - span.start.offset)
          if written != "" and span.start.line == span.stop.line
            code = written
          end
        end

        parts = parts.push("\#{#{code}}")
        next_arg += 1
    end
  end

  "\"#{parts.join("")}\""
end

def escaped(text: String) -> String
  text.replace("\\", "\\\\").replace("\"", "\\\"").replace("\#{", "\\\#{").replace("\n", "\\n").replace("\t", "\\t")
end
