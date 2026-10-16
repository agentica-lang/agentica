## The second half of the linker: rewrites the declarations of one file so that every name is the name of the linked
## program (resolve.agc), and so every file can share one program.
##
## Names are resolved in a fixed order (a node's own name first, then its parts in field order), so the first failure
## is always the same. Nodes keep their ids and spans. The recursion follows the depth of the tree: about
## one VM call per level (rewrite_expr passes to rewrite_compound with a tail call), so trees up to about 9,900 levels
## fit in the limit of 10,000 calls (the parser's nesting limit bounds the calls it makes, not the depth of the tree;
## see ast.agc).

import Ast from "ast"
import Declarations from "declarations"
import Resolve from "resolve"
import Source from "source"

## The declarations of a file in the linked program: its functions, structs, enums and aliases without the export,
## imports left
## out.
export def rewrite_declarations(cx: Resolve.Context) -> Result[List[Ast.Decl]]
  out: List[Ast.Decl] = []
  for wrapped in cx.me.program.declarations
    if !Declarations.import?(Declarations.kind_of(wrapped))
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
    Ast.Decl.TypeAlias(node) ->
      target = try rewrite_type(cx, node.target)
      return ok(Ast.Decl.TypeAlias(node.with(name: Resolve.identity(cx, node.name), target: target)))
    Ast.Decl.Constant(node) -> return rewrite_constant(cx, node)
    _ -> return ok(decl)
  end
end

def rewrite_function(cx: Resolve.Context, node: Ast.FunctionDecl) -> Result[Ast.Decl]
  params: List[Ast.Param] = []
  for param in node.params
    type = try rewrite_type(cx, param.type)
    default = try rewrite_optional_expr(cx, param.default)
    params = params.push(param.with(type: type, default: default))
  end
  result = try rewrite_type(cx, node.result)
  body = try rewrite_stmts(cx, node.body)
  return ok(
    Ast.Decl.Function(node.with(name: Resolve.identity(cx, node.name), params: params, result: result, body: body)),
  )
end

# A constant keeps its place, takes its linked name and loses its export (the linked program has no exports).
def rewrite_constant(cx: Resolve.Context, node: Ast.ConstDecl) -> Result[Ast.Decl]
  type = try rewrite_optional_type(cx, node.type)
  value = try rewrite_expr(cx, node.value)
  return ok(
    Ast.Decl.Constant(node.with(name: Resolve.identity(cx, node.name), type: type, value: value, exported: false)),
  )
end

def rewrite_struct(cx: Resolve.Context, node: Ast.StructDecl) -> Result[Ast.Decl]
  fields: List[Ast.FieldDecl] = []
  for field in node.fields
    fields = fields.push(field.with(type: try rewrite_type(cx, field.type)))
  end
  return ok(Ast.Decl.Struct(node.with(name: Resolve.identity(cx, node.name), fields: fields)))
end

def rewrite_enum(cx: Resolve.Context, node: Ast.EnumDecl) -> Result[Ast.Decl]
  variants: List[Ast.EnumVariant] = []
  for variant in node.variants
    payload: List[Ast.TypeRef] = []
    for type in variant.payload_types
      payload = payload.push(try rewrite_payload(cx, node.type_parameters, type))
    end
    variants = variants.push(variant.with(payload_types: payload))
  end
  return ok(Ast.Decl.Enum(node.with(name: Resolve.identity(cx, node.name), variants: variants)))
end

# A payload type that is a type parameter of the enum (T) stays as it is.
def rewrite_payload(cx: Resolve.Context, parameters: List[String], type: Ast.TypeRef) -> Result[Ast.TypeRef]
  name = type.name
  if type.args.size > 0 or !parameters.any? do |parameter| parameter == type.name end
    name = try Resolve.resolve(cx, type.name, Resolve.Want.Type, type.span, false)
  end
  args: List[Ast.TypeRef] = []
  for arg in type.args
    args = args.push(try rewrite_payload(cx, parameters, arg))
  end
  return ok(type.with(name: name, args: args))
end

