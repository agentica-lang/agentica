## The text form of a parse, for tests. See parse_text.

import Diag from "../diagnostics/diagnostic"
import Ast from "ast"
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
export def parse_text(text: String) -> String = parse_text_from(text, 0)

## Like parse_text, with the ids of the nodes starting at first_id.
export def parse_text_from(text: String, first_id: Int) -> String = print_from(text, first_id).text

## Like parse_text_from, and also gives Ast.next_free_id of the Program, so the next file can continue the numbering.
export def print_from(text: String, first_id: Int) -> Printed
  case Lexer.lex(text)
    Diag.Outcome.Failed(problem) -> Printed(text: Text.diagnostic_line(problem), next_id: first_id)
    Diag.Outcome.Done(tokens) ->
      case Parser.parse(tokens, first_id)
        Diag.Outcome.Failed(problem) -> Printed(text: Text.diagnostic_line(problem), next_id: first_id)
        Diag.Outcome.Done(program) ->
          Printed(text: print_program(program).join("\n"), next_id: Ast.next_free_id(program))
      end
  end
end

## The margin one level deeper.
export def deeper(at: Margin) -> Margin = at.with(indent: "#{at.indent}  ")

## The first line of a node: the indent, the role if there is one (the root has none), the kind, the id relative to the
## margin, the span and the attributes.
export def head(at: Margin, role: String, kind: String, id: Int, span: Source.Span, attrs: String) -> String
  label = ""
  if role != ""
    label = "#{role}: "
  end

  note = at.notes.get(id)
  extra = ""
  if note.some?
    extra = note.unwrap!
  end

  # "##{...}" writes a literal "#" and then the node number relative to the base, such as: Foo #3 1:1-1:4
  "#{at.indent}#{label}#{kind} ##{id - at.base} #{Text.span_text(span)}#{attrs}#{extra}"
end

## The label followed by the quoted text of an optional string, or the empty string when it is absent.
export def text_attr(label: String, doc: Optional[String]) -> String
  case doc
    some(text) -> label + Text.quote(text)
    none -> ""
  end
end

## The text form of a parsed tree, one line per node: `role: kind #id span attributes`, children indented by two
## spaces.
export def print_program(program: Ast.Program) -> List[String]
  lines: List[String] = [
    head(
      Margin(indent: "", base: 0, notes: {}),
      "",
      "program",
      program.id,
      program.span,
      text_attr(" module-doc=", program.module_doc) + private_attr(program.private_mark),
    ),
  ]

  for decl in program.declarations
    lines = print_decl(lines, Margin(indent: "  ", base: 0, notes: {}), "declaration", decl)
  end

  lines
end

