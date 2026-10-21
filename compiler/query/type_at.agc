## `agentica type-at` as a stage (docs/future/39-semantic-cli.md, 39.3): a linked and checked program and a position in
## its root file in, the type of the innermost expression there and its definition out, or QUERY-NO-EXPRESSION.
##
## A position must be on a token: a blank between tokens, a comment, the end of a line and anything past the end of the
## text hold no expression, even inside the span of one. A local (a parameter, a binding, a loop variable or a pattern
## name) is answered with its type and no definition; its binding is not recorded yet.

import Checker from "../check/checker"
import Diag from "../diagnostics/diagnostic"
import Linker from "../modules/linker"
import Ast from "../syntax/ast"
import Lexer from "../syntax/lexer"
import Source from "../syntax/source"
import T from "../syntax/types"
import At from "at"
import Definitions from "definitions"
import Position from "query_position"

# The characters of a name written in front of the parenthesis of a call: a name, a dot between a module and its
# member, and the ? or ! that ends a name.
HEAD_CHARS = Set.new("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.?!".split(""))

# The longest name a call head is read from, in characters.
HEAD_LIMIT = 128

## What a position is on. `kind` is `name` when the position is on a name (a variable, a function or type named, the
## name of a field or method after the dot) and `expression` otherwise; `span` is always the whole expression, so on
## the name of a field access it is the whole access. `text` is the source text of `span`, `type` the type as the root
## file writes it, and `definition` the declaration of what the expression names.
export struct Answer
  kind: String
  span: Source.Span
  text: String
  type: String
  definition: Ast.Optional[Definitions.Definition]
end

## The answer for `asked`, a position in the root file of `linked` (checked as `checked`), or QUERY-NO-EXPRESSION.
export def answer(linked: Linker.Linked, checked: Checker.Checked, asked: Position.Asked) -> Diag.Outcome[Answer]
  module = linked.modules[0]
  case Position.locate(module.text, asked.line, asked.column)
    Position.Located.Outside(span) -> return nothing(asked, span)
    Position.Located.At(offset) ->
      here = Position.character(offset, asked.line, asked.column)
      if !on_token?(module.text, offset)
        return nothing(asked, here)
      end
      case At.innermost(module, checked.types, offset)
        Ast.Optional.Absent -> return nothing(asked, here)
        Ast.Optional.Present(expr) -> return Diag.Outcome.Done(found(linked, checked, expr, offset))
      end
  end
end

def nothing(asked: Position.Asked, span: Source.Span) -> Diag.Outcome[Answer]
  return Diag.Outcome.Failed(
    Diag.fail(
      "QUERY-NO-EXPRESSION",
      "no expression at line #{asked.line}, column #{asked.column}",
      span,
      Diag.Help.Hint("put the position on a token of an expression; agentica outline lists the declarations"),
    ),
  )
end

def found(linked: Linker.Linked, checked: Checker.Checked, expr: Ast.Expr, offset: Int) -> Answer
  module = linked.modules[0]
  span = Ast.expr_span(expr)
  kind = "expression"
  if on_name?(expr, module.text, offset)
    kind = "name"
  end
  return Answer(
    kind: kind,
    span: span,
    text: source_text(module.text, span),
    type: T.to_text_as(checked.types[Ast.expr_id(expr)], written_prefixes(linked)),
    definition: Definitions.of_expr(linked.modules, checked.types, expr),
  )
end

# The text of a span; empty when the span does not lie in the text.
def source_text(text: String, span: Source.Span) -> String
  size = span.stop.offset - span.start.offset
  if span.start.offset < 0 or size < 0 or span.stop.offset > text.length
    return ""
  end
  return text.slice(span.start.offset, size)
end

# Whether some token of the text holds the character at `offset`. Line breaks and the end are tokens that hold nothing.
def on_token?(text: String, offset: Int) -> Bool
  case Lexer.lex(text)
    Diag.Outcome.Failed(_) -> return false
    Diag.Outcome.Done(tokens) ->
      for token in tokens
        if token.span.start.offset > offset
          return false
        elsif token.kind != "NL" and token.kind != "eof" and At.holds?(token.span, offset)
          return true
        end
      end
      return false
  end
end

# Whether the position is on a name: an expression that is a name, or the name part of one that has a name in it.
def on_name?(expr: Ast.Expr, text: String, offset: Int) -> Bool
  case expr
    Ast.Expr.Name(_) -> return true
    Ast.Expr.ConstRef(_) -> return true
    Ast.Expr.TypeName(_) -> return true
    Ast.Expr.FunctionRef(_) -> return true
    Ast.Expr.FieldAccess(node) -> return At.holds?(node.name_span, offset)
    Ast.Expr.MethodCall(node) -> return At.holds?(node.name_span, offset)
    Ast.Expr.Call(node) -> return on_head?(text, node.span, offset)
    Ast.Expr.EnumConstructor(node) -> return on_head?(text, node.span, offset)
    Ast.Expr.Construct(node) -> return on_head?(text, node.span, offset)
    _ -> return false
  end
end

# Whether `offset` is in the name that a call, a construction or a variant starts with (`Models.total(x)`).
def on_head?(text: String, span: Source.Span, offset: Int) -> Bool
  start = span.start.offset
  size = span.stop.offset - start
  if size > HEAD_LIMIT
    size = HEAD_LIMIT
  end
  if start < 0 or size <= 0 or start + size > text.length
    return false
  end
  head = 0
  written = text.slice(start, size)
  while head < size and HEAD_CHARS.include?(written.at(head))
    head += 1
  end
  return start <= offset and offset < start + head
end

# The "@N::" prefix of each file that the root file imports under an alias, to that alias, so a type of such a file is
# written `Models.User`, as the root file writes it. Aliases are visited in order, so the first of two aliases for one
# file wins.
def written_prefixes(linked: Linker.Linked) -> Map[String, String]
  written: Map[String, String] = {}
  aliases = linked.modules[0].aliases
  for alias in aliases.keys.sort
    for module in linked.modules
      if module.key == aliases[alias] and module.prefix != "" and !written.has_key?(module.prefix)
        written = written.put(module.prefix, alias)
      end
    end
  end
  return written
end