def rewrite_type(cx: Resolve.Context, type: Ast.TypeRef) -> Result[Ast.TypeRef]
  name = try Resolve.resolve(cx, type.name, Resolve.Want.Type, type.span, false)
  args: List[Ast.TypeRef] = []
  for arg in type.args
    args = args.push(try rewrite_type(cx, arg))
  end
  return ok(type.with(name: name, args: args))
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
      return ok(Ast.Stmt.Binding(node.with(type: type, value: value)))
    Ast.Stmt.Return(node) ->
      value = try rewrite_optional_expr(cx, node.value)
      return ok(Ast.Stmt.Return(node.with(value: value)))
    Ast.Stmt.Expression(node) -> return ok(Ast.Stmt.Expression(node.with(value: try rewrite_expr(cx, node.value))))
    Ast.Stmt.If(node) -> return rewrite_if(cx, node)
    Ast.Stmt.While(node) ->
      condition = try rewrite_expr(cx, node.condition)
      body = try rewrite_stmts(cx, node.body)
      return ok(Ast.Stmt.While(node.with(condition: condition, body: body)))
    Ast.Stmt.For(node) ->
      iterable = try rewrite_expr(cx, node.iterable)
      body = try rewrite_stmts(cx, node.body)
      return ok(Ast.Stmt.For(node.with(iterable: iterable, body: body)))
    Ast.Stmt.Control(node) -> return ok(stmt)
    Ast.Stmt.Case(node) -> return rewrite_case(cx, node)
  end
end

def rewrite_if(cx: Resolve.Context, node: Ast.IfStmt) -> Result[Ast.Stmt]
  branches: List[Ast.IfBranch] = []
  for branch in node.branches
    condition = try rewrite_expr(cx, branch.condition)
    body = try rewrite_stmts(cx, branch.body)
    branches = branches.push(branch.with(condition: condition, body: body))
  end
  else_body = node.else_body
  case node.else_body
    Ast.Optional.Present(body) -> else_body = Ast.Optional.Present(try rewrite_stmts(cx, body))
    Ast.Optional.Absent -> else_body = node.else_body
  end
  return ok(Ast.Stmt.If(node.with(branches: branches, else_body: else_body)))
end

def rewrite_case(cx: Resolve.Context, node: Ast.CaseStmt) -> Result[Ast.Stmt]
  value = try rewrite_expr(cx, node.value)
  arms: List[Ast.CaseArm] = []
  for arm in node.arms
    pattern = try rewrite_pattern(cx, arm.pattern)
    guard = try rewrite_optional_expr(cx, arm.guard)
    body = try rewrite_stmts(cx, arm.body)
    arms = arms.push(arm.with(pattern: pattern, guard: guard, body: body))
  end
  return ok(Ast.Stmt.Case(node.with(value: value, arms: arms)))
end

# A variant pattern names its enum, and so does each variant nested in its slots.
def rewrite_pattern(cx: Resolve.Context, pattern: Ast.Pattern) -> Result[Ast.Pattern]
  case pattern
    Ast.Pattern.Variant(node) ->
      name = try Resolve.resolve(cx, node.enum_name, Resolve.Want.Enum, node.span, false)
      slots: List[Ast.Slot] = []
      for slot in node.slots
        case slot
          Ast.Slot.Nested(inner) -> slots = slots.push(Ast.Slot.Nested(try rewrite_pattern(cx, inner)))
          _ -> slots = slots.push(slot)
        end
      end
      return ok(Ast.Pattern.Variant(node.with(enum_name: name, slots: slots)))
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
    out = out.push(arg.with(value: try rewrite_expr(cx, arg.value)))
  end
  return ok(out)
end

def rewrite_expr(cx: Resolve.Context, expr: Ast.Expr) -> Result[Ast.Expr]
  case expr
    Ast.Expr.Literal(node) -> return ok(expr)
    Ast.Expr.Name(node) -> return ok(expr)
    Ast.Expr.TypeName(node) -> return rewrite_type_name(cx, node)
    Ast.Expr.Call(node) -> return rewrite_call(cx, node)
    Ast.Expr.EnumConstructor(node) ->
      name = try Resolve.resolve(cx, node.enum_name, Resolve.Want.Enum, node.span, false)
      args = try rewrite_exprs(cx, node.args)
      return ok(Ast.Expr.EnumConstructor(node.with(enum_name: name, args: args)))
    Ast.Expr.FunctionRef(node) ->
      name = try Resolve.resolve(cx, node.name, Resolve.Want.Function, node.span, false)
      return ok(Ast.Expr.FunctionRef(node.with(name: name)))
    Ast.Expr.Construct(node) -> return rewrite_construct(cx, node)
    _ -> return rewrite_compound(cx, expr)
  end
end