## Prints a declaration and everything under it, one line per node, after the lines already in out.
export def print_decl(out: List[String], at: Margin, role: String, decl: Ast.Decl) -> List[String]
  child = deeper(at)
  case decl
    Ast.Decl.Import(node) -> out.push(head(at, role, "import-decl", node.id, node.span, import_attrs(node)))
    Ast.Decl.Reexport(node) ->
      attrs = " alias=#{Text.quote(node.alias)} name=#{Text.quote(node.name)}"
      out.push(head(at, role, "reexport-decl", node.id, node.span, attrs))
    Ast.Decl.Export(node) ->
      lines = out.push(head(at, role, "export-decl", node.id, node.span, doc_attr(node.doc)))
      print_decl(lines, child, "declaration", node.declaration)
    Ast.Decl.Module(node) ->
      lines = out.push(head(at, role, "module-decl", node.id, node.span, module_attrs(node)))
      for inner in node.declarations
        lines = print_decl(lines, child, "declaration", inner)
      end

      lines
    Ast.Decl.Function(node) ->
      attrs = name_attr(node.name)
      if node.type_parameters.size > 0
        parameters = node.type_parameters.map do |name| Text.quote(name) end
        attrs += " type-parameters=#{list_text(parameters)}"
      end

      attrs += doc_attr(node.doc) + native_attr(node.name, node.native)
      if node.expression
        attrs += " expression"
      end

      lines = out.push(head(at, role, "function-decl", node.id, node.span, attrs))
      for param in node.params
        lines = print_param(lines, child, param)
      end

      lines = print_type(lines, child, "result", node.result)
      print_stmts(lines, child, "body", node.body)
    Ast.Decl.Struct(node) ->
      attrs = name_attr(node.name)
      if node.type_parameters.size > 0
        parameters = node.type_parameters.map do |name| Text.quote(name) end
        attrs += " type-parameters=#{list_text(parameters)}"
      end

      attrs += doc_attr(node.doc)
      if node.record_of != ""
        attrs += " record-of=#{Text.quote(node.record_of)}"
      end

      if node.layout != ""
        attrs += " layout=#{Text.quote(node.layout)}"
      end

      attrs += private_attr(node.private_mark)
      lines = out.push(head(at, role, "struct-decl", node.id, node.span, attrs))
      for field in node.fields
        lines = print_field(lines, child, field)
      end

      lines
    Ast.Decl.Constant(node) ->
      exported = ""
      if node.exported
        exported = " exported=true"
      end

      lines = out.push(
        head(at, role, "const-decl", node.id, node.span, name_attr(node.name) + exported + doc_attr(node.doc)),
      )

      lines = print_optional_type(lines, child, "type", node.type)
      print_expr(lines, child, "value", node.value)
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

      lines
    Ast.Decl.Resource(node) ->
      attrs = "#{name_attr(node.name)} free=#{Text.quote(node.free)}"
      if node.by_ref
        attrs += " by_ref=true"
      end

      if node.module != ""
        attrs += " module=#{Text.quote(node.module)}"
      end

      case node.callback
        some(callback) ->
          attrs = "#{name_attr(node.name)} codes=#{Text.quote(callback.codes)}#{doc_attr(node.doc)}"
          lines = out.push(head(at, role, "callback-decl", node.id, node.span, attrs))
          for param in callback.params
            lines = print_param(lines, deeper(at), param)
          end

          return print_type(lines, deeper(at), "result", callback.result)
        none -> attrs += doc_attr(node.doc)
      end

      out.push(head(at, role, "resource-decl", node.id, node.span, attrs))
    Ast.Decl.TypeAlias(node) ->
      attrs = name_attr(node.name)
      if node.type_parameters.size > 0
        parameters = node.type_parameters.map do |name| Text.quote(name) end
        attrs += " type-parameters=#{list_text(parameters)}"
      end

      lines = out.push(head(at, role, "type-alias-decl", node.id, node.span, attrs + doc_attr(node.doc)))
      print_type(lines, child, "target", node.target)
  end
end

# ` private-at=N` for a scope with a `private` line before its declaration number N, "" for one without.
def private_attr(mark: Optional[Ast.PrivateMark]) -> String
  case mark
    some(found) -> " private-at=#{found.index}"
    none -> ""
  end
end

def module_attrs(node: Ast.ModuleDecl) -> String
  name_attr(node.name) + doc_attr(node.doc) + private_attr(node.private_mark)
end

def doc_attr(doc: Optional[String]) -> String = text_attr(" doc=", doc)

# The library and the C type codes of an extern function, its C name when it is not the def's name, compute=true for
# a compute def, module=true for a function of a native module, the resource and its free function for one that returns
# a resource, and each out resource with its free function; nothing for an ordinary function.
def native_attr(name: String, native: Optional[Ast.Native]) -> String
  case native
    some(link) ->
      extra = ""
      if link.symbol != name
        extra += " symbol=#{Text.quote(link.symbol)}"
      end

      if link.compute
        extra += " compute=true"
      end

      if link.module
        extra += " module=true"
      end

      if link.free != ""
        extra += " resource=#{Text.quote(link.resource)} free=#{Text.quote(link.free)}"
      end

      for out in link.outs
        extra += " out=#{Text.quote(out.name)} free=#{Text.quote(out.free)}"
      end

      " library=#{Text.quote(link.library)} codes=#{Text.quote(link.codes)}#{extra}"
    none -> ""
  end
