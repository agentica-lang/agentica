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
  definition: Optional[Definitions.Definition]
  builtin: Optional[Model.Builtin]
end

## The answer for `asked`, a position in the root file of `linked` (checked as `checked`), or QUERY-NO-EXPRESSION.
export def answer(linked: Linker.Linked, checked: Checker.Checked, asked: Position.Asked) -> Diag.Outcome[Answer]
  case Position.locate(linked.modules[0].text, asked.line, asked.column)
    Position.Located.Outside(span) -> nothing(asked, span)
    Position.Located.At(offset) -> answer_at(At.focus(linked, offset), checked, asked, offset)
  end
end

## The "@N::" prefix of each file that the root file imports under an alias, to that alias, so a type of such a file is
## written `Models.User`, as the root file writes it. Aliases are visited in order, so the first of two aliases for one
## file wins. A type that such a file re-exports (`export Models.User`) is written through the alias of the file that
## re-exports it, so the map holds its whole linked name too (`@2::User`), unless the root file imports its own file
## under an alias. When two files re-export the same type, the alphabetically first alias is the one written. The first
## module may be a module block (At.focus): its own types are written bare, as it writes them, and those of the other
## blocks of its file through their names (`Counter.Msg`). A block of a file imported under an alias is written through
## both (`Agents.Counter.Msg`), unless the root file names the block itself.
export def written_prefixes(linked: Linker.Linked) -> Map[String, String]
  written: Map[String, String] = {}
  aliases = linked.modules[0].aliases
  here = linked.modules[0].key
  for alias in aliases.keys.sort
    for module in linked.modules
      named = module.key == aliases[alias] and module.key != here
      if named and module.prefix != "" and !written.has_key?(module.prefix)
        written = written.put(module.prefix, alias)
      end
    end
  end

  for alias in aliases.keys.sort
    for module in linked.modules
      inner = module.block != "" and Linker.home_key(module) == aliases[alias]
      if inner and !written.has_key?(module.prefix)
        written = written.put(module.prefix, "#{alias}.#{module.block}")
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

  written
end

## The file of the definition of `answered`; "" when the answer has none.
export def definition_file(answered: Answer) -> String
  case answered.definition
    some(definition) -> definition.file
    none -> ""
  end
end

## Whether some token of the text holds the character at `offset`. Line breaks and the end are tokens that hold
## nothing.
export def on_token?(text: String, offset: Int) -> Bool = kind_at(text, offset) != ""

# The "@N::" in front of a linked name; "" for a name of the root file.
def prefix_of(name: String) -> String = name.slice(0, name.length - T.display_name(name).length)

# The answer at `offset`, a character of the root file; the first module of `linked` is the one that holds it.
def answer_at(
  linked: Linker.Linked,
  checked: Checker.Checked,
  asked: Position.Asked,
  offset: Int,
) -> Diag.Outcome[Answer]
  module = linked.modules[0]
  here = Position.character(offset, asked.line, asked.column)
  token = kind_at(module.text, offset)
  return nothing(asked, here) if token == ""

  # A local comes first: on the name of a binding, the innermost expression would be the one around it.
  case Locals.find(module, checked.bound, offset)
    some(local) ->
      return nothing(asked, here) if local.local.kind == "discard"

      Diag.Outcome.Done(local_answer(linked, local))
    none ->
      # A type is before the expressions: the parameters of a block are inside the block, which holds the position.
      if type_token?(module.text, token, offset)
        found = type_answer(linked, checked, offset)
        return Diag.Outcome.Done(found[0]) if found.size > 0
      end

      expression_answer(linked, checked, asked, offset, here)
  end
end

# The kind of the token that holds the character at `offset`; "" for none, a line break and the end included.
def kind_at(text: String, offset: Int) -> String
  case Lexer.lex(text)
    Diag.Outcome.Failed(_) -> ""
    Diag.Outcome.Done(tokens) ->
      for token in tokens
        if token.span.start.offset > offset
          return ""
        elsif token.kind != "NL" and token.kind != "eof" and At.holds?(token.span, offset)
          return token.kind
        end
      end

      ""
  end
end

# The name of a type that holds the position, as the sites of query/sites.agc list it. The checker has no part in it,
# so a type in a function that failed to check is answered too.
def type_answer(linked: Linker.Linked, checked: Checker.Checked, offset: Int) -> List[Answer]
  module = linked.modules[0]
  sites = Sites.of_types(module, checked, Sites.declared_names(linked.modules))
  case Sites.innermost(sites, offset)
    none -> []
    some(site) ->
      text = source_text(module.text, site.reach)
      [
        Answer(
          kind: "type",
          span: site.reach,
          text: text,
          type: text,
          definition: Definitions.of_name(linked.modules, site.target.name),
          builtin: none,
        ),
      ]
  end
end

