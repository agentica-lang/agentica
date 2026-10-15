## The second half of the linker: rewrites the declarations of one file so that every name is the name of the linked program (resolve.agc), and so every file can share one program. This is the rewrite function of src/modules.rkt.
##
## Names are resolved in the order Racket resolves them (a node's own name first, then its parts in field order), so the first failure is the same. Nodes keep their ids and spans. The recursion follows the depth of the tree: about two VM calls per level, so a tree of 3,000 levels is near the limit of 10,000 calls (the parser's nesting limit bounds the calls it makes, not the depth of the tree; see ast.agc).

import "ast" as Ast
import "declarations" as Declarations
import "resolve" as Resolve
import "source" as Source

## The declarations of a file in the linked program: its functions, structs and enums without the export, imports left out.
export def rewrite_declarations(cx: Resolve.Context) -> Result[List[Ast.Decl]]
  out: List[Ast.Decl] = []
  for wrapped in cx.me.program.declarations
    if Declarations.kind_of(wrapped) != "import"
      out = out.push(try rewrite_decl(cx, Declarations.unwrap(wrapped)))
    end
  end
  return ok(out)
end

def rewrite_decl(cx: Resolve.Context, decl: Ast.Decl) -> Result[Ast.Decl]
  case decl
    Ast.Decl.Function(node) -> return rewrite_function(cx, node)
    Ast.Decl.Struct(node) -> return rewrite_struct(cx, node)
    Ast.Decl.Enum(node) -> return rewrite_enum(cx, node)
    _ -> return ok(decl)
  end
end

def rewrite_function(cx: Resolve.Context, node: Ast.FunctionDecl) -> Result[Ast.Decl]
  params: List[Ast.Param] = []
  for param in node.params
    params = params.push(Ast.Param(id: param.id, name: param.name, type: try rewrite_type(cx, param.type), span: param.span))
  end
  result = try rewrite_type(cx, node.result)
  body = try rewrite_stmts(cx, node.body)
  return ok(Ast.Decl.Function(Ast.FunctionDecl(id: node.id, name: Resolve.identity(cx, node.name), params: params, result: result, body: body, doc: node.doc, span: node.span)))
end

def rewrite_struct(cx: Resolve.Context, node: Ast.StructDecl) -> Result[Ast.Decl]
  fields: List[Ast.FieldDecl] = []
  for field in node.fields
    fields = fields.push(Ast.FieldDecl(id: field.id, name: field.name, type: try rewrite_type(cx, field.type), doc: field.doc, span: field.span))
  end
  return ok(Ast.Decl.Struct(Ast.StructDecl(id: node.id, name: Resolve.identity(cx, node.name), fields: fields, doc: node.doc, span: node.span)))
end

def rewrite_enum(cx: Resolve.Context, node: Ast.EnumDecl) -> Result[Ast.Decl]
  variants: List[Ast.EnumVariant] = []
  for variant in node.variants
    payload: List[Ast.TypeRef] = []
    for type in variant.payload_types
      payload = payload.push(try rewrite_payload(cx, node.type_parameters, type))
    end
    variants = variants.push(Ast.EnumVariant(id: variant.id, name: variant.name, payload_types: payload, doc: variant.doc, span: variant.span))
  end
  return ok(Ast.Decl.Enum(Ast.EnumDecl(id: node.id, name: Resolve.identity(cx, node.name), type_parameters: node.type_parameters, variants: variants, doc: node.doc, span: node.span)))
end

# A payload type that is a type parameter of the enum (T) stays as it is.
def rewrite_payload(cx: Resolve.Context, parameters: List[String], type: Ast.TypeRef) -> Result[Ast.TypeRef]
  name = type.name
  if type.args.size > 0 or !parameters.any? do |parameter| parameter == type.name end
    name = try Resolve.resolve(cx, type.name, "type", type.span, false)
  end
  args: List[Ast.TypeRef] = []
  for arg in type.args
    args = args.push(try rewrite_payload(cx, parameters, arg))
  end
  return ok(Ast.TypeRef(id: type.id, name: name, args: args, span: type.span))
end

def rewrite_type(cx: Resolve.Context, type: Ast.TypeRef) -> Result[Ast.TypeRef]
  name = try Resolve.resolve(cx, type.name, "type", type.span, false)
  args: List[Ast.TypeRef] = []
  for arg in type.args
    args = args.push(try rewrite_type(cx, arg))
  end
  return ok(Ast.TypeRef(id: type.id, name: name, args: args, span: type.span))