def rewrite_call(cx: Resolve.Context, node: Ast.Call) -> Result[Ast.Expr]
  parts = node.name.split(".")
  if parts.size == 2 and Resolve.constant_identity(cx, parts[0]) != ""
    return rewrite_constant_member(cx, node, Resolve.constant_identity(cx, parts[0]), parts[0].length, parts[1])
  end
  name = try Resolve.resolve(cx, node.name, Resolve.Want.Function, node.span, false)
  args = try rewrite_exprs(cx, node.args)
  return ok(Ast.Expr.Call(node.with(name: name, args: args)))
end

# NAME.x on a constant: a field access when written with no parentheses and no arguments (a block is an argument), a
# method call otherwise (docs/future/44-module-constants.md 44.3). The receiver is the name alone, with an id past the
# ids of the program, since the call has only one.
def rewrite_constant_member(
  cx: Resolve.Context,
  node: Ast.Call,
  linked: String,
  length: Int,
  member: String,
) -> Result[Ast.Expr]
  start = node.span.start
  stop = Source.Position(offset: start.offset + length, line: start.line, column: start.column + length)
  receiver = Ast.Expr.ConstRef(
    Ast.ConstRef(id: cx.ids + node.id, name: linked, span: Source.Span(start: start, stop: stop)),
  )
  if node.args.size == 0 and !node.parenthesized
    return ok(Ast.Expr.FieldAccess(Ast.FieldAccess(id: node.id, target: receiver, name: member, span: node.span)))
  end
  args = try rewrite_exprs(cx, node.args)
  return ok(
    Ast.Expr.MethodCall(Ast.MethodCall(id: node.id, target: receiver, name: member, args: args, span: node.span)),
  )
end

# The expressions that only rewrite their parts, in the order of their fields.
def rewrite_compound(cx: Resolve.Context, expr: Ast.Expr) -> Result[Ast.Expr]
  case expr
    Ast.Expr.Invoke(node) ->
      target = try rewrite_expr(cx, node.target)
      args = try rewrite_exprs(cx, node.args)
      return ok(Ast.Expr.Invoke(node.with(target: target, args: args)))
    Ast.Expr.Update(node) ->
      target = try rewrite_expr(cx, node.target)
      args = try rewrite_named(cx, node.args)
      return ok(Ast.Expr.Update(node.with(target: target, args: args, visible: Ast.Optional.Present(cx.visible))))
    Ast.Expr.ListLit(node) -> return ok(Ast.Expr.ListLit(node.with(elements: try rewrite_exprs(cx, node.elements))))
    Ast.Expr.MapLit(node) -> return rewrite_map(cx, node)
    Ast.Expr.FieldAccess(node) -> return ok(Ast.Expr.FieldAccess(node.with(target: try rewrite_expr(cx, node.target))))
    Ast.Expr.MethodCall(node) ->
      target = try rewrite_expr(cx, node.target)
      args = try rewrite_exprs(cx, node.args)
      return ok(Ast.Expr.MethodCall(node.with(target: target, args: args)))
    Ast.Expr.Interpolation(node) -> return rewrite_interpolation(cx, node)
    Ast.Expr.BlockLit(node) -> return rewrite_block(cx, node)
    Ast.Expr.Index(node) ->
      target = try rewrite_expr(cx, node.target)
      index = try rewrite_expr(cx, node.index)
      return ok(Ast.Expr.Index(node.with(target: target, index: index)))
    Ast.Expr.Try(node) -> return ok(Ast.Expr.Try(node.with(operand: try rewrite_expr(cx, node.operand))))
    Ast.Expr.Unary(node) -> return ok(Ast.Expr.Unary(node.with(operand: try rewrite_expr(cx, node.operand))))
    Ast.Expr.Binary(node) ->
      left = try rewrite_expr(cx, node.left)
      right = try rewrite_expr(cx, node.right)
      return ok(Ast.Expr.Binary(node.with(left: left, right: right)))
    _ -> return ok(expr)
  end
end

def rewrite_map(cx: Resolve.Context, node: Ast.MapLit) -> Result[Ast.Expr]
  entries: List[Ast.MapEntry] = []
  for entry in node.entries
    key = try rewrite_expr(cx, entry.key)
    value = try rewrite_expr(cx, entry.value)
    entries = entries.push(entry.with(key: key, value: value))
  end
  return ok(Ast.Expr.MapLit(node.with(entries: entries)))
end

