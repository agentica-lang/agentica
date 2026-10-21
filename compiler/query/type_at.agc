## `agentica type-at` as a stage (docs/future/39-semantic-cli.md, 39.3): a linked and checked program and a position in
## its root file in, the type of the innermost expression there and its definition out, or QUERY-NO-EXPRESSION.
##
## A position must be on a token: a blank between tokens, a comment, the end of a line and anything past the end of the
## text hold no expression, even inside the span of one. A local (a parameter, a binding, a loop variable or a pattern
## name) is answered with its type and a definition at its binding, on a use of the name and on the binding itself.

import CatalogJson from "../catalog/catalog_json"
import Checker from "../check/checker"
import Diag from "../diagnostics/diagnostic"
import Linker from "../modules/linker"
import Ast from "../syntax/ast"
import Lexer from "../syntax/lexer"
import Model from "../catalog/builtin_model"
import Source from "../syntax/source"
import State from "../check/check_state"
import T from "../syntax/types"
import At from "at"
import Definitions from "definitions"
import Locals from "locals"
import Position from "query_position"

# The characters of a name written in front of the parenthesis of a call: a name, a dot between a module and its
# member, and the ? or ! that ends a name.
HEAD_CHARS = Set.new("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.?!".split(""))

# The longest name a call head is read from, in characters.
HEAD_LIMIT = 128

## What a position is on. `kind` is `builtin` when the position is on the name of a builtin (`split` in
## `xs.split(",")`, `puts`), `name` when it is on another name (a variable, a function or type named, the name of a
## field or method after the dot, the name where a local is bound) and `expression` otherwise; `span` is always the
## whole expression, so on the name of a field access it is the whole access, and the name alone on a local. `text` is
## the source text of `span`, `type` the type as the root file writes it, and `definition` the declaration of what the
## expression names, or the binding of a local. `builtin` is the catalog row of a `builtin` answer, which has no
## definition.
export struct Answer
  kind: String
  span: Source.Span
  text: String
  type: String
  definition: Ast.Optional[Definitions.Definition]
  builtin: Ast.Optional[Model.Builtin]
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
      # A local comes first: on the name of a binding, the innermost expression would be the one around it.
      case Locals.find(module, checked.bound, offset)
        Ast.Optional.Present(local) ->
          if local.local.kind == "discard"
            return nothing(asked, here)
          end
          return Diag.Outcome.Done(local_answer(linked, local))
        Ast.Optional.Absent -> return expression_answer(linked, checked, asked, offset, here)
      end
  end
end

## The "@N::" prefix of each file that the root file imports under an alias, to that alias, so a type of such a file is
## written `Models.User`, as the root file writes it. Aliases are visited in order, so the first of two aliases for one
## file wins.
export def written_prefixes(linked: Linker.Linked) -> Map[String, String]
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

## The file of the definition of `answered`; "" when the answer has none.
export def definition_file(answered: Answer) -> String
  case answered.definition
    Ast.Optional.Present(definition) -> return definition.file
    Ast.Optional.Absent -> return ""
  end
end

def expression_answer(
  linked: Linker.Linked,
  checked: Checker.Checked,
  asked: Position.Asked,
  offset: Int,
  here: Source.Span,
) -> Diag.Outcome[Answer]
  case At.innermost(linked.modules[0], checked.types, offset)
    Ast.Optional.Absent -> return nothing(asked, here)
    Ast.Optional.Present(expr) -> return Diag.Outcome.Done(found(linked, checked, expr, offset))
  end
end

# A local, on a use or on its binding: `span` is the name there, and the definition is the binding.
def local_answer(linked: Linker.Linked, at: Locals.Found) -> Answer
  module = linked.modules[0]
  type = T.to_text_as(at.local.type, written_prefixes(linked))
  return Answer(
    kind: "name",
    span: at.site,
    text: source_text(module.text, at.site),
    type: type,
    definition: Ast.Optional.Present(Definitions.of_local(module, at.local, type)),
    builtin: Ast.Optional.Absent,
  )
end

def nothing(asked: Position.Asked, span: Source.Span) -> Diag.Outcome[Answer]
  return Diag.Outcome.Failed(Position.no_expression(asked, span))
end

def found(linked: Linker.Linked, checked: Checker.Checked, expr: Ast.Expr, offset: Int) -> Answer
  module = linked.modules[0]
  span = Ast.expr_span(expr)
  definition = Definitions.of_expr(linked.modules, checked.types, expr)
  kind = "expression"
  builtin: Ast.Optional[Model.Builtin] = Ast.Optional.Absent
  if on_name?(expr, module.text, offset)
    kind = "name"
    builtin = builtin_of(checked, expr, definition)
  end
  case builtin
    Ast.Optional.Present(_) -> kind = "builtin"
    Ast.Optional.Absent -> kind = kind
  end
  return Answer(
    kind: kind,
    span: span,
    text: source_text(module.text, span),
    type: T.to_text_as(checked.types[Ast.expr_id(expr)], written_prefixes(linked)),
    definition: definition,
    builtin: builtin,
  )
end

# The public builtin that a call, a method call or a field access that names a method names, or
# Absent. An expression that has a definition names a declaration of the program, never a builtin.
def builtin_of(
  checked: Checker.Checked,
  expr: Ast.Expr,
  definition: Ast.Optional[Definitions.Definition],
) -> Ast.Optional[Model.Builtin]
  case definition
    Ast.Optional.Present(_) -> return Ast.Optional.Absent
    Ast.Optional.Absent ->
      case expr
        Ast.Expr.Call(node) -> return public(node.name)
        Ast.Expr.MethodCall(node) -> return resolved(checked, node.id)
        Ast.Expr.FieldAccess(node) -> return resolved(checked, node.id)
        _ -> return Ast.Optional.Absent
      end
  end
end

# The builtin that the checker resolved the method call or field access `id` to. `to_s`, `inspect` and a receiver
# that stays as it is resolve to no catalog row.
def resolved(checked: Checker.Checked, id: Int) -> Ast.Optional[Model.Builtin]
  found = checked.resolved.get(id)
  if !found.ok?
    return Ast.Optional.Absent
  end
  case found.unwrap!
    State.Resolved.Call(name, _) -> return public(name)
    _ -> return Ast.Optional.Absent
  end
end

def public(name: String) -> Ast.Optional[Model.Builtin]
  entry = CatalogJson.public(name)
  if entry.ok?
    return Ast.Optional.Present(entry.unwrap!)
  end
  return Ast.Optional.Absent
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
    # Not reached yet: no type is recorded for a TypeName (see Definitions.of_expr), so it is never the answer.
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