end

def rewrite_optional_type(cx: Resolve.Context, type: Ast.Optional[Ast.TypeRef]) -> Result[Ast.Optional[Ast.TypeRef]]
  case type
    Ast.Optional.Present(found) -> return ok(Ast.Optional.Present(try rewrite_type(cx, found)))
    Ast.Optional.Absent -> return ok(type)
  end
end

def rewrite_stmts(cx: Resolve.Context, stmts: List[Ast.Stmt]) -> Result[List[Ast.Stmt]]
  out: List[Ast.Stmt] = []
  for stmt in stmts
    out = out.push(try rewrite_stmt(cx, stmt))
  end
  return ok(out)
end

def rewrite_stmt(cx: Resolve.Context, stmt: Ast.Stmt) -> Result[Ast.Stmt]
  case stmt
    Ast.Stmt.Binding(node) ->
      type = try rewrite_optional_type(cx, node.type)
      value = try rewrite_expr(cx, node.value)
      return ok(Ast.Stmt.Binding(Ast.Binding(id: node.id, name: node.name, type: type, value: value, span: node.span)))
    Ast.Stmt.Return(node) ->
      value = try rewrite_optional_expr(cx, node.value)
      return ok(Ast.Stmt.Return(Ast.Return(id: node.id, value: value, span: node.span)))
    Ast.Stmt.Expression(node) -> return ok(Ast.Stmt.Expression(Ast.ExprStmt(id: node.id, value: try rewrite_expr(cx, node.value), span: node.span)))
    Ast.Stmt.If(node) -> return rewrite_if(cx, node)
    Ast.Stmt.While(node) ->
      condition = try rewrite_expr(cx, node.condition)
      body = try rewrite_stmts(cx, node.body)
      return ok(Ast.Stmt.While(Ast.WhileStmt(id: node.id, condition: condition, body: body, span: node.span)))
    Ast.Stmt.For(node) ->
      iterable = try rewrite_expr(cx, node.iterable)
      body = try rewrite_stmts(cx, node.body)
      return ok(Ast.Stmt.For(Ast.ForStmt(id: node.id, variable: node.variable, iterable: iterable, body: body, span: node.span)))
    Ast.Stmt.Control(node) -> return ok(stmt)
    Ast.Stmt.Case(node) -> return rewrite_case(cx, node)
  end
end

def rewrite_if(cx: Resolve.Context, node: Ast.IfStmt) -> Result[Ast.Stmt]
  branches: List[Ast.IfBranch] = []
  for branch in node.branches
    condition = try rewrite_expr(cx, branch.condition)
    body = try rewrite_stmts(cx, branch.body)
    branches = branches.push(Ast.IfBranch(id: branch.id, condition: condition, body: body, span: branch.span))
  end
  else_body = node.else_body
  case node.else_body
    Ast.Optional.Present(body) -> else_body = Ast.Optional.Present(try rewrite_stmts(cx, body))
    Ast.Optional.Absent -> else_body = node.else_body
  end
  return ok(Ast.Stmt.If(Ast.IfStmt(id: node.id, branches: branches, else_body: else_body, span: node.span)))
end

def rewrite_case(cx: Resolve.Context, node: Ast.CaseStmt) -> Result[Ast.Stmt]
  value = try rewrite_expr(cx, node.value)
  arms: List[Ast.CaseArm] = []
  for arm in node.arms
    pattern = try rewrite_pattern(cx, arm.pattern)
    body = try rewrite_stmts(cx, arm.body)
    arms = arms.push(Ast.CaseArm(id: arm.id, pattern: pattern, body: body, span: arm.span))
  end
  return ok(Ast.Stmt.Case(Ast.CaseStmt(id: node.id, value: value, arms: arms, span: node.span)))
end

def rewrite_pattern(cx: Resolve.Context, pattern: Ast.Pattern) -> Result[Ast.Pattern]
  case pattern
    Ast.Pattern.Variant(node) ->
      name = try Resolve.resolve(cx, node.enum_name, "enum", node.span, false)
      return ok(Ast.Pattern.Variant(Ast.VariantPattern(id: node.id, enum_name: name, variant_name: node.variant_name, bindings: node.bindings, span: node.span)))
    _ -> return ok(pattern)
  end
end

def rewrite_optional_expr(cx: Resolve.Context, expr: Ast.Optional[Ast.Expr]) -> Result[Ast.Optional[Ast.Expr]]
  case expr
    Ast.Optional.Present(found) -> return ok(Ast.Optional.Present(try rewrite_expr(cx, found)))
    Ast.Optional.Absent -> return ok(expr)
  end
