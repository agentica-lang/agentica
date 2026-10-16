## The text form of a parse, for tests. See parse_text.

import Ast from "ast"
import Diag from "diagnostic"
import Lexer from "lexer"
import Parser from "parser"
import Source from "source"
import Text from "text"

## The text form of a parse and the first node id the next file can use (first_id again when the parse failed).
export struct Printed
  text: String
  next_id: Int
end

## Where a line is printed: its indent, the number subtracted from every node id, and the text added at the end of the
## line of a node, by the node's id (the checker's text form adds the type of each expression this way). A file of a
## linked program prints ids that start at 0 inside the file, so the text does not depend on which files came before
## it.
export struct Margin
  indent: String
  base: Int
  notes: Map[Int, String]
end

## Lexes and parses a file and returns the text form of the tree, or the ERROR line of the first diagnostic. One node
## per line: `role: kind #id span attributes`, children indented by two spaces. The goldens are in
## tests/fixtures/frontend/parser/.
export def parse_text(text: String) -> String
  return parse_text_from(text, 0)
end

## Like parse_text, with the ids of the nodes starting at first_id.
export def parse_text_from(text: String, first_id: Int) -> String
  return print_from(text, first_id).text
end

## Like parse_text_from, and also gives Ast.next_free_id of the Program, so the next file can continue the numbering.
export def print_from(text: String, first_id: Int) -> Printed
  case Lexer.lex(text)
    Diag.Outcome.Failed(problem) -> return Printed(text: Text.diagnostic_line(problem), next_id: first_id)
    Diag.Outcome.Done(tokens) ->
      case Parser.parse(tokens, first_id)
        Diag.Outcome.Failed(problem) -> return Printed(text: Text.diagnostic_line(problem), next_id: first_id)
        Diag.Outcome.Done(program) -> return Printed(
          text: print_program(program).join("\n"),
          next_id: Ast.next_free_id(program),
        )
      end
  end
end

## The margin one level deeper.
export def deeper(at: Margin) -> Margin
  return at.with(indent: "#{at.indent}  ")
end

## The first line of a node: the indent, the role if there is one (the root has none), the kind, the id relative to the
## margin, the span and the attributes.
export def head(at: Margin, role: String, kind: String, id: Int, span: Source.Span, attrs: String) -> String
  label = ""
  if role != ""
    label = "#{role}: "
  end
  note = at.notes.get(id)
  extra = ""
  if note.ok?
    extra = note.unwrap!
  end
  # "##{...}" writes a literal "#" and then the node number relative to the base, such as: Foo #3 1:1-1:4
  return "#{at.indent}#{label}#{kind} ##{id - at.base} #{Text.span_text(span)}#{attrs}#{extra}"
end

## The label followed by the quoted text of an optional string, or the empty string when it is absent.
export def text_attr(label: String, doc: Ast.Optional[String]) -> String
  case doc
    Ast.Optional.Present(text) -> return label + Text.quote(text)
    Ast.Optional.Absent -> return ""
  end
end

## Prints a declaration and everything under it, one line per node, after the lines already in out.
export def print_decl(out: List[String], at: Margin, role: String, decl: Ast.Decl) -> List[String]
  child = deeper(at)
  case decl
    Ast.Decl.Import(node) -> return out.push(head(at, role, "import-decl", node.id, node.span, import_attrs(node)))
    Ast.Decl.Export(node) ->
      lines = out.push(head(at, role, "export-decl", node.id, node.span, doc_attr(node.doc)))
      return print_decl(lines, child, "declaration", node.declaration)
    Ast.Decl.Function(node) ->
      lines = out.push(head(at, role, "function-decl", node.id, node.span, name_attr(node.name) + doc_attr(node.doc)))
      for param in node.params
        lines = print_param(lines, child, param)
      end
      lines = print_type(lines, child, "result", node.result)
      return print_stmts(lines, child, "body", node.body)
    Ast.Decl.Struct(node) ->
      lines = out.push(head(at, role, "struct-decl", node.id, node.span, name_attr(node.name) + doc_attr(node.doc)))
      for field in node.fields
        lines = print_field(lines, child, field)
      end
      return lines
    Ast.Decl.Constant(node) ->
      exported = ""
      if node.exported
        exported = " exported=true"
      end
      lines = out.push(
        head(at, role, "const-decl", node.id, node.span, name_attr(node.name) + exported + doc_attr(node.doc)),
      )
      lines = print_optional_type(lines, child, "type", node.type)
      return print_expr(lines, child, "value", node.value)
    Ast.Decl.Enum(node) ->
      parameters = node.type_parameters.map do |name| Text.quote(name) end
      lines = out.push(
        head(
          at,
          role,
          "enum-decl",
          node.id,
          node.span,
          "#{name_attr(node.name)} type-parameters=#{list_text(parameters)}#{doc_attr(node.doc)}",
        ),
      )
      for variant in node.variants
        lines = print_variant(lines, child, variant)
      end
      return lines
  end