end

def name_attr(name: String) -> String = " name=#{Text.quote(name)}"

def value_text(value: Ast.LitValue) -> String
  case value
    Ast.LitValue.Whole(number) -> "int:#{number}"
    Ast.LitValue.Huge(digits) -> "int:#{digits}"
    Ast.LitValue.Real(number) -> "float:bits:#{Float.to_bits(number)}"
    Ast.LitValue.Text(text) -> "string:#{Text.quote(text)}"
    Ast.LitValue.Flag(flag) -> "bool:#{flag}"
    Ast.LitValue.Nothing -> "nil"
  end
end

def visible_attr(visible: Optional[List[String]]) -> String
  case visible
    some(names) ->
      quoted = names.map do |name| Text.quote(name) end
      " visible=#{list_text(quoted)}"
    none -> ""
  end
end

def list_text(items: List[String]) -> String = "[#{items.join(",")}]"

def print_type(out: List[String], at: Margin, role: String, type: Ast.TypeRef) -> List[String]
  lines = out.push(head(at, role, "type-ref", type.id, type.span, name_attr(type.name)))
  print_types(lines, deeper(at), "arg", type.args)
end

def print_types(out: List[String], at: Margin, role: String, types: List[Ast.TypeRef]) -> List[String]
  lines = out
  for type in types
    lines = print_type(lines, at, role, type)
  end

  lines
end

def print_optional_type(out: List[String], at: Margin, role: String, type: Optional[Ast.TypeRef]) -> List[String]
  case type
    some(found) -> print_type(out, at, role, found)
    none -> out
  end
end

def print_exprs(out: List[String], at: Margin, role: String, items: List[Ast.Expr]) -> List[String]
  lines = out
  for item in items
    lines = print_expr(lines, at, role, item)
  end

  lines
end

def print_stmts(out: List[String], at: Margin, role: String, items: List[Ast.Stmt]) -> List[String]
  lines = out
  for item in items
    lines = print_stmt(lines, at, role, item)
  end

  lines
end

def print_named_args(out: List[String], at: Margin, items: List[Ast.NamedArg]) -> List[String]
  lines = out
  for item in items
    lines = out_named(lines, at, item)
  end

  lines
end

def out_named(out: List[String], at: Margin, item: Ast.NamedArg) -> List[String]
  lines = out.push(head(at, "arg", "named-arg", item.id, item.span, name_attr(item.name)))
  print_expr(lines, deeper(at), "value", item.value)
end

def print_part(out: List[String], at: Margin, part: Ast.Part) -> List[String]
  case part
    Ast.Part.Text(text) -> out.push("#{at.indent}part: text #{Text.quote(text)}")
    Ast.Part.Code(code) -> print_expr(out, at, "part", code)
  end
end

def print_block_param(out: List[String], at: Margin, param: Ast.BlockParam) -> List[String]
  lines = out.push(head(at, "param", "block-param", param.id, param.span, name_attr(param.name)))
  print_optional_type(lines, deeper(at), "type", param.type)
end

def print_map_entry(out: List[String], at: Margin, entry: Ast.MapEntry) -> List[String]
  lines = out.push(head(at, "entry", "map-entry", entry.id, entry.span, ""))
  lines = print_expr(lines, deeper(at), "key", entry.key)
  print_expr(lines, deeper(at), "value", entry.value)
end

def op_attrs(op: String, op_span: Source.Span) -> String = " op=#{op} op-span=#{Text.span_text(op_span)}"

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
  print_exprs(lines, deeper(at), "arg", args)
end

