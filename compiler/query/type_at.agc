## `agentica type-at` as a stage (docs/future/39-semantic-cli.md, 39.3): a linked and checked program and a position in
## its root file in, the type of the innermost expression there and its definition out, or QUERY-NO-EXPRESSION.
##
## A position must be on a token: a blank between tokens, a comment, the end of a line and anything past the end of the
## text hold no expression, even inside the span of one. A local (a parameter, a binding, a loop variable or a pattern
## name) is answered with its type and a definition at its binding, on a use of the name and on the binding itself. The
## name of a type in an annotation or a type argument (`Point`, `Models.User`, `List`) is answered with the kind
## `type`.

import Model from "../catalog/builtin_model"
import CatalogJson from "../catalog/catalog_json"
import State from "../check/check_state"
import Checker from "../check/checker"
import Diag from "../diagnostics/diagnostic"
import Linker from "../modules/linker"
import Ast from "../syntax/ast"
import Lexer from "../syntax/lexer"
import Source from "../syntax/source"
import T from "../syntax/types"
import At from "at"
import Definitions from "definitions"
import Locals from "locals"
import Position from "query_position"
import Sites from "sites"

# The characters of a name written in front of the parenthesis of a call: a name, a dot between a module and its
# member, and the ? or ! that ends a name.
HEAD_CHARS = Set.new("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.?!".split(""))

# The characters that a type name can start with.
CAPITALS = Set.new("ABCDEFGHIJKLMNOPQRSTUVWXYZ".split(""))

# The longest name a call head is read from, in characters.
HEAD_LIMIT = 128

## What a position is on. `kind` is `builtin` when the position is on the name of a builtin (`split` in
## `xs.split(",")`, `puts`), `type` when it is on the name of a type in an annotation or a type argument, `name` when
## it is on another name (a variable, a function named, the name of a field or method after the dot, the name where a
## local is bound) and `expression` otherwise; `span` is always the whole expression, so on the name of a field access
## it is the whole access, and the name alone on a local or a type (the qualified name for `Models.User`). `text` is
## the source text of `span`, `type` the type as the root file writes it (the written name for a `type` answer), and
## `definition` the declaration of what the expression names, the binding of a local, or the struct, enum or alias of
## a type (none for a builtin type). `builtin` is the catalog row of a `builtin` answer, which has no definition.
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
      token = kind_at(module.text, offset)
      if token == ""
        return nothing(asked, here)
      end

      # A local comes first: on the name of a binding, the innermost expression would be the one around it.
      case Locals.find(module, checked.bound, offset)
        Ast.Optional.Present(local) ->
          if local.local.kind == "discard"
            return nothing(asked, here)
          end

          return Diag.Outcome.Done(local_answer(linked, local))
        Ast.Optional.Absent ->
          # A type is before the expressions: the parameters of a block are inside the block, which holds the position.
          if type_token?(module.text, token, offset)
            found = type_answer(linked, checked, offset)
            if found.size > 0
              return Diag.Outcome.Done(found[0])
            end
          end

          return expression_answer(linked, checked, asked, offset, here)
      end
  end
end

## The "@N::" prefix of each file that the root file imports under an alias, to that alias, so a type of such a file is
## written `Models.User`, as the root file writes it. Aliases are visited in order, so the first of two aliases for one
## file wins. A type that such a file re-exports (`export Models.User`) is written through the alias of the file that
## re-exports it, so the map holds its whole linked name too (`@2::User`), unless the root file imports its own file
## under an alias. When two files re-export the same type, the alphabetically first alias is the one written.
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

  for alias in aliases.keys.sort
    for module in linked.modules
      if module.key == aliases[alias]
        for name in module.reexported.keys.sort
          original = module.reexported[name]
          if !written.has_key?(original) and !written.has_key?(prefix_of(original))
            written = written.put(original, alias)
          end
        end
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

## Whether some token of the text holds the character at `offset`. Line breaks and the end are tokens that hold
## nothing.
export def on_token?(text: String, offset: Int) -> Bool
  return kind_at(text, offset) != ""
end

# The "@N::" in front of a linked name; "" for a name of the root file.
def prefix_of(name: String) -> String
  return name.slice(0, name.length - T.display_name(name).length)
end

# The kind of the token that holds the character at `offset`; "" for none, a line break and the end included.
def kind_at(text: String, offset: Int) -> String
  case Lexer.lex(text)
    Diag.Outcome.Failed(_) -> return ""
    Diag.Outcome.Done(tokens) ->
      for token in tokens
        if token.span.start.offset > offset
          return ""
        elsif token.kind != "NL" and token.kind != "eof" and At.holds?(token.span, offset)
          return token.kind
        end
      end

      return ""
  end
end

# The name of a type that holds the position, as the sites of query/sites.agc list it. The checker has no part in it,
# so a type in a function that failed to check is answered too.
def type_answer(linked: Linker.Linked, checked: Checker.Checked, offset: Int) -> List[Answer]
  module = linked.modules[0]
  sites = Sites.of_types(module, checked, Sites.declared_names(linked.modules))
  case Sites.innermost(sites, offset)
    Ast.Optional.Absent -> return []
    Ast.Optional.Present(site) ->
      text = source_text(module.text, site.reach)
      return [
        Answer(
          kind: "type",
          span: site.reach,
          text: text,
          type: text,
          definition: Definitions.of_name(linked.modules, site.target.name),
          builtin: Ast.Optional.Absent,
        ),
      ]
  end
end

# Whether the token at `offset` may be in the name of a type: a type name, or the dot of `Models.User`, which is
# followed by a name that starts with a capital. The dot of a call (`Models.total`) needs no scan of the sites.
def type_token?(text: String, token: String, offset: Int) -> Bool
  if token == "type-name"
    return true
  end

  return token == "dot" and offset + 1 < text.length and CAPITALS.include?(text.at(offset + 1))
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