def rewrite_interpolation(cx: Resolve.Context, node: Ast.Interpolation) -> Result[Ast.Expr]
  parts: List[Ast.Part] = []
  for part in node.parts
    case part
      Ast.Part.Text(text) -> parts = parts.push(part)
      Ast.Part.Code(code) -> parts = parts.push(Ast.Part.Code(try rewrite_expr(cx, code)))
    end
  end
  return ok(Ast.Expr.Interpolation(node.with(parts: parts)))
end

def rewrite_block(cx: Resolve.Context, node: Ast.BlockLit) -> Result[Ast.Expr]
  params: List[Ast.BlockParam] = []
  for param in node.params
    params = params.push(param.with(type: try rewrite_optional_type(cx, param.type)))
  end
  body = try rewrite_stmts(cx, node.body)
  return ok(Ast.Expr.BlockLit(node.with(params: params, body: body)))
end

# Enum.Variant, written without parentheses, is a variant of an enum of this file, one imported by name or a builtin
# one; a name that is a constant of this file is a read of it; any other name is a type.
def rewrite_type_name(cx: Resolve.Context, node: Ast.TypeName) -> Result[Ast.Expr]
  parts = node.name.split(".")
  if parts.size == 2 and Resolve.local_enum?(cx, parts[0])
    return ok(variant(node.id, Resolve.identity(cx, parts[0]), parts[1], [], [], node.span))
  elsif parts.size == 2 and Resolve.named_enum?(cx, parts[0])
    enum_name = try Resolve.resolve(cx, parts[0], Resolve.Want.Enum, node.span, false)
    return ok(variant(node.id, enum_name, parts[1], [], [], node.span))
  elsif parts.size == 2 and cx.settings.catalog.enums.has_key?(parts[0])
    return ok(variant(node.id, parts[0], parts[1], [], [], node.span))
  end
  constant = Resolve.constant_identity(cx, node.name)
  if parts.size == 1 and constant != ""
    return ok(Ast.Expr.ConstRef(Ast.ConstRef(id: node.id, name: constant, span: node.span)))
  end
  if parts.size == 1 and Resolve.unknown_constant?(cx, node.name)
    return error(Resolve.unknown_constant_failure(cx, node.name, node.span))
  end
  name = try Resolve.resolve(cx, node.name, Resolve.Want.Type, node.span, true)
  return ok(Ast.Expr.TypeName(node.with(name: name)))
end

def variant(
  id: Int,
  enum_name: String,
  variant_name: String,
  args: List[Ast.Expr],
  named: List[Ast.NamedArg],
  span: Source.Span,
) -> Ast.Expr
  return Ast.Expr.EnumConstructor(
    Ast.EnumConstructor(
      id: id,
      enum_name: enum_name,
      variant_name: variant_name,
      args: args,
      named: named,
      span: span,
    ),
  )
end

# Name(field: value) builds a struct, unless the name is a variant (Enum.Variant, or Alias.Enum.Variant): that is an
# enum constructor with named arguments, which the checker refuses.
def rewrite_construct(cx: Resolve.Context, node: Ast.Construct) -> Result[Ast.Expr]
  parts = node.type_name.split(".")
  if parts.size == 2 and Resolve.local_enum?(cx, parts[0])
    return ok(
      variant(node.id, Resolve.identity(cx, parts[0]), parts[1], [], try rewrite_named(cx, node.args), node.span),
    )
  elsif parts.size == 2 and Resolve.named_enum?(cx, parts[0])
    enum_name = try Resolve.resolve(cx, parts[0], Resolve.Want.Enum, node.span, false)
    return ok(variant(node.id, enum_name, parts[1], [], try rewrite_named(cx, node.args), node.span))
  elsif parts.size == 2 and cx.settings.catalog.enums.has_key?(parts[0])
    return ok(variant(node.id, parts[0], parts[1], [], try rewrite_named(cx, node.args), node.span))
  elsif parts.size == 3 and exported_enum?(cx, parts[0], parts[1])
    name = try Resolve.resolve(cx, "#{parts[0]}.#{parts[1]}", Resolve.Want.Enum, node.span, false)
    return ok(variant(node.id, name, parts[2], [], try rewrite_named(cx, node.args), node.span))
  end
  name = try Resolve.resolve(cx, node.type_name, Resolve.Want.Type, node.span, false)
  args = try rewrite_named(cx, node.args)
  return ok(Ast.Expr.Construct(node.with(type_name: name, args: args)))
end

def exported_enum?(cx: Resolve.Context, alias: String, name: String) -> Bool
  target = cx.me.aliases.get(alias, "")
  return target != "" and Resolve.exports_enum?(cx.modules[target], name)
end
