## Regex literals in the checker (docs/future/48-regex.md, 48.6): the file must import std/regex, and the body must be
## a valid pattern, which std/regex itself decides, so a literal cannot fail at run time.

import Ast from "../syntax/ast"
import Source from "../syntax/source"
import T from "../syntax/types"
import State from "check_state"
import Regex from "std/regex"

## The type of a regex literal, the `Regex` of std/regex. A file without an import of std/regex is CHECK-REGEX-IMPORT,
## and a body that std/regex does not compile is CHECK-INVALID-REGEX at the character where the error is.
export def check_regex(cx: State.Cx, st: State.St, node: Ast.RegexLit) -> Result[State.Out]
  if function_of(node) == ""
    return error(
      State.fail_help(
        cx,
        st,
        "CHECK-REGEX-IMPORT",
        "a regex literal needs std/regex",
        node.span,
        "add import Regex from \"std/regex\"; any import of std/regex will do",
      ),
    )
  end

  # The body alone first, so the place in the message counts the characters of the body as written.
  body = Regex.compile(node.body)
  if !body.ok?
    return error(invalid(cx, st, node, body.message))
  end

  whole = Regex.compile(pattern_of(node))
  if !whole.ok?
    return error(invalid(cx, st, node, whole.message))
  end

  return State.expr(cx, st, node.call, T.Type.Unknown)
end

# The name the linker gave the call of the literal: the linked `compile` of std/regex, or "" without an import.
def function_of(node: Ast.RegexLit) -> String
  case node.call
    Ast.Expr.MethodCall(unwrap) ->
      case unwrap.target
        Ast.Expr.Call(call) -> return call.name
        _ -> return ""
      end

    _ -> return ""
  end
end

def pattern_of(node: Ast.RegexLit) -> String
  case node.call
    Ast.Expr.MethodCall(unwrap) ->
      case unwrap.target
        Ast.Expr.Call(call) ->
          case call.args[0]
            Ast.Expr.Literal(text) ->
              case text.value
                Ast.LitValue.Text(pattern) -> return pattern
                _ -> return node.body
              end

            _ -> return node.body
          end

        _ -> return node.body
      end

    _ -> return node.body
  end
end

# CHECK-INVALID-REGEX at the character of the body that `message` (`character N: ...`) names, or at the whole literal
# when the place is not in the body (a limit of the pattern with its flags).
def invalid(cx: State.Cx, st: State.St, node: Ast.RegexLit, message: String) -> String
  span = node.span
  rest = ""
  if message.start_with?("character ")
    rest = message.slice(10, message.length - 10)
  end

  colon = rest.index_of(": ").unwrap_or(-1)
  if colon > 0
    at = rest.slice(0, colon).to_i.unwrap_or(0)
    if at >= 1 and at <= node.body.length
      start = span.start
      first = Source.Position(offset: start.offset + at, line: start.line, column: start.column + at)
      stop = Source.Position(offset: first.offset + 1, line: first.line, column: first.column + 1)
      span = Source.Span(start: first, stop: stop)
    end
  end

  return State.fail_help(
    cx,
    st,
    "CHECK-INVALID-REGEX",
    "invalid regex: #{message}",
    span,
    "the pattern syntax is that of std/regex; escape a literal character with a backslash, such as \\. or \\/",
  )
end
