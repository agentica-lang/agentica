## The text form of a parse, for tests. See parse_text.

import "ast" as Ast
import "diagnostic" as Diag
import "lexer" as Lexer
import "parser" as Parser
import "source" as Source
import "text" as Text

## The text form of a parse and the first node id the next file can use (first_id again when the parse failed).
export struct Printed
  text: String
  next_id: Int
end

## Lexes and parses a file and returns the text form of the tree, or the ERROR line of the first diagnostic. One node per line: `role: kind #id span attributes`, children indented by two spaces. tests/frontend-parser-common.rkt prints the same text from the Racket tree.
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
        Diag.Outcome.Done(program) -> return Printed(text: print_program(program).join("\n"), next_id: Ast.next_free_id(program))
      end
  end
end

# The first line of a node. The root has no role.
def head(indent: String, role: String, kind: String, id: Int, span: Source.Span, attrs: String) -> String
  label = ""
  if role != ""
    label = role + ": "
  end
  return indent + label + kind + " #" + id.to_s + " " + Text.span_text(span) + attrs
end

def doc_attr(doc: Ast.Optional[String]) -> String
  return text_attr(" doc=", doc)
end

def text_attr(label: String, doc: Ast.Optional[String]) -> String
  case doc
    Ast.Optional.Present(text) -> return label + Text.quote(text)
    Ast.Optional.Absent -> return ""
  end
end

def name_attr(name: String) -> String
  return " name=" + Text.quote(name)
end

def value_text(value: Ast.LitValue) -> String
  case value
    Ast.LitValue.Whole(number) -> return "int:" + number.to_s
    Ast.LitValue.Huge(digits) -> return "int:" + digits
    Ast.LitValue.Real(number) -> return "float:bits:" + Float.to_bits(number).to_s
    Ast.LitValue.Text(text) -> return "string:" + Text.quote(text)
    Ast.LitValue.Flag(flag) -> return "bool:" + flag.to_s
    Ast.LitValue.Nothing -> return "nil"
  end
end

def list_text(items: List[String]) -> String
  return "[" + items.join(",") + "]"
end

def print_type(out: List[String], indent: String, role: String, type: Ast.TypeRef) -> List[String]
  lines = out.push(head(indent, role, "type-ref", type.id, type.span, name_attr(type.name)))
  return print_types(lines, indent + "  ", "arg", type.args)
end

def print_types(out: List[String], indent: String, role: String, types: List[Ast.TypeRef]) -> List[String]
  lines = out
  for type in types
    lines = print_type(lines, indent, role, type)
  end
  return lines
end

def print_optional_type(out: List[String], indent: String, role: String, type: Ast.Optional[Ast.TypeRef]) -> List[String]
  case type
    Ast.Optional.Present(found) -> return print_type(out, indent, role, found)
    Ast.Optional.Absent -> return out
  end
end

def print_exprs(out: List[String], indent: String, role: String, items: List[Ast.Expr]) -> List[String]
  lines = out
  for item in items
    lines = print_expr(lines, indent, role, item)
  end
  return lines
end

def print_stmts(out: List[String], indent: String, role: String, items: List[Ast.Stmt]) -> List[String]
  lines = out
  for item in items
    lines = print_stmt(lines, indent, role, item)
  end
  return lines
end

def print_named_args(out: List[String], indent: String, items: List[Ast.NamedArg]) -> List[String]
  lines = out
  for item in items
    lines = out_named(lines, indent, item)
  end
  return lines
end

def out_named(out: List[String], indent: String, item: Ast.NamedArg) -> List[String]
  lines = out.push(head(indent, "arg", "named-arg", item.id, item.span, name_attr(item.name)))
  return print_expr(lines, indent + "  ", "value", item.value)
end

def print_part(out: List[String], indent: String, part: Ast.Part) -> List[String]
  case part
    Ast.Part.Text(text) -> return out.push(indent + "part: text " + Text.quote(text))
    Ast.Part.Code(code) -> return print_expr(out, indent, "part", code)
  end
end

def print_block_param(out: List[String], indent: String, param: Ast.BlockParam) -> List[String]
  lines = out.push(head(indent, "param", "block-param", param.id, param.span, name_attr(param.name)))
  return print_optional_type(lines, indent + "  ", "type", param.type)
end

def print_map_entry(out: List[String], indent: String, entry: Ast.MapEntry) -> List[String]
  lines = out.push(head(indent, "entry", "map-entry", entry.id, entry.span, ""))
  lines = print_expr(lines, indent + "  ", "key", entry.key)
  return print_expr(lines, indent + "  ", "value", entry.value)
end

def op_attrs(op: String, op_span: Source.Span) -> String
  return " op=" + op + " op-span=" + Text.span_text(op_span)
end

def print_call_like(out: List[String], indent: String, role: String, kind: String, id: Int, span: Source.Span, attrs: String, args: List[Ast.Expr]) -> List[String]
  lines = out.push(head(indent, role, kind, id, span, attrs))
  return print_exprs(lines, indent + "  ", "arg", args)
end