# Whether the token at `offset` may be in the name of a type: a type name, or the dot of `Models.User`, which is
# followed by a name that starts with a capital. The dot of a call (`Models.total`) needs no scan of the sites.
def type_token?(text: String, token: String, offset: Int) -> Bool
  return true if token == "type-name"

  token == "dot" and offset + 1 < text.length and CAPITALS.include?(text.at(offset + 1))
end

def expression_answer(
  linked: Linker.Linked,
  checked: Checker.Checked,
  asked: Position.Asked,
  offset: Int,
  here: Source.Span,
) -> Diag.Outcome[Answer]
  case At.innermost(linked.modules[0], checked.types, offset)
    none -> nothing(asked, here)
    some(expr) -> Diag.Outcome.Done(found(linked, checked, expr, offset))
  end
end

# A local, on a use or on its binding: `span` is the name there, and the definition is the binding.
def local_answer(linked: Linker.Linked, at: Locals.Found) -> Answer
  module = linked.modules[0]
  type = T.to_text_as(at.local.type, written_prefixes(linked))
  Answer(
    kind: "name",
    span: at.site,
    text: source_text(module.text, at.site),
    type: type,
    definition: some(Definitions.of_local(module, at.local, type)),
    builtin: none,
  )
end

def nothing(asked: Position.Asked, span: Source.Span) -> Diag.Outcome[Answer]
  Diag.Outcome.Failed(Position.no_expression(asked, span))
end

def found(linked: Linker.Linked, checked: Checker.Checked, expr: Ast.Expr, offset: Int) -> Answer
  module = linked.modules[0]
  span = Ast.expr_span(expr)
  definition = Definitions.of_expr(linked.modules, checked.types, checked.resolved, expr)
  kind = "expression"
  builtin: Optional[Model.Builtin] = none
  if on_name?(expr, module.text, offset)
    kind = "name"
    builtin = builtin_of(checked, expr, definition)
  end

  case builtin
    some(_) -> kind = "builtin"
    none -> kind = kind
  end

  Answer(
    kind: kind,
    span: span,
    text: source_text(module.text, span),
    type: T.to_text_as(checked.types[Ast.expr_id(expr)], written_prefixes(linked)),
    definition: definition,
    builtin: builtin,
  )
end

# The public builtin that a call, a method call or a field access that names a method names, or
# `none`. An expression that has a definition names a declaration of the program, never a builtin.
def builtin_of(
  checked: Checker.Checked,
  expr: Ast.Expr,
  definition: Optional[Definitions.Definition],
) -> Optional[Model.Builtin]
  case definition
    some(_) -> none
    none ->
      case expr
        Ast.Expr.Call(node) -> public(node.name)
        Ast.Expr.MethodCall(node) -> resolved(checked, node.id)
        Ast.Expr.FieldAccess(node) -> resolved(checked, node.id)
        _ -> none
      end
  end
end

# The builtin that the checker resolved the method call or field access `id` to. `to_s`, `inspect` and a receiver
# that stays as it is resolve to no catalog row.
def resolved(checked: Checker.Checked, id: Int) -> Optional[Model.Builtin]
  found = checked.resolved.get(id)
  return none if found.none?

  case found.unwrap!
    State.Resolved.Call(name, _) -> public(name)
    _ -> none
  end
end

def public(name: String) -> Optional[Model.Builtin]
  entry = CatalogJson.public(name)
  return some(entry.unwrap!) if entry.ok?

  none
end

# The text of a span; empty when the span does not lie in the text.
def source_text(text: String, span: Source.Span) -> String
  size = span.stop.offset - span.start.offset
  return "" if span.start.offset < 0 or size < 0 or span.stop.offset > text.length

  text.slice(span.start.offset, size)
end

# Whether the position is on a name: an expression that is a name, or the name part of one that has a name in it.
def on_name?(expr: Ast.Expr, text: String, offset: Int) -> Bool
  case expr
    Ast.Expr.Name(_) -> true
    Ast.Expr.ConstRef(_) -> true
    Ast.Expr.TypeName(_) -> true
    Ast.Expr.FunctionRef(_) -> true
    Ast.Expr.FieldAccess(node) -> At.holds?(node.name_span, offset)
    Ast.Expr.MethodCall(node) -> At.holds?(node.name_span, offset)
    Ast.Expr.Call(node) -> on_head?(text, node.span, offset)
    Ast.Expr.EnumConstructor(node) -> on_head?(text, node.span, offset)
    Ast.Expr.Construct(node) -> on_head?(text, node.span, offset)
    _ -> false
  end
end

# Whether `offset` is in the name that a call, a construction or a variant starts with (`Models.total(x)`).
def on_head?(text: String, span: Source.Span, offset: Int) -> Bool
  start = span.start.offset
  size = span.stop.offset - start
  if size > HEAD_LIMIT
    size = HEAD_LIMIT
  end

  return false if start < 0 or size <= 0 or start + size > text.length

  head = 0
  written = text.slice(start, size)
  while head < size and HEAD_CHARS.include?(written.at(head))
    head += 1
  end

  start <= offset and offset < start + head
end