end

def rewrite_exprs(cx: Resolve.Context, exprs: List[Ast.Expr]) -> Result[List[Ast.Expr]]
  out: List[Ast.Expr] = []
  for expr in exprs
    out = out.push(try rewrite_expr(cx, expr))
  end
  return ok(out)
end

def rewrite_named(cx: Resolve.Context, args: List[Ast.NamedArg]) -> Result[List[Ast.NamedArg]]
  out: List[Ast.NamedArg] = []
  for arg in args
    out = out.push(Ast.NamedArg(id: arg.id, name: arg.name, value: try rewrite_expr(cx, arg.value), span: arg.span))
  end
  return ok(out)
end

def rewrite_expr(cx: Resolve.Context, expr: Ast.Expr) -> Result[Ast.Expr]
  case expr
    Ast.Expr.Literal(node) -> return ok(expr)
    Ast.Expr.Name(node) -> return ok(expr)
    Ast.Expr.TypeName(node) -> return rewrite_type_name(cx, node)
    Ast.Expr.Call(node) ->
      name = try Resolve.resolve(cx, node.name, "function", node.span, false)
      args = try rewrite_exprs(cx, node.args)
      return ok(Ast.Expr.Call(Ast.Call(id: node.id, name: name, args: args, piped: node.piped, parenthesized: node.parenthesized, span: node.span)))
    Ast.Expr.EnumConstructor(node) ->
      name = try Resolve.resolve(cx, node.enum_name, "enum", node.span, false)
      args = try rewrite_exprs(cx, node.args)
      return ok(Ast.Expr.EnumConstructor(Ast.EnumConstructor(id: node.id, enum_name: name, variant_name: node.variant_name, args: args, named: node.named, span: node.span)))
    Ast.Expr.FunctionRef(node) ->
      name = try Resolve.resolve(cx, node.name, "function", node.span, false)
      return ok(Ast.Expr.FunctionRef(Ast.FunctionRef(id: node.id, name: name, span: node.span)))
    Ast.Expr.Construct(node) -> return rewrite_construct(cx, node)
    _ -> return rewrite_compound(cx, expr)
  end
end

# The expressions that only rewrite their parts, in the order of their fields.
def rewrite_compound(cx: Resolve.Context, expr: Ast.Expr) -> Result[Ast.Expr]
  case expr
    Ast.Expr.Invoke(node) ->
      target = try rewrite_expr(cx, node.target)
      args = try rewrite_exprs(cx, node.args)
      return ok(Ast.Expr.Invoke(Ast.Invoke(id: node.id, target: target, args: args, span: node.span)))
    Ast.Expr.ListLit(node) -> return ok(Ast.Expr.ListLit(Ast.ListLit(id: node.id, elements: try rewrite_exprs(cx, node.elements), span: node.span)))
    Ast.Expr.MapLit(node) -> return rewrite_map(cx, node)
    Ast.Expr.FieldAccess(node) -> return ok(Ast.Expr.FieldAccess(Ast.FieldAccess(id: node.id, target: try rewrite_expr(cx, node.target), name: node.name, span: node.span)))
    Ast.Expr.MethodCall(node) ->
      target = try rewrite_expr(cx, node.target)
      args = try rewrite_exprs(cx, node.args)
      return ok(Ast.Expr.MethodCall(Ast.MethodCall(id: node.id, target: target, name: node.name, args: args, span: node.span)))
    Ast.Expr.Interpolation(node) -> return rewrite_interpolation(cx, node)
    Ast.Expr.BlockLit(node) -> return rewrite_block(cx, node)
    Ast.Expr.Index(node) ->
      target = try rewrite_expr(cx, node.target)
      index = try rewrite_expr(cx, node.index)
      return ok(Ast.Expr.Index(Ast.IndexAccess(id: node.id, target: target, index: index, span: node.span)))
    Ast.Expr.Try(node) -> return ok(Ast.Expr.Try(Ast.TryExpr(id: node.id, operand: try rewrite_expr(cx, node.operand), span: node.span)))
    Ast.Expr.Unary(node) -> return ok(Ast.Expr.Unary(Ast.Unary(id: node.id, op: node.op, op_span: node.op_span, operand: try rewrite_expr(cx, node.operand), span: node.span)))
    Ast.Expr.Binary(node) ->
      left = try rewrite_expr(cx, node.left)
      right = try rewrite_expr(cx, node.right)
      return ok(Ast.Expr.Binary(Ast.Binary(id: node.id, op: node.op, op_span: node.op_span, left: left, right: right, span: node.span)))
    _ -> return ok(expr)
  end
