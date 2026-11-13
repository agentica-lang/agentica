## The type of a block or lambda parameter that neither an annotation nor the context gives, from its uses in the body
## (docs/grammar/06-semantics.md, "Blocks"). Each use of the name is either no constraint or the complete set of types
## that the use allows, which is finite only when every type in it can be named: the checker matches types exactly, so
## a type outside the set can never pass that use. The parameter has a type when the sets of its uses meet in exactly
## one type. The scan reads the tree only; the body is then checked with that type as if it were annotated.

import Model from "../catalog/builtin_model"
import {ENTRIES} from "../catalog/builtins"
import Ast from "../syntax/ast"
import Walk from "../syntax/ast_walk"
import T from "../syntax/types"
import Defaults from "defaults"
import Names from "check_names"
import State from "check_state"
import Types from "check_types"

# The receiver kinds whose type has no type arguments, so a method of theirs names the whole type.
PLAIN_KINDS = {
  "Int": T.Type.Int,
  "Float": T.Type.Float,
  "String": T.Type.String,
  "Json": T.Type.Json,
  "Range": T.Type.Range,
  "Bytes": T.Type.Bytes,
}

## What the uses of a parameter say: Found(type) when they leave one type; Open when no use names a type; Several when
## they leave more than one; Conflict when no type passes them all.
export enum Guess
  Found(T.Type)
  Open
  Several(List[T.Type])
  Conflict
end

# What one use allows: Any (no constraint) or OneOf(types), every type the use can take.
enum Allows
  Any
  OneOf(List[T.Type])
end

## The type that the uses of `name` in `body` leave for it. Shadowing is an error of its own (CHECK-SHADOWED-NAME), so
## every read of the name below the block, nested blocks included, is a read of the parameter.
export def param_type(cx: State.Cx, st: State.St, body: List[Ast.Stmt], name: String) -> Guess
  left: List[T.Type] = []
  narrowed = false
  structs = cx.structs.keys.sort
  work: List[Walk.Node] = body.map do |stmt: Ast.Stmt| Walk.Node.Stmt(stmt) end
  at = 0
  while at < work.size
    node = work[at]
    at += 1
    for allows in uses(cx, st, structs, node, name)
      case allows
        Allows.OneOf(types) ->
          if narrowed
            left = left.filter do |type: T.Type| has?(types, type) end
          else
            left = types
            narrowed = true
          end

        Allows.Any -> narrowed = narrowed
      end
    end

    for child in Walk.children(node)
      work = work.push(child)
    end
  end

  return Guess.Open if !narrowed
  return Guess.Found(left[0]) if left.size == 1
  return Guess.Several(left) if left.size > 1

  Guess.Conflict
end

# What the node says about `name` when the name is one of its direct parts.
def uses(cx: State.Cx, st: State.St, structs: List[String], node: Walk.Node, name: String) -> List[Allows]
  case node
    Walk.Node.Stmt(stmt) ->
      case stmt
        Ast.Stmt.Binding(binding) -> binding_use(cx, st, binding, name)
        _ -> []
      end

    Walk.Node.Expr(expr) -> expr_uses(cx, structs, expr, name)
  end
end

def expr_uses(cx: State.Cx, structs: List[String], expr: Ast.Expr, name: String) -> List[Allows]
  case expr
    Ast.Expr.Call(call) -> call_uses(cx, call, name)
    Ast.Expr.EnumConstructor(variant) -> variant_uses(cx, variant, name)
    Ast.Expr.Construct(construct) -> construct_uses(cx, construct, name)
    Ast.Expr.MethodCall(call) ->
      return [member_use(cx, structs, call.name)] if named?(call.target, name)

      []
    Ast.Expr.FieldAccess(access) ->
      return [member_use(cx, structs, access.name)] if named?(access.target, name)

      []
    Ast.Expr.Binary(binary) -> binary_uses(binary, name)
    Ast.Expr.Unary(unary) ->
      return [Allows.OneOf([T.Type.Bool])] if unary.op == "not" and named?(unary.operand, name)

      []
    _ -> []
  end
end

# `y: Type = x` allows the annotated type.
def binding_use(cx: State.Cx, st: State.St, binding: Ast.Binding, name: String) -> List[Allows]
  return [] if !named?(binding.value, name)

  case binding.type
    some(ref) ->
      case Types.resolve_type(cx, st, ref, false)
        ok(type) -> [Allows.OneOf([type])]
        error(_) -> []
      end

    none -> []
  end
end

# The parameter as an argument of a function of the program, or of a builtin with one form and no rule of its own.
def call_uses(cx: State.Cx, written: Ast.Call, name: String) -> List[Allows]
  params: List[T.Type] = []
  call = written
  case cx.functions.get(call.name)
    some(signature) ->
      shape = signature.shape
      if call.named.size > 0
        binding = Defaults.bind(signature.names, shape, call.args, call.named)
        return [] if binding.code != ""

        call = Defaults.bound(call, binding.slots)
      end

      count = call.args.size
      return [] if count < shape.required or count > shape.total

      for index in 0...count
        params = params.push(signature.params[Defaults.param_of(shape, call.slots, count, index)])
      end

    none ->
      entry = ENTRIES.get(call.name)
      return named_builtin_uses(call, entry, name) if call.named.size > 0

      return [] if !plain_builtin?(entry, call.args.size)

      params = entry.unwrap!.parameters.map do |param: Model.Named| param.type end
  end

  slot_uses(call.args, params, name)
end