def print_expr(out: List[String], at: Margin, role: String, expr: Ast.Expr) -> List[String]
  child = deeper(at)
  case expr
    Ast.Expr.Literal(node) ->
      out.push(head(at, role, "literal", node.id, node.span, " value=#{value_text(node.value)}"))
    Ast.Expr.Name(node) -> out.push(head(at, role, "name-ref", node.id, node.span, name_attr(node.name)))
    Ast.Expr.TypeName(node) ->
      lines = out.push(head(at, role, "type-expression", node.id, node.span, name_attr(node.name)))
      print_types(lines, child, "arg", node.args)
    Ast.Expr.ConstRef(node) -> out.push(head(at, role, "const-ref", node.id, node.span, name_attr(node.name)))
    Ast.Expr.FunctionRef(node) -> out.push(head(at, role, "function-ref", node.id, node.span, name_attr(node.name)))
    Ast.Expr.Call(node) ->
      lines = print_call_like(
        out,
        at,
        role,
        "call",
        node.id,
        node.span,
        "#{name_attr(node.name)} piped=#{node.piped}",
        node.args,
      )

      print_named_args(lines, child, node.named)
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

      print_named_args(lines, child, node.named)
    Ast.Expr.Invoke(node) ->
      lines = out.push(head(at, role, "invoke", node.id, node.span, ""))
      lines = print_expr(lines, child, "target", node.target)
      print_exprs(lines, child, "arg", node.args)
    Ast.Expr.Construct(node) ->
      lines = out.push(head(at, role, "construct", node.id, node.span, " type=#{Text.quote(node.type_name)}"))
      print_named_args(lines, child, node.args)
    Ast.Expr.Update(node) ->
      lines = out.push(head(at, role, "struct-update", node.id, node.span, visible_attr(node.visible)))
      lines = print_expr(lines, child, "target", node.target)
      print_named_args(lines, child, node.args)
    _ -> print_container_expr(out, at, role, expr)
  end
end

def print_container_expr(out: List[String], at: Margin, role: String, expr: Ast.Expr) -> List[String]
  child = deeper(at)
  case expr
    Ast.Expr.ListLit(node) ->
      lines = out.push(head(at, role, "list-lit", node.id, node.span, ""))
      print_exprs(lines, child, "element", node.elements)
    Ast.Expr.MapLit(node) ->
      lines = out.push(head(at, role, "map-lit", node.id, node.span, ""))
      for entry in node.entries
        lines = print_map_entry(lines, child, entry)
      end

      lines
    Ast.Expr.FieldAccess(node) ->
      lines = out.push(head(at, role, "field-access", node.id, node.span, name_attr(node.name)))
      print_expr(lines, child, "target", node.target)
    Ast.Expr.MethodCall(node) ->
      lines = out.push(head(at, role, "method-call", node.id, node.span, name_attr(node.name)))
      lines = print_expr(lines, child, "target", node.target)
      lines = print_exprs(lines, child, "arg", node.args)
      print_named_args(lines, child, node.named)
    Ast.Expr.Interpolation(node) ->
      lines = out.push(head(at, role, "interpolation", node.id, node.span, ""))
      for part in node.parts
        lines = print_part(lines, child, part)
      end

      lines
    Ast.Expr.BlockLit(node) ->
      name = "block-lit"
      if node.lambda
        name = "lambda"
      end

      lines = out.push(head(at, role, name, node.id, node.span, ""))
      for param in node.params
        lines = print_block_param(lines, child, param)
      end

      print_stmts(lines, child, "body", node.body)
    Ast.Expr.Index(node) ->
      lines = out.push(head(at, role, "index-access", node.id, node.span, ""))
      lines = print_expr(lines, child, "target", node.target)
      print_expr(lines, child, "index", node.index)
    Ast.Expr.Try(node) ->
      lines = out.push(head(at, role, "try-expr", node.id, node.span, ""))
      print_expr(lines, child, "operand", node.operand)
    Ast.Expr.Unary(node) ->
      lines = out.push(head(at, role, "unary", node.id, node.span, op_attrs(node.op, node.op_span)))
      print_expr(lines, child, "operand", node.operand)
    Ast.Expr.Binary(node) ->
      lines = out.push(head(at, role, "binary", node.id, node.span, op_attrs(node.op, node.op_span)))
      lines = print_expr(lines, child, "left", node.left)
      print_expr(lines, child, "right", node.right)
    Ast.Expr.RegexLit(node) ->
      # The call is made from the body and flags, so the text form shows only those.
      attrs = " body=#{Text.quote(node.body)} flags=#{Text.quote(node.flags)}"
      out.push(head(at, role, "regex-lit", node.id, node.span, attrs))
    Ast.Expr.EagLit(node) ->
      lines = out.push(head(at, role, "eag-lit", node.id, node.span, ""))
      print_expr(lines, child, "call", node.call)
    Ast.Expr.Case(node) -> print_case(out, at, role, "case-expr", node)
    # print_expr handles every other variant before it calls this one.
    _ -> out
  end