end

def doc_attr(doc: Ast.Optional[String]) -> String
  return text_attr(" doc=", doc)
end

def name_attr(name: String) -> String
  return " name=#{Text.quote(name)}"
end

def value_text(value: Ast.LitValue) -> String
  case value
    Ast.LitValue.Whole(number) -> return "int:#{number}"
    Ast.LitValue.Huge(digits) -> return "int:#{digits}"
    Ast.LitValue.Real(number) -> return "float:bits:#{Float.to_bits(number)}"
    Ast.LitValue.Text(text) -> return "string:#{Text.quote(text)}"
    Ast.LitValue.Flag(flag) -> return "bool:#{flag}"
    Ast.LitValue.Nothing -> return "nil"
  end
end

def visible_attr(visible: Ast.Optional[List[String]]) -> String
  case visible
    Ast.Optional.Present(names) ->
      quoted = names.map do |name| Text.quote(name) end
      return " visible=#{list_text(quoted)}"
    Ast.Optional.Absent -> return ""
  end
end

def list_text(items: List[String]) -> String
  return "[#{items.join(",")}]"
end

def print_type(out: List[String], at: Margin, role: String, type: Ast.TypeRef) -> List[String]
  lines = out.push(head(at, role, "type-ref", type.id, type.span, name_attr(type.name)))
  return print_types(lines, deeper(at), "arg", type.args)
end

def print_types(out: List[String], at: Margin, role: String, types: List[Ast.TypeRef]) -> List[String]
  lines = out
  for type in types
    lines = print_type(lines, at, role, type)
  end
  return lines
end

def print_optional_type(out: List[String], at: Margin, role: String, type: Ast.Optional[Ast.TypeRef]) -> List[String]
  case type
    Ast.Optional.Present(found) -> return print_type(out, at, role, found)
    Ast.Optional.Absent -> return out
  end
end

def print_exprs(out: List[String], at: Margin, role: String, items: List[Ast.Expr]) -> List[String]
  lines = out
  for item in items
    lines = print_expr(lines, at, role, item)
  end
  return lines
end

def print_stmts(out: List[String], at: Margin, role: String, items: List[Ast.Stmt]) -> List[String]
  lines = out
  for item in items
    lines = print_stmt(lines, at, role, item)
  end
  return lines
end

def print_named_args(out: List[String], at: Margin, items: List[Ast.NamedArg]) -> List[String]
  lines = out
  for item in items
    lines = out_named(lines, at, item)
  end
  return lines
end

def out_named(out: List[String], at: Margin, item: Ast.NamedArg) -> List[String]
  lines = out.push(head(at, "arg", "named-arg", item.id, item.span, name_attr(item.name)))
  return print_expr(lines, deeper(at), "value", item.value)
end

def print_part(out: List[String], at: Margin, part: Ast.Part) -> List[String]
  case part
    Ast.Part.Text(text) -> return out.push("#{at.indent}part: text #{Text.quote(text)}")
    Ast.Part.Code(code) -> return print_expr(out, at, "part", code)
  end