# The parameter as an argument of a builtin call with named arguments: a Plain row with one form, bound by the names of
# its parameters (error(...) has the fields of its Error as names, so it is left out).
def named_builtin_uses(written: Ast.Call, entry: Optional[Model.Builtin], name: String) -> List[Allows]
  return [] if entry.none? or written.name == "error"

  form = entry.unwrap!
  return [] if !plain_rule?(form.rule) or form.alternatives.size > 0

  shape = Defaults.builtin_shape(form)
  names = form.parameters.map do |param: Model.Named| param.name end
  binding = Defaults.bind(names, shape, written.args, written.named)
  return [] if binding.code != ""

  call = Defaults.bound(written, binding.slots)
  params: List[T.Type] = []
  for index in 0...call.args.size
    params = params.push(form.parameters[Defaults.param_of(shape, call.slots, call.args.size, index)].type)
  end

  slot_uses(call.args, params, name)
end

def plain_builtin?(entry: Optional[Model.Builtin], count: Int) -> Bool
  case entry
    some(builtin) -> plain_rule?(builtin.rule) and builtin.alternatives.size == 0 and builtin.parameters.size == count
    none -> false
  end
end

def plain_rule?(rule: Model.Rule) -> Bool
  case rule
    Model.Rule.Plain -> true
    _ -> false
  end
end

# The parameter as the payload of a variant whose enum the program knows.
def variant_uses(cx: State.Cx, variant: Ast.EnumConstructor, name: String) -> List[Allows]
  definition = cx.enums.get(variant.enum_name)
  return [] if definition.none?

  for declared in definition.unwrap!.variants
    if declared.name == variant.variant_name and declared.payload.size == variant.args.size
      return slot_uses(variant.args, declared.payload, name)
    end
  end

  []
end

# The parameter as the value of a field in a struct construction.
def construct_uses(cx: State.Cx, construct: Ast.Construct, name: String) -> List[Allows]
  fields = cx.structs.get(construct.type_name)
  return [] if fields.none?

  out: List[Allows] = []
  for arg in construct.args
    if named?(arg.value, name)
      for field in fields.unwrap!
        if field.name == arg.name
          out = out.push(slot(field.type))
        end
      end
    end
  end

  out
end

# One use for each argument that is the parameter, against the type of its slot.
def slot_uses(args: List[Ast.Expr], types: List[T.Type], name: String) -> List[Allows]
  out: List[Allows] = []
  for index in 0...args.size
    if named?(args[index], name)
      out = out.push(slot(types[index]))
    end
  end

  out
end

# A slot whose type holds a variable of its declaration takes values of many types.
def slot(type: T.Type) -> Allows
  return Allows.Any if Types.open_variables?(type, {})

  Allows.OneOf([type])
end

# x.name or x.name(...): the receiver kinds that have a method of that name and the structs (builtin records included)
# that have a field of that name, `structs` being the sorted keys of cx.structs. A generic one among them (List,
# Result, a generic struct ...) takes types that cannot all be named, and every data value has to_s and inspect, so
# then the use allows any type. A name that nothing has is a typo, which the check of the body reports with its
# did-you-mean (CHECK-UNKNOWN-METHOD), so it is no constraint either.
def member_use(cx: State.Cx, structs: List[String], name: String) -> Allows
  return Allows.Any if name == "to_s" or name == "inspect"

  out: List[T.Type] = []
  for kind in Names.METHOD_KINDS
    if Names.resolve_method(cx, kind, name) != ""
      plain = PLAIN_KINDS.get(kind)
      return Allows.Any if plain.none?

      out = out.push(plain.unwrap!)
    end
  end

  for key in structs
    if cx.structs[key].any? do |field: Model.Named| field.name == name end
      return Allows.Any if generic_struct?(cx, key)

      out = out.push(T.Type.Struct(key, []))
    end
  end

  return Allows.Any if out.size == 0

  Allows.OneOf(out)
end

def generic_struct?(cx: State.Cx, key: String) -> Bool
  case cx.struct_params.get(key)
    some(params) -> params.size > 0
    none -> false
  end
end

# An operator with the parameter on one side. and, or need two Bools; the others need a literal on the other side.
# Every operator but `*` (String repeat) and the Int-only ones (%, ranges) takes two values of one type.
def binary_uses(binary: Ast.Binary, name: String) -> List[Allows]
  left = named?(binary.left, name)
  right = named?(binary.right, name)
  return [] if !left and !right
  return [Allows.OneOf([T.Type.Bool])] if binary.op == "and" or binary.op == "or"

  other = binary.left
  if left
    other = binary.right
  end

  literal = literal_type(other)
  return [] if literal.none?

  type = literal.unwrap!
  if binary.op == "modulo" or binary.op == "dot-dot" or binary.op == "dot-dot-dot"
    return [Allows.OneOf([T.Type.Int])]
  elsif binary.op == "multiply" and left and T.is?(type, "Int")
    return [Allows.OneOf([T.Type.Int, T.Type.String])]
  elsif binary.op == "multiply" and right and T.is?(type, "String")
    return [Allows.OneOf([T.Type.Int])]
  end

  [Allows.OneOf([type])]
end

# The type of a number, string or Bool literal.
def literal_type(expr: Ast.Expr) -> Optional[T.Type]
  case expr
    Ast.Expr.Literal(literal) ->
      case literal.value
        Ast.LitValue.Whole(_) -> some(T.Type.Int)
        Ast.LitValue.Real(_) -> some(T.Type.Float)
        Ast.LitValue.Text(_) -> some(T.Type.String)
        Ast.LitValue.Flag(_) -> some(T.Type.Bool)
        _ -> none
      end

    _ -> none
  end
end

def named?(expr: Ast.Expr, name: String) -> Bool
  case expr
    Ast.Expr.Name(ref) -> ref.name == name
    _ -> false
  end
end

def has?(types: List[T.Type], type: T.Type) -> Bool = types.any? do |known: T.Type| T.same?(known, type) end