end

def print_pattern(out: List[String], at: Margin, role: String, pattern: Ast.Pattern) -> List[String]
  case pattern
    Ast.Pattern.Wildcard(node) -> out.push(head(at, role, "wildcard-pattern", node.id, node.span, ""))
    Ast.Pattern.Literal(node) ->
      out.push(head(at, role, "literal-pattern", node.id, node.span, " value=#{value_text(node.value)}"))
    Ast.Pattern.Variant(node) ->
      names = node.slots.map do |slot| slot_text(slot) end
      lines = out.push(
        head(
          at,
          role,
          "variant-pattern",
          node.id,
          node.span,
          " enum=#{Text.quote(node.enum_name)} variant=#{Text.quote(node.variant_name)} bindings=#{list_text(names)}",
        ),
      )

      for slot in node.slots
        case slot
          Ast.Slot.Nested(inner) -> lines = print_pattern(lines, deeper(at), "nested", inner)
          _ -> lines = lines
        end
      end

      lines
    Ast.Pattern.Or(node) ->
      lines = out.push(head(at, role, "or-pattern", node.id, node.span, ""))
      for inner in node.patterns
        lines = print_pattern(lines, deeper(at), "alternative", inner)
      end

      lines
  end
end

# A name is quoted, `_` is -, and a nested pattern is * (its own line follows the variant, in the order of the slots).
def slot_text(slot: Ast.Slot) -> String
  case slot
    Ast.Slot.Bind(name, _) -> Text.quote(name)
    Ast.Slot.Skip -> "-"
    Ast.Slot.Nested(_) -> "*"
  end
end

def print_branch(out: List[String], at: Margin, branch: Ast.IfBranch) -> List[String]
  lines = out.push(head(at, "branch", "if-branch", branch.id, branch.span, ""))
  lines = print_expr(lines, deeper(at), "condition", branch.condition)
  print_stmts(lines, deeper(at), "body", branch.body)
end

def print_arm(out: List[String], at: Margin, arm: Ast.CaseArm) -> List[String]
  lines = out.push(head(at, "arm", "case-arm", arm.id, arm.span, ""))
  lines = print_pattern(lines, deeper(at), "pattern", arm.pattern)
  case arm.guard
    some(condition) -> lines = print_expr(lines, deeper(at), "guard", condition)
    none -> lines = lines
  end

  print_stmts(lines, deeper(at), "body", arm.body)
end