end

def print_block_param(out: List[String], at: Margin, param: Ast.BlockParam) -> List[String]
  lines = out.push(head(at, "param", "block-param", param.id, param.span, name_attr(param.name)))
  return print_optional_type(lines, deeper(at), "type", param.type)
end

def print_map_entry(out: List[String], at: Margin, entry: Ast.MapEntry) -> List[String]
  lines = out.push(head(at, "entry", "map-entry", entry.id, entry.span, ""))
  lines = print_expr(lines, deeper(at), "key", entry.key)
  return print_expr(lines, deeper(at), "value", entry.value)
end

def op_attrs(op: String, op_span: Source.Span) -> String
  return " op=#{op} op-span=#{Text.span_text(op_span)}"
end

def print_call_like(
  out: List[String],
  at: Margin,
  role: String,
  kind: String,
  id: Int,
  span: Source.Span,
  attrs: String,
  args: List[Ast.Expr],
) -> List[String]
  lines = out.push(head(at, role, kind, id, span, attrs))
  return print_exprs(lines, deeper(at), "arg", args)
end

def print_expr(out: List[String], at: Margin, role: String, expr: Ast.Expr) -> List[String]
  child = deeper(at)
  case expr
    Ast.Expr.Literal(node) -> return out.push(
      head(at, role, "literal", node.id, node.span, " value=#{value_text(node.value)}"),
    )
    Ast.Expr.Name(node) -> return out.push(head(at, role, "name-ref", node.id, node.span, name_attr(node.name)))
    Ast.Expr.TypeName(node) -> return out.push(
      head(at, role, "type-expression", node.id, node.span, name_attr(node.name)),
    )
    Ast.Expr.ConstRef(node) -> return out.push(head(at, role, "const-ref", node.id, node.span, name_attr(node.name)))
    Ast.Expr.FunctionRef(node) -> return out.push(
      head(at, role, "function-ref", node.id, node.span, name_attr(node.name)),
    )
    Ast.Expr.Call(node) -> return print_call_like(
      out,
      at,
      role,
      "call",
      node.id,
      node.span,
      "#{name_attr(node.name)} piped=#{node.piped}",
      node.args,
    )
    Ast.Expr.EnumConstructor(node) ->
      lines = print_call_like(
        out,
        at,
        role,
        "enum-constructor",
        node.id,
        node.span,
        " enum=#{Text.quote(node.enum_name)} variant=#{Text.quote(node.variant_name)}",
        node.args,
      )
      return print_named_args(lines, child, node.named)
    Ast.Expr.Invoke(node) ->
      lines = out.push(head(at, role, "invoke", node.id, node.span, ""))
      lines = print_expr(lines, child, "target", node.target)
      return print_exprs(lines, child, "arg", node.args)
    Ast.Expr.Construct(node) ->
      lines = out.push(head(at, role, "construct", node.id, node.span, " type=#{Text.quote(node.type_name)}"))
      return print_named_args(lines, child, node.args)
    Ast.Expr.Update(node) ->
      lines = out.push(head(at, role, "struct-update", node.id, node.span, visible_attr(node.visible)))
      lines = print_expr(lines, child, "target", node.target)
      return print_named_args(lines, child, node.args)
    _ -> return print_container_expr(out, at, role, expr)
  end
end