def print_expr(out: List[String], indent: String, role: String, expr: Ast.Expr) -> List[String]
  child = indent + "  "
  case expr
    Ast.Expr.Literal(node) -> return out.push(head(indent, role, "literal", node.id, node.span, " value=" + value_text(node.value)))
    Ast.Expr.Name(node) -> return out.push(head(indent, role, "name-ref", node.id, node.span, name_attr(node.name)))
    Ast.Expr.TypeName(node) -> return out.push(head(indent, role, "type-expression", node.id, node.span, name_attr(node.name)))
    Ast.Expr.FunctionRef(node) -> return out.push(head(indent, role, "function-ref", node.id, node.span, name_attr(node.name)))
    Ast.Expr.Call(node) -> return print_call_like(out, indent, role, "call", node.id, node.span, name_attr(node.name) + " piped=" + node.piped.to_s, node.args)
    Ast.Expr.EnumConstructor(node) -> return print_call_like(out, indent, role, "enum-constructor", node.id, node.span, " enum=" + Text.quote(node.enum_name) + " variant=" + Text.quote(node.variant_name), node.args)
    Ast.Expr.Invoke(node) ->
      lines = out.push(head(indent, role, "invoke", node.id, node.span, ""))
      lines = print_expr(lines, child, "target", node.target)
      return print_exprs(lines, child, "arg", node.args)
    Ast.Expr.Construct(node) ->
      lines = out.push(head(indent, role, "construct", node.id, node.span, " type=" + Text.quote(node.type_name)))
      return print_named_args(lines, child, node.args)
    Ast.Expr.ListLit(node) ->
      lines = out.push(head(indent, role, "list-lit", node.id, node.span, ""))
      return print_exprs(lines, child, "element", node.elements)
    Ast.Expr.MapLit(node) ->
      lines = out.push(head(indent, role, "map-lit", node.id, node.span, ""))
      for entry in node.entries
        lines = print_map_entry(lines, child, entry)
      end
      return lines
    Ast.Expr.FieldAccess(node) ->
      lines = out.push(head(indent, role, "field-access", node.id, node.span, name_attr(node.name)))
      return print_expr(lines, child, "target", node.target)
    Ast.Expr.MethodCall(node) ->
      lines = out.push(head(indent, role, "method-call", node.id, node.span, name_attr(node.name)))
      lines = print_expr(lines, child, "target", node.target)
      return print_exprs(lines, child, "arg", node.args)
    Ast.Expr.Interpolation(node) ->
      lines = out.push(head(indent, role, "interpolation", node.id, node.span, ""))
      for part in node.parts
        lines = print_part(lines, child, part)
      end
      return lines
    Ast.Expr.BlockLit(node) ->
      lines = out.push(head(indent, role, "block-lit", node.id, node.span, ""))
      for param in node.params
        lines = print_block_param(lines, child, param)
      end
      return print_stmts(lines, child, "body", node.body)
    Ast.Expr.Index(node) ->
      lines = out.push(head(indent, role, "index-access", node.id, node.span, ""))
      lines = print_expr(lines, child, "target", node.target)
      return print_expr(lines, child, "index", node.index)
    Ast.Expr.Try(node) ->
      lines = out.push(head(indent, role, "try-expr", node.id, node.span, ""))
      return print_expr(lines, child, "operand", node.operand)
    Ast.Expr.Unary(node) ->
      lines = out.push(head(indent, role, "unary", node.id, node.span, op_attrs(node.op, node.op_span)))
      return print_expr(lines, child, "operand", node.operand)
    Ast.Expr.Binary(node) ->
      lines = out.push(head(indent, role, "binary", node.id, node.span, op_attrs(node.op, node.op_span)))
      lines = print_expr(lines, child, "left", node.left)
      return print_expr(lines, child, "right", node.right)
  end
end

def print_pattern(out: List[String], indent: String, role: String, pattern: Ast.Pattern) -> List[String]
  case pattern
    Ast.Pattern.Wildcard(node) -> return out.push(head(indent, role, "wildcard-pattern", node.id, node.span, ""))
    Ast.Pattern.Literal(node) -> return out.push(head(indent, role, "literal-pattern", node.id, node.span, " value=" + value_text(node.value)))
    Ast.Pattern.Variant(node) ->
      names = node.bindings.map do |binding| binding_text(binding) end
      return out.push(head(indent, role, "variant-pattern", node.id, node.span, " enum=" + Text.quote(node.enum_name) + " variant=" + Text.quote(node.variant_name) + " bindings=" + list_text(names)))
  end
end

def binding_text(binding: Ast.Optional[String]) -> String
  case binding
    Ast.Optional.Present(name) -> return Text.quote(name)
    Ast.Optional.Absent -> return "-"
  end
end

def print_branch(out: List[String], indent: String, branch: Ast.IfBranch) -> List[String]
  lines = out.push(head(indent, "branch", "if-branch", branch.id, branch.span, ""))
  lines = print_expr(lines, indent + "  ", "condition", branch.condition)
  return print_stmts(lines, indent + "  ", "body", branch.body)
end