def print_stmt(out: List[String], at: Margin, role: String, stmt: Ast.Stmt) -> List[String]
  child = deeper(at)
  case stmt
    Ast.Stmt.Binding(node) ->
      lines = out.push(head(at, role, "binding", node.id, node.span, name_attr(node.name)))
      lines = print_optional_type(lines, child, "type", node.type)
      print_expr(lines, child, "value", node.value)
    Ast.Stmt.Return(node) ->
      extra = ""
      if node.implicit
        extra = " implicit"
      end

      lines = out.push(head(at, role, "return-stmt", node.id, node.span, extra))
      case node.value
        some(value) -> print_expr(lines, child, "value", value)
        none -> lines
      end

    Ast.Stmt.Expression(node) ->
      lines = out.push(head(at, role, "expr-stmt", node.id, node.span, ""))
      print_expr(lines, child, "value", node.value)
    Ast.Stmt.If(node) ->
      extra = ""
      if node.guard
        extra = " guard"
      end

      lines = out.push(head(at, role, "if-stmt", node.id, node.span, extra))
      for branch in node.branches
        lines = print_branch(lines, child, branch)
      end

      case node.else_body
        some(body) ->
          lines = lines.push("#{child.indent}else:")
          print_stmts(lines, deeper(child), "body", body)
        none -> lines
      end

    Ast.Stmt.While(node) ->
      lines = out.push(head(at, role, "while-stmt", node.id, node.span, ""))
      lines = print_expr(lines, child, "condition", node.condition)
      print_stmts(lines, child, "body", node.body)
    Ast.Stmt.For(node) ->
      lines = out.push(head(at, role, "for-stmt", node.id, node.span, " variable=#{Text.quote(node.variable)}"))
      lines = print_expr(lines, child, "iterable", node.iterable)
      print_stmts(lines, child, "body", node.body)
    Ast.Stmt.Control(node) -> out.push(head(at, role, "loop-control", node.id, node.span, " kind=#{node.kind}"))
    Ast.Stmt.Case(node) -> print_case(out, at, role, "case-stmt", node)
  end
end

def print_case(out: List[String], at: Margin, role: String, kind: String, node: Ast.CaseStmt) -> List[String]
  lines = out.push(head(at, role, kind, node.id, node.span, ""))
  lines = print_expr(lines, deeper(at), "value", node.value)
  for arm in node.arms
    lines = print_arm(lines, deeper(at), arm)
  end

  lines
end

def print_param(out: List[String], at: Margin, param: Ast.Param) -> List[String]
  lines = out.push(head(at, "param", "param", param.id, param.span, name_attr(param.name)))
  lines = print_type(lines, deeper(at), "type", param.type)
  case param.default
    some(value) -> print_expr(lines, deeper(at), "default", value)
    none -> lines
  end
end

def print_field(out: List[String], at: Margin, field: Ast.FieldDecl) -> List[String]
  lines = out.push(head(at, "field", "field-decl", field.id, field.span, name_attr(field.name) + doc_attr(field.doc)))
  lines = print_type(lines, deeper(at), "type", field.type)
  case field.default
    some(value) -> print_expr(lines, deeper(at), "default", value)
    none -> lines
  end
end

def print_variant(out: List[String], at: Margin, variant: Ast.EnumVariant) -> List[String]
  lines = out.push(
    head(at, "variant", "enum-variant", variant.id, variant.span, name_attr(variant.name) + doc_attr(variant.doc)),
  )

  print_types(lines, deeper(at), "payload", variant.payload_types)
end

# ` path="x" alias="Mod"`, or ` path="x" names=[...]` with each name and its span, and `as` with the local name for a
# rename.
def import_attrs(node: Ast.ImportDecl) -> String
  case node.alias
    some(alias) -> " path=#{Text.quote(node.path)} alias=#{Text.quote(alias)}"
    none ->
      texts = node.names.map do |entry| import_name_text(entry) end
      " path=#{Text.quote(node.path)} names=[#{texts.join(",")}]"
  end
end

def import_name_text(entry: Ast.ImportName) -> String
  text = "#{Text.quote(entry.name)}@#{Text.span_text(entry.span)}"
  if entry.local != entry.name
    text += " as #{Text.quote(entry.local)}@#{Text.span_text(entry.local_span)}"
  end

  text
end