def print_container_expr(out: List[String], at: Margin, role: String, expr: Ast.Expr) -> List[String]
  child = deeper(at)
  case expr
    Ast.Expr.ListLit(node) ->
      lines = out.push(head(at, role, "list-lit", node.id, node.span, ""))
      return print_exprs(lines, child, "element", node.elements)
    Ast.Expr.MapLit(node) ->
      lines = out.push(head(at, role, "map-lit", node.id, node.span, ""))
      for entry in node.entries
        lines = print_map_entry(lines, child, entry)
      end
      return lines
    Ast.Expr.FieldAccess(node) ->
      lines = out.push(head(at, role, "field-access", node.id, node.span, name_attr(node.name)))
      return print_expr(lines, child, "target", node.target)
    Ast.Expr.MethodCall(node) ->
      lines = out.push(head(at, role, "method-call", node.id, node.span, name_attr(node.name)))
      lines = print_expr(lines, child, "target", node.target)
      return print_exprs(lines, child, "arg", node.args)
    Ast.Expr.Interpolation(node) ->
      lines = out.push(head(at, role, "interpolation", node.id, node.span, ""))
      for part in node.parts
        lines = print_part(lines, child, part)
      end
      return lines
    Ast.Expr.BlockLit(node) ->
      lines = out.push(head(at, role, "block-lit", node.id, node.span, ""))
      for param in node.params
        lines = print_block_param(lines, child, param)
      end
      return print_stmts(lines, child, "body", node.body)
    Ast.Expr.Index(node) ->
      lines = out.push(head(at, role, "index-access", node.id, node.span, ""))
      lines = print_expr(lines, child, "target", node.target)
      return print_expr(lines, child, "index", node.index)
    Ast.Expr.Try(node) ->
      lines = out.push(head(at, role, "try-expr", node.id, node.span, ""))
      return print_expr(lines, child, "operand", node.operand)
    Ast.Expr.Unary(node) ->
      lines = out.push(head(at, role, "unary", node.id, node.span, op_attrs(node.op, node.op_span)))
      return print_expr(lines, child, "operand", node.operand)
    Ast.Expr.Binary(node) ->
      lines = out.push(head(at, role, "binary", node.id, node.span, op_attrs(node.op, node.op_span)))
      lines = print_expr(lines, child, "left", node.left)
      return print_expr(lines, child, "right", node.right)
    # print_expr handles every other variant before it calls this one.
    _ -> return out
  end
end

def print_pattern(out: List[String], at: Margin, role: String, pattern: Ast.Pattern) -> List[String]
  case pattern
    Ast.Pattern.Wildcard(node) -> return out.push(head(at, role, "wildcard-pattern", node.id, node.span, ""))
    Ast.Pattern.Literal(node) -> return out.push(
      head(at, role, "literal-pattern", node.id, node.span, " value=#{value_text(node.value)}"),
    )
    Ast.Pattern.Variant(node) ->
      names = node.bindings.map do |binding| binding_text(binding) end
      return out.push(
        head(
          at,
          role,
          "variant-pattern",
          node.id,
          node.span,
          " enum=#{Text.quote(node.enum_name)} variant=#{Text.quote(node.variant_name)} bindings=#{list_text(names)}",
        ),
      )
  end
end

def binding_text(binding: Ast.Optional[String]) -> String
  case binding
    Ast.Optional.Present(name) -> return Text.quote(name)
    Ast.Optional.Absent -> return "-"
  end
end

def print_branch(out: List[String], at: Margin, branch: Ast.IfBranch) -> List[String]
  lines = out.push(head(at, "branch", "if-branch", branch.id, branch.span, ""))
  lines = print_expr(lines, deeper(at), "condition", branch.condition)
  return print_stmts(lines, deeper(at), "body", branch.body)
end

def print_arm(out: List[String], at: Margin, arm: Ast.CaseArm) -> List[String]
  lines = out.push(head(at, "arm", "case-arm", arm.id, arm.span, ""))
  lines = print_pattern(lines, deeper(at), "pattern", arm.pattern)
  return print_stmts(lines, deeper(at), "body", arm.body)
end