def print_arm(out: List[String], indent: String, arm: Ast.CaseArm) -> List[String]
  lines = out.push(head(indent, "arm", "case-arm", arm.id, arm.span, ""))
  lines = print_pattern(lines, indent + "  ", "pattern", arm.pattern)
  return print_stmts(lines, indent + "  ", "body", arm.body)
end

def print_stmt(out: List[String], indent: String, role: String, stmt: Ast.Stmt) -> List[String]
  child = indent + "  "
  case stmt
    Ast.Stmt.Binding(node) ->
      lines = out.push(head(indent, role, "binding", node.id, node.span, name_attr(node.name)))
      lines = print_optional_type(lines, child, "type", node.type)
      return print_expr(lines, child, "value", node.value)
    Ast.Stmt.Return(node) ->
      lines = out.push(head(indent, role, "return-stmt", node.id, node.span, ""))
      case node.value
        Ast.Optional.Present(value) -> return print_expr(lines, child, "value", value)
        Ast.Optional.Absent -> return lines
      end
    Ast.Stmt.Expression(node) ->
      lines = out.push(head(indent, role, "expr-stmt", node.id, node.span, ""))
      return print_expr(lines, child, "value", node.value)
    Ast.Stmt.If(node) ->
      lines = out.push(head(indent, role, "if-stmt", node.id, node.span, ""))
      for branch in node.branches
        lines = print_branch(lines, child, branch)
      end
      case node.else_body
        Ast.Optional.Present(body) ->
          lines = lines.push(child + "else:")
          return print_stmts(lines, child + "  ", "body", body)
        Ast.Optional.Absent -> return lines
      end
    Ast.Stmt.While(node) ->
      lines = out.push(head(indent, role, "while-stmt", node.id, node.span, ""))
      lines = print_expr(lines, child, "condition", node.condition)
      return print_stmts(lines, child, "body", node.body)
    Ast.Stmt.For(node) ->
      lines = out.push(head(indent, role, "for-stmt", node.id, node.span, " variable=" + Text.quote(node.variable)))
      lines = print_expr(lines, child, "iterable", node.iterable)
      return print_stmts(lines, child, "body", node.body)
    Ast.Stmt.Control(node) -> return out.push(head(indent, role, "loop-control", node.id, node.span, " kind=" + node.kind))
    Ast.Stmt.Case(node) ->
      lines = out.push(head(indent, role, "case-stmt", node.id, node.span, ""))
      lines = print_expr(lines, child, "value", node.value)
      for arm in node.arms
        lines = print_arm(lines, child, arm)
      end
      return lines
  end
end

def print_param(out: List[String], indent: String, param: Ast.Param) -> List[String]
  lines = out.push(head(indent, "param", "param", param.id, param.span, name_attr(param.name)))
  return print_type(lines, indent + "  ", "type", param.type)
end

def print_field(out: List[String], indent: String, field: Ast.FieldDecl) -> List[String]
  lines = out.push(head(indent, "field", "field-decl", field.id, field.span, name_attr(field.name) + doc_attr(field.doc)))
  return print_type(lines, indent + "  ", "type", field.type)
end

def print_variant(out: List[String], indent: String, variant: Ast.EnumVariant) -> List[String]
  lines = out.push(head(indent, "variant", "enum-variant", variant.id, variant.span, name_attr(variant.name) + doc_attr(variant.doc)))
  return print_types(lines, indent + "  ", "payload", variant.payload_types)
end

def print_decl(out: List[String], indent: String, role: String, decl: Ast.Decl) -> List[String]
  child = indent + "  "
  case decl
    Ast.Decl.Import(node) -> return out.push(head(indent, role, "import-decl", node.id, node.span, " path=" + Text.quote(node.path) + " alias=" + Text.quote(node.alias)))
    Ast.Decl.Export(node) ->
      lines = out.push(head(indent, role, "export-decl", node.id, node.span, doc_attr(node.doc)))
      return print_decl(lines, child, "declaration", node.declaration)
    Ast.Decl.Function(node) ->
      lines = out.push(head(indent, role, "function-decl", node.id, node.span, name_attr(node.name) + doc_attr(node.doc)))
      for param in node.params
        lines = print_param(lines, child, param)
      end
      lines = print_type(lines, child, "result", node.result)
      return print_stmts(lines, child, "body", node.body)
    Ast.Decl.Struct(node) ->
      lines = out.push(head(indent, role, "struct-decl", node.id, node.span, name_attr(node.name) + doc_attr(node.doc)))
      for field in node.fields
        lines = print_field(lines, child, field)
      end
      return lines
    Ast.Decl.Enum(node) ->
      parameters = node.type_parameters.map do |name| Text.quote(name) end
      lines = out.push(head(indent, role, "enum-decl", node.id, node.span, name_attr(node.name) + " type-parameters=" + list_text(parameters) + doc_attr(node.doc)))
      for variant in node.variants
        lines = print_variant(lines, child, variant)
      end
      return lines
  end
end

def print_program(program: Ast.Program) -> List[String]
  lines: List[String] = [head("", "", "program", program.id, program.span, text_attr(" module-doc=", program.module_doc))]
  for decl in program.declarations
    lines = print_decl(lines, "  ", "declaration", decl)
  end
  return lines
end