end

def rewrite_map(cx: Resolve.Context, node: Ast.MapLit) -> Result[Ast.Expr]
  entries: List[Ast.MapEntry] = []
  for entry in node.entries
    key = try rewrite_expr(cx, entry.key)
    value = try rewrite_expr(cx, entry.value)
    entries = entries.push(Ast.MapEntry(id: entry.id, key: key, value: value, span: entry.span))
  end
  return ok(Ast.Expr.MapLit(Ast.MapLit(id: node.id, entries: entries, span: node.span)))
end

def rewrite_interpolation(cx: Resolve.Context, node: Ast.Interpolation) -> Result[Ast.Expr]
  parts: List[Ast.Part] = []
  for part in node.parts
    case part
      Ast.Part.Text(text) -> parts = parts.push(part)
      Ast.Part.Code(code) -> parts = parts.push(Ast.Part.Code(try rewrite_expr(cx, code)))
    end
  end
  return ok(Ast.Expr.Interpolation(Ast.Interpolation(id: node.id, parts: parts, span: node.span)))
end

def rewrite_block(cx: Resolve.Context, node: Ast.BlockLit) -> Result[Ast.Expr]
  params: List[Ast.BlockParam] = []
  for param in node.params
    params = params.push(Ast.BlockParam(id: param.id, name: param.name, type: try rewrite_optional_type(cx, param.type), span: param.span))
  end
  body = try rewrite_stmts(cx, node.body)
  return ok(Ast.Expr.BlockLit(Ast.BlockLit(id: node.id, params: params, body: body, span: node.span)))
end

# Enum.Variant, written without parentheses, is a variant of an enum of this file or a builtin one; any other name is a type.
def rewrite_type_name(cx: Resolve.Context, node: Ast.TypeName) -> Result[Ast.Expr]
  parts = node.name.split(".")
  if parts.size == 2 and cx.me.names.get(parts[0], "") == "enum"
    return ok(variant(node.id, Resolve.identity(cx, parts[0]), parts[1], [], [], node.span))
  elsif parts.size == 2 and cx.settings.builtin_enums.include?(parts[0])
    return ok(variant(node.id, parts[0], parts[1], [], [], node.span))
  end
  name = try Resolve.resolve(cx, node.name, "type", node.span, true)
  return ok(Ast.Expr.TypeName(Ast.TypeName(id: node.id, name: name, span: node.span)))
end

def variant(id: Int, enum_name: String, variant_name: String, args: List[Ast.Expr], named: List[Ast.NamedArg], span: Source.Span) -> Ast.Expr
  return Ast.Expr.EnumConstructor(Ast.EnumConstructor(id: id, enum_name: enum_name, variant_name: variant_name, args: args, named: named, span: span))
end

# Name(field: value) builds a struct, unless the name is a variant (Enum.Variant, or Alias.Enum.Variant): that is an enum constructor with named arguments, which the checker refuses.
def rewrite_construct(cx: Resolve.Context, node: Ast.Construct) -> Result[Ast.Expr]
  parts = node.type_name.split(".")
  if parts.size == 2 and cx.me.names.get(parts[0], "") == "enum"
    return ok(variant(node.id, Resolve.identity(cx, parts[0]), parts[1], [], try rewrite_named(cx, node.args), node.span))
  elsif parts.size == 2 and cx.settings.builtin_enums.include?(parts[0])
    return ok(variant(node.id, parts[0], parts[1], [], try rewrite_named(cx, node.args), node.span))
  elsif parts.size == 3 and exported_enum?(cx, parts[0], parts[1])
    name = try Resolve.resolve(cx, parts[0] + "." + parts[1], "enum", node.span, false)
    return ok(variant(node.id, name, parts[2], [], try rewrite_named(cx, node.args), node.span))
  end
  name = try Resolve.resolve(cx, node.type_name, "type", node.span, false)
  args = try rewrite_named(cx, node.args)
  return ok(Ast.Expr.Construct(Ast.Construct(id: node.id, type_name: name, args: args, span: node.span)))
end

def exported_enum?(cx: Resolve.Context, alias: String, name: String) -> Bool
  target = cx.me.aliases.get(alias, "")
  return target != "" and cx.modules[target].public.get(name, "") == "enum"
end