def print_stmt(out: List[String], at: Margin, role: String, stmt: Ast.Stmt) -> List[String]
  child = deeper(at)
  case stmt
    Ast.Stmt.Binding(node) ->
      lines = out.push(head(at, role, "binding", node.id, node.span, name_attr(node.name)))
      lines = print_optional_type(lines, child, "type", node.type)
      return print_expr(lines, child, "value", node.value)
    Ast.Stmt.Return(node) ->
      lines = out.push(head(at, role, "return-stmt", node.id, node.span, ""))
      case node.value
        Ast.Optional.Present(value) -> return print_expr(lines, child, "value", value)
        Ast.Optional.Absent -> return lines
      end
    Ast.Stmt.Expression(node) ->
      lines = out.push(head(at, role, "expr-stmt", node.id, node.span, ""))
      return print_expr(lines, child, "value", node.value)
    Ast.Stmt.If(node) ->
      lines = out.push(head(at, role, "if-stmt", node.id, node.span, ""))
      for branch in node.branches
        lines = print_branch(lines, child, branch)
      end
      case node.else_body
        Ast.Optional.Present(body) ->
          lines = lines.push("#{child.indent}else:")
          return print_stmts(lines, deeper(child), "body", body)
        Ast.Optional.Absent -> return lines
      end
    Ast.Stmt.While(node) ->
      lines = out.push(head(at, role, "while-stmt", node.id, node.span, ""))
      lines = print_expr(lines, child, "condition", node.condition)
      return print_stmts(lines, child, "body", node.body)
    Ast.Stmt.For(node) ->
      lines = out.push(head(at, role, "for-stmt", node.id, node.span, " variable=#{Text.quote(node.variable)}"))
      lines = print_expr(lines, child, "iterable", node.iterable)
      return print_stmts(lines, child, "body", node.body)
    Ast.Stmt.Control(node) -> return out.push(head(at, role, "loop-control", node.id, node.span, " kind=#{node.kind}"))
    Ast.Stmt.Case(node) ->
      lines = out.push(head(at, role, "case-stmt", node.id, node.span, ""))
      lines = print_expr(lines, child, "value", node.value)
      for arm in node.arms
        lines = print_arm(lines, child, arm)
      end
      return lines
  end
end

def print_param(out: List[String], at: Margin, param: Ast.Param) -> List[String]
  lines = out.push(head(at, "param", "param", param.id, param.span, name_attr(param.name)))
  lines = print_type(lines, deeper(at), "type", param.type)
  case param.default
    Ast.Optional.Present(value) -> return print_expr(lines, deeper(at), "default", value)
    Ast.Optional.Absent -> return lines
  end
end

def print_field(out: List[String], at: Margin, field: Ast.FieldDecl) -> List[String]
  lines = out.push(head(at, "field", "field-decl", field.id, field.span, name_attr(field.name) + doc_attr(field.doc)))
  return print_type(lines, deeper(at), "type", field.type)
end

def print_variant(out: List[String], at: Margin, variant: Ast.EnumVariant) -> List[String]
  lines = out.push(
    head(at, "variant", "enum-variant", variant.id, variant.span, name_attr(variant.name) + doc_attr(variant.doc)),
  )
  return print_types(lines, deeper(at), "payload", variant.payload_types)
end

def print_program(program: Ast.Program) -> List[String]
  lines: List[String] = [
    head(
      Margin(indent: "", base: 0, notes: {}),
      "",
      "program",
      program.id,
      program.span,
      text_attr(" module-doc=", program.module_doc),
    ),
  ]
  for decl in program.declarations
    lines = print_decl(lines, Margin(indent: "  ", base: 0, notes: {}), "declaration", decl)
  end
  return lines
end

# ` path="x" alias="Mod"`, or ` path="x" names=[...]` with each name and its span, and `as` with the local name for a
# rename.
def import_attrs(node: Ast.ImportDecl) -> String
  case node.alias
    Ast.Optional.Present(alias) -> return " path=#{Text.quote(node.path)} alias=#{Text.quote(alias)}"
    Ast.Optional.Absent ->
      texts = node.names.map do |entry| import_name_text(entry) end
      return " path=#{Text.quote(node.path)} names=[#{texts.join(",")}]"
  end
end

def import_name_text(entry: Ast.ImportName) -> String
  text = "#{Text.quote(entry.name)}@#{Text.span_text(entry.span)}"
  if entry.local != entry.name
    text += " as #{Text.quote(entry.local)}@#{Text.span_text(entry.local_span)}"
  end
  return text
end
