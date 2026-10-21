## Expressions. check_expression is the function that
## Cx.expression holds: every part of the checker reaches an expression through it. It counts the nesting
## (CHECK-TOO-DEEP), checks the node by its kind, records the type by node id, and refuses a Void value that is not a
## completion.

import Ast from "../syntax/ast"
import Calls from "check_call"
import Failure from "../diagnostics/problem"
import Help from "check_help"
import Methods from "check_method"
import Rules from "check_rules"
import State from "check_state"
import Statements from "check_stmt"
import CheckTypes from "check_types"
import T from "../syntax/types"
import {ENTRIES} from "../catalog/builtins"

# What the two sides of a binary operator are, checked in order. The right side of a range is checked with the methods
# and fields of its chain marked, so that the help can say a method call on a range needs parentheses.
struct Sides
  st: State.St
  left: T.Type
  right: T.Type
end

## Checks an expression against the type the context expects (Unknown when none). completion says a Void value is
## allowed here: a statement, the last expression of a block, a return.
export def check_expression(
  cx: State.Cx,
  st: State.St,
  node: Ast.Expr,
  expected: T.Type,
  completion: Bool,
) -> Result[State.Out]
  if st.nest >= State.nesting_limit()
    return error(
      State.fail_help(
        cx,
        st,
        "CHECK-TOO-DEEP",
        "nesting is deeper than #{State.nesting_limit()} levels",
        Ast.expr_span(node),
        "split the code into smaller functions or simpler expressions",
      ),
    )
  end
  checked = try expression_inside(cx, st.with(nest: st.nest + 1), node, expected)
  span = Ast.expr_span(node)
  if T.is(checked.type, "Void") and !completion
    return error(
      State.fail(cx, checked.st, "CHECK-VOID-VALUE", "a Void call has no value; use it as a statement", span),
    )
  end
  actual = try State.ensure(cx, checked.st, checked.type, expected, span)
  recorded = State.record_type(checked.st, Ast.expr_id(node), checked.type)
  return ok(State.Out(st: recorded.with(nest: st.nest), type: actual))
end

# An Int literal past the largest Int is CHECK-INT-RANGE, except this one under a minus.
def int_min_digits() -> String
  return "9223372036854775808"
end

# The type of the node by its kind, before the Void and expected-type checks.
def expression_inside(cx: State.Cx, st: State.St, node: Ast.Expr, expected: T.Type) -> Result[State.Out]
  case node
    Ast.Expr.Literal(found) -> return check_literal(cx, st, found)
    Ast.Expr.Name(found) -> return check_name(cx, st, found)
    Ast.Expr.Unary(found) -> return check_unary(cx, st, found)
    Ast.Expr.Binary(found) -> return check_binary(cx, st, found)
    Ast.Expr.Call(found) -> return Calls.check_call(cx, st, found, expected)
    Ast.Expr.EnumConstructor(found) -> return Calls.check_enum_constructor(
      cx,
      st,
      found.enum_name,
      found.variant_name,
      found.args,
      found.named.size,
      found.span,
      expected,
    )
    Ast.Expr.FunctionRef(found) -> return check_function_ref(cx, st, found)
    Ast.Expr.Invoke(found) -> return check_invoke(cx, st, found)
    Ast.Expr.Try(found) -> return check_try(cx, st, found, expected)
    Ast.Expr.Construct(found) -> return Calls.check_construct(cx, st, found, expected)
    Ast.Expr.Update(found) -> return Calls.check_struct_update(cx, st, found)
    Ast.Expr.ListLit(found) -> return check_list(cx, st, found, expected)
    Ast.Expr.MapLit(found) -> return check_map(cx, st, found, expected)
    Ast.Expr.FieldAccess(found) -> return Methods.check_field_access(cx, st, found, expected)
    Ast.Expr.MethodCall(found) -> return Methods.check_method(cx, st, found, expected)
    Ast.Expr.Typed(found) -> return ok(State.Out(st: st, type: found.type))
    Ast.Expr.BlockLit(found) -> return check_block_lit(cx, st, found, expected)
    Ast.Expr.Interpolation(found) -> return check_interpolation(cx, st, found)
    Ast.Expr.Index(found) -> return check_index(cx, st, found)
    Ast.Expr.TypeName(found) -> return check_type_name(cx, st, found)
    Ast.Expr.ConstRef(found) -> return check_const_ref(cx, st, found)
  end
end

def check_literal(cx: State.Cx, st: State.St, node: Ast.Literal) -> Result[State.Out]
  case node.value
    Ast.LitValue.Whole(number) -> return ok(State.Out(st: st, type: T.Type.Int))
    Ast.LitValue.Huge(digits) -> return error(
      State.fail(cx, st, "CHECK-INT-RANGE", "Int literal is outside the signed 64-bit range", node.span),
    )
    Ast.LitValue.Real(number) -> return ok(State.Out(st: st, type: T.Type.Float))
    Ast.LitValue.Text(text) -> return ok(State.Out(st: st, type: T.Type.String))
    Ast.LitValue.Flag(flag) -> return ok(State.Out(st: st, type: T.Type.Bool))
    Ast.LitValue.Nothing -> return ok(State.Out(st: st, type: T.Type.Nil))
  end
end

# A name in scope. A function name is not a value, and the help of an unknown name is a close name or a name of another
# language.
def check_name(cx: State.Cx, st: State.St, node: Ast.NameRef) -> Result[State.Out]
  if node.name == "_"
    return error(
      State.fail_help(
        cx,
        st,
        "CHECK-UNKNOWN-NAME",
        "\"_\" discards a value and cannot be read",
        node.span,
        "give the value a name where it is bound",
      ),
    )
  end
  binding = State.lookup(st, node.name)
  if binding.ok?
    return ok(State.Out(st: st, type: binding.unwrap!.type))
  end
  if cx.functions.has_key?(node.name) or ENTRIES.has_key?(node.name)
    return error(
      State.fail(
        cx,
        st,
        "CHECK-UNKNOWN-NAME",
        "\"#{node.name}\" is a function; functions are not values",
        node.span,
      ),
    )
  end
  help = name_help(cx, st, node.name)
  return error(State.fail_maybe(cx, st, "CHECK-UNKNOWN-NAME", "unknown name \"#{node.name}\"", node.span, help))
end

# The help of an unknown name: a close name in scope, or the name another language uses.
def name_help(cx: State.Cx, st: State.St, name: String) -> String
  guess = Help.near(name, State.visible_names(cx, st), [])
  if guess != ""
    return guess
  end
  return Help.foreign(cx.help, name)
end

# A constant is read after its initializer was checked, because the constants are checked in dependency order.
def check_const_ref(cx: State.Cx, st: State.St, node: Ast.ConstRef) -> Result[State.Out]
  type = cx.constants.get(node.name)
  if !type.ok?
    return error(State.fail(cx, st, "CHECK-INTERNAL", "constant read before it was checked", node.span))
  end
  return ok(State.Out(st: st, type: type.unwrap!))
end

def check_type_name(cx: State.Cx, st: State.St, node: Ast.TypeName) -> Result[State.Out]
  return error(
    State.fail_maybe(
      cx,
      st,
      "CHECK-TYPE-MISMATCH",
      "a type name is only valid as a JSON type argument",
      node.span,
      Help.foreign(cx.help, node.name),
    ),
  )
end

def check_function_ref(cx: State.Cx, st: State.St, node: Ast.FunctionRef) -> Result[State.Out]
  signature = cx.functions.get(node.name)
  if !signature.ok?
    return error(
      State.fail(cx, st, "CHECK-UNKNOWN-NAME", "a function reference requires a declared function", node.span),
    )
  end
  return ok(State.Out(st: st, type: T.Type.Fn(signature.unwrap!.params, signature.unwrap!.result)))
end

# target.call(args): the target is a function value and the arguments match its parameters.
def check_invoke(cx: State.Cx, st: State.St, node: Ast.Invoke) -> Result[State.Out]
  target = try State.expr(cx, st, node.target, T.Type.Unknown)
  if !T.is(target.type, "Fn")
    return error(State.fail(cx, target.st, "CHECK-TYPE-MISMATCH", ".call requires a function value", node.span))
  end
  params = T.params(target.type)
  if params.size != node.args.size
    return error(State.fail(cx, target.st, "CHECK-ARITY", "wrong number of function arguments", node.span))
  end
  current = target.st
  index = 0
  while index < params.size
    out = try State.expr(cx, current, node.args[index], params[index])
    current = out.st
    index += 1
  end
  return ok(State.Out(st: current, type: T.result(target.type)))
end

# try needs a function, or a block, that returns a Result (a block with an inferred result qualifies only when it must
# give a Result), and an operand that is a Result. In the block of a Lazy method any `try` works: its error ends the
# pipeline and is the terminal's result, so it is recorded for the lowering (try-step).
def check_try(cx: State.Cx, st: State.St, node: Ast.TryExpr, expected: T.Type) -> Result[State.Out]
  if !st.step and !result_context?(st)
    return error(
      State.fail_help(
        cx,
        st,
        "CHECK-TRY-CONTEXT",
        "try requires a function returning Result",
        node.span,
        "return Result[T] from this function, or handle the Result explicitly",
      ),
    )
  end
  wanted = T.Type.Unknown
  if !T.unknown?(expected)
    wanted = T.Type.Result(expected)
  end
  out = try State.expr(cx, st, node.operand, wanted)
  if !T.is(out.type, "Result")
    return error(State.mismatch(cx, out.st, T.Type.Result(T.Type.Var("T")), out.type, Ast.expr_span(node.operand)))
  end
  after = out.st
  if st.step
    after = after.with(step_tries: after.step_tries.add(node.id))
  end
  return ok(State.Out(st: after, type: T.item(out.type)))
end

def result_context?(st: State.St) -> Bool
  case st.result
    State.Slot.Known(type) -> return T.is(type, "Result")
    State.Slot.InferResult -> return true
    State.Slot.Infer -> return false
  end
end

def check_interpolation(cx: State.Cx, st: State.St, node: Ast.Interpolation) -> Result[State.Out]
  current = st
  for part in node.parts
    case part
      Ast.Part.Code(code) ->
        out = try State.expr(cx, current, code, T.Type.Unknown)
        try Rules.ensure_printable(cx, out.st, out.type, Ast.expr_span(code))
        current = out.st
      Ast.Part.Text(text) -> current = current
    end
  end
  return ok(State.Out(st: current, type: T.Type.String))
end

# A block where a function is expected, or anywhere a type is not demanded.
def check_block_lit(cx: State.Cx, st: State.St, node: Ast.BlockLit, expected: T.Type) -> Result[State.Out]
  if T.unknown?(expected)
    return Statements.check_block_body(cx, st, node, Ast.Optional.Absent, T.Type.Unknown, Ast.Optional.Absent)
  elsif !T.is(expected, "Fn")
    return error(
      State.fail_help(
        cx,
        st,
        "CHECK-BLOCK-TARGET",
        "a block is passed where #{T.to_text(expected)} is expected",
        node.span,
        "a block is only allowed when the last parameter is a function (Fn[...])",
      ),
    )
  end
  return Statements.check_block_body(
    cx,
    st,
    node,
    Ast.Optional.Present(T.params(expected)),
    T.result(expected),
    Ast.Optional.Absent,
  )
end

def check_list(cx: State.Cx, st: State.St, node: Ast.ListLit, expected: T.Type) -> Result[State.Out]
  if !T.unknown?(expected) and !T.is(expected, "List")
    return error(
      State.fail(cx, st, "CHECK-TYPE-MISMATCH", "expected #{T.to_text(expected)}, found a list", node.span),
    )
  end
  wanted = T.Type.Unknown
  if T.is(expected, "List")
    wanted = T.item(expected)
  end
  if node.elements.size == 0
    if T.unknown?(wanted)
      return error(
        State.fail_help(
          cx,
          st,
          "CHECK-EMPTY-LIST-TYPE",
          "an empty list needs an expected type, for example \"List[Int]\"",
          node.span,
          "annotate the variable: xs: List[Int] = []; a parameter, a field or a function result also gives the type",
        ),
      )
    end
    return ok(State.Out(st: st, type: expected))
  end
  first = try State.expr(cx, st, node.elements[0], wanted)
  element = wanted
  if T.unknown?(wanted)
    element = first.type
  end
  current = first.st
  index = 1
  while index < node.elements.size
    out = try State.expr(cx, current, node.elements[index], element)
    current = out.st
    index += 1
  end
  return ok(State.Out(st: current, type: T.Type.List(element)))
end

def check_map(cx: State.Cx, st: State.St, node: Ast.MapLit, expected: T.Type) -> Result[State.Out]
  if !T.unknown?(expected) and !T.is(expected, "Map")
    return error(
      State.fail(cx, st, "CHECK-TYPE-MISMATCH", "expected #{T.to_text(expected)}, found a map", node.span),
    )
  end
  if node.entries.size == 0
    if T.unknown?(expected)
      return error(
        State.fail_help(
          cx,
          st,
          "CHECK-EMPTY-MAP-TYPE",
          "an empty map needs an expected type, for example \"Map[String, Int]\"",
          node.span,
          (
            "annotate the variable: m: Map[String, Int] = {}; " +
            "a parameter, a field or a function result also gives the type"
          ),
        ),
      )
    end
    return ok(State.Out(st: st, type: expected))
  end
  wanted_key = T.Type.Unknown
  wanted_value = T.Type.Unknown
  if T.is(expected, "Map")
    wanted_key = T.key(expected)
    wanted_value = T.value(expected)
  end
  first = node.entries[0]
  key = try State.expr(cx, st, first.key, wanted_key)
  if !CheckTypes.key_here?(cx, key.type)
    return error(
      State.fail(
        cx,
        key.st,
        "CHECK-MAP-KEY-TYPE",
        "a Map key must be Int or String, found #{T.to_text(key.type)}",
        Ast.expr_span(first.key),
      ),
    )
  end
  value = try State.expr(cx, key.st, first.value, wanted_value)
  current = value.st
  index = 1
  while index < node.entries.size
    entry = node.entries[index]
    k = try State.expr(cx, current, entry.key, key.type)
    v = try State.expr(cx, k.st, entry.value, value.type)
    current = v.st
    index += 1
  end
  return ok(State.Out(st: current, type: T.Type.Map(key.type, value.type)))
end

def check_index(cx: State.Cx, st: State.St, node: Ast.IndexAccess) -> Result[State.Out]
  target = try State.expr(cx, st, node.target, T.Type.Unknown)
  if T.is(target.type, "Map")
    index = try State.expr(cx, target.st, node.index, T.key(target.type))
    return ok(State.Out(st: index.st, type: T.value(target.type)))
  elsif T.is(target.type, "List")
    index = try State.expr(cx, target.st, node.index, T.Type.Int)
    return ok(State.Out(st: index.st, type: T.item(target.type)))
  end
  return error(
    State.fail_maybe(
      cx,
      target.st,
      "CHECK-NOT-INDEXABLE",
      "indexing needs a list or a map, found #{T.to_text(target.type)}",
      node.span,
      index_help(target.type),
    ),
  )
end

def index_help(target: T.Type) -> String
  if T.is(target, "String")
    return (
      "strings cannot be indexed: s.at(i) reads one character, s.slice(start, length) a part, " +
      "s.split(\"\") gives all characters"
    )
  elsif T.is(target, "Result")
    return "unwrap the Result first: r.unwrap!, try r inside a function that returns Result, or case r"
  elsif T.is(target, "Struct")
    return "read a field with .name"
  elsif T.is(target, "Set")
    return "sets have no positions: s.include?(x) tests membership, s.to_a gives a list in insertion order"
  end
  return ""
end

# - and not. -9223372036854775808 is the one literal that only fits under a minus.
def check_unary(cx: State.Cx, st: State.St, node: Ast.Unary) -> Result[State.Out]
  operand = try unary_operand(cx, st, node)
  if node.op == "minus"
    if !CheckTypes.numeric?(operand.type)
      return error(
        State.fail(
          cx,
          operand.st,
          "CHECK-TYPE-MISMATCH",
          "unary \"-\" expects a number, found #{T.to_text(operand.type)}",
          node.op_span,
        ),
      )
    end
    return ok(operand)
  end
  if !T.is(operand.type, "Bool")
    return error(
      State.fail(
        cx,
        operand.st,
        "CHECK-TYPE-MISMATCH",
        "\"not\" (or \"!\") expects Bool, found #{T.to_text(operand.type)}",
        node.op_span,
      ),
    )
  end
  return ok(State.Out(st: operand.st, type: T.Type.Bool))
end

def unary_operand(cx: State.Cx, st: State.St, node: Ast.Unary) -> Result[State.Out]
  if node.op == "minus" and min_literal?(node.operand)
    return ok(State.Out(st: st, type: T.Type.Int))
  end
  out = try State.expr_completion(cx, st, node.operand, T.Type.Unknown)
  if T.is(out.type, "Void")
    return error(
      State.fail_maybe(
        cx,
        out.st,
        "CHECK-VOID-VALUE",
        "a Void call has no value; use it as a statement",
        Ast.expr_span(node.operand),
        void_negation_help(node),
      ),
    )
  end
  return ok(out)
end

def min_literal?(node: Ast.Expr) -> Bool
  case node
    Ast.Expr.Literal(found) ->
      case found.value
        Ast.LitValue.Huge(digits) -> return digits == int_min_digits()
        _ -> return false
      end
    _ -> return false
  end
end

# -5.abs is -(5.abs): the help says to write (-5).abs.
def void_negation_help(node: Ast.Unary) -> String
  if node.op != "minus"
    return ""
  end
  case node.operand
    Ast.Expr.MethodCall(call) ->
      case call.target
        Ast.Expr.Literal(literal) ->
          case literal.value
            Ast.LitValue.Whole(n) -> return "-#{n}.#{call.name} is -(#{n}.#{call.name}); write (-#{n}).#{call.name}"
            _ -> return ""
          end
        _ -> return ""
      end
    _ -> return ""
  end
end

def check_sides(cx: State.Cx, st: State.St, node: Ast.Binary) -> Result[Sides]
  left = try State.expr(cx, st, node.left, T.Type.Unknown)
  if node.op == "dot-dot" or node.op == "dot-dot-dot"
    chained = left.st.with(range_chain: chain_ids(node.right))
    right = try State.expr(cx, chained, node.right, T.Type.Unknown)
    return ok(Sides(st: right.st.with(range_chain: left.st.range_chain), left: left.type, right: right.type))
  end
  right = try State.expr(cx, left.st, node.right, T.Type.Unknown)
  return ok(Sides(st: right.st, left: left.type, right: right.type))
end

# The ids of the method calls and field accesses along the target chain of an expression.
def chain_ids(node: Ast.Expr) -> List[Int]
  ids: List[Int] = []
  current = node
  going = true
  while going
    case current
      Ast.Expr.MethodCall(call) ->
        ids = ids.push(call.id)
        current = call.target
      Ast.Expr.FieldAccess(access) ->
        ids = ids.push(access.id)
        current = access.target
      _ -> going = false
    end
  end
  return ids
end

def check_binary(cx: State.Cx, st: State.St, node: Ast.Binary) -> Result[State.Out]
  sides = try check_sides(cx, st, node)
  type = try binary_type(cx, sides, node)
  return ok(State.Out(st: sides.st, type: type))
end

# The result type of the operator, or the first rule it breaks.
def binary_type(cx: State.Cx, sides: Sides, node: Ast.Binary) -> Result[T.Type]
  left = sides.left
  right = sides.right
  case node.op
    "plus" ->
      try same_types(cx, sides, node, true)
      return plus_type(cx, sides, node)
    "minus" -> return arithmetic_type(cx, sides, node)
    "multiply" -> return arithmetic_type(cx, sides, node)
    "divide" -> return arithmetic_type(cx, sides, node)
    "modulo" -> return modulo_type(cx, sides, node)
    "less" -> return comparison_type(cx, sides, node)
    "less-equal" -> return comparison_type(cx, sides, node)
    "greater" -> return comparison_type(cx, sides, node)
    "greater-equal" -> return comparison_type(cx, sides, node)
    "dot-dot" -> return range_type(cx, sides, node)
    "dot-dot-dot" -> return range_type(cx, sides, node)
    "equal" -> return equality_type(cx, sides, node)
    "not-equal" -> return equality_type(cx, sides, node)
    "and" -> return logical_type(cx, sides, node)
    "or" -> return logical_type(cx, sides, node)
    _ -> return error(State.fail(cx, sides.st, "CHECK-INTERNAL", "unsupported operator", node.op_span))
  end
end

def type_error(cx: State.Cx, sides: Sides, node: Ast.Binary, message: String, help: String) -> String
  return State.fail_maybe(cx, sides.st, "CHECK-TYPE-MISMATCH", message, node.op_span, help)
end

# Both sides have one type. with_to_s adds to the String help that to_s makes a String of the number.
def same_types(cx: State.Cx, sides: Sides, node: Ast.Binary, with_to_s: Bool) -> Result[Bool]
  if T.same(sides.left, sides.right)
    return ok(true)
  end
  left = T.to_text(sides.left)
  right = T.to_text(sides.right)
  base = Failure.problem(
    cx.file,
    sides.st.signature,
    "CHECK-TYPE-MISMATCH",
    "operator expects two values of the same type, found #{left} and #{right}",
    node.op_span,
    State.hint_of(same_help(sides, with_to_s)),
  )
  labels = [
    Failure.Label(span: Ast.expr_span(node.left), text: "this is #{left}"),
    Failure.Label(span: Ast.expr_span(node.right), text: "this is #{right}"),
  ]
  return error(Failure.pack(base.with(expected: left, actual: right, labels: labels)))
end

def same_help(sides: Sides, with_to_s: Bool) -> String
  either_int = T.is(sides.left, "Int") or T.is(sides.right, "Int")
  either_float = T.is(sides.left, "Float") or T.is(sides.right, "Float")
  either_string = T.is(sides.left, "String") or T.is(sides.right, "String")
  if either_int and either_float
    return (
      "make both sides the same type: n.to_f (Float.from_int) turns the Int into a Float, " +
      "x.to_i! (Float.to_int!) truncates the Float"
    )
  elsif either_string and (either_int or either_float)
    if with_to_s
      return (
        "make both sides Strings with n.to_s or interpolation \"\#{n}\"; " +
        "or make both numbers with s.to_i! or s.to_f!, which halt on text that is not a number"
      )
    end
    return (
      "make both sides numbers: s.to_i! or s.to_f! turns the String into a number, " +
      "and halts on text that is not a number"
    )
  end
  return ""
end

def plus_type(cx: State.Cx, sides: Sides, node: Ast.Binary) -> Result[T.Type]
  if CheckTypes.numeric?(sides.left) and CheckTypes.numeric?(sides.right)
    return ok(sides.left)
  elsif T.is(sides.left, "String") and T.is(sides.right, "String")
    return ok(T.Type.String)
  end
  return error(
    type_error(cx, sides, node, "\"+\" expects two numbers or two strings, found #{T.to_text(sides.left)}", ""),
  )
end

def arithmetic_type(cx: State.Cx, sides: Sides, node: Ast.Binary) -> Result[T.Type]
  try same_types(cx, sides, node, false)
  if !CheckTypes.numeric?(sides.left) or !CheckTypes.numeric?(sides.right)
    return error(type_error(cx, sides, node, "arithmetic expects two numbers, found #{T.to_text(sides.left)}", ""))
  end
  return ok(sides.left)
end

def modulo_type(cx: State.Cx, sides: Sides, node: Ast.Binary) -> Result[T.Type]
  if !T.is(sides.left, "Int") or !T.is(sides.right, "Int")
    return error(
      type_error(
        cx,
        sides,
        node,
        "\"%\" expects two Ints, found #{T.to_text(sides.left)} and #{T.to_text(sides.right)}",
        "",
      ),
    )
  end
  return ok(T.Type.Int)
end

def comparison_type(cx: State.Cx, sides: Sides, node: Ast.Binary) -> Result[T.Type]
  try same_types(cx, sides, node, false)
  if !CheckTypes.numeric?(sides.left) or !CheckTypes.numeric?(sides.right)
    help = ""
    if T.is(sides.left, "String")
      help = "< <= > >= only take Int or Float; compare Strings with == and !=, or order a List[String] with xs.sort"
    end
    return error(type_error(cx, sides, node, "comparison expects two numbers, found #{T.to_text(sides.left)}", help))
  end
  return ok(T.Type.Bool)
end

def range_type(cx: State.Cx, sides: Sides, node: Ast.Binary) -> Result[T.Type]
  if !T.is(sides.left, "Int") or !T.is(sides.right, "Int")
    return error(
      type_error(
        cx,
        sides,
        node,
        "a range expects two Ints, found #{T.to_text(sides.left)} and #{T.to_text(sides.right)}",
        "",
      ),
    )
  end
  return ok(T.Type.Range)
end

def equality_type(cx: State.Cx, sides: Sides, node: Ast.Binary) -> Result[T.Type]
  try same_types(cx, sides, node, true)
  if !CheckTypes.primitive?(sides.left) and !T.is(sides.left, "Range")
    help = ""
    if T.is(sides.left, "Set")
      help = "two sets are equal when each is a subset of the other: a.subset?(b) and b.subset?(a)"
    end
    return error(
      type_error(
        cx,
        sides,
        node,
        "equality is only defined for primitive values and ranges, found #{T.to_text(sides.left)}",
        help,
      ),
    )
  end
  return ok(T.Type.Bool)
end

def logical_type(cx: State.Cx, sides: Sides, node: Ast.Binary) -> Result[T.Type]
  if !T.is(sides.left, "Bool") or !T.is(sides.right, "Bool")
    return error(
      type_error(
        cx,
        sides,
        node,
        "logical operator expects two Bools, found #{T.to_text(sides.left)} and #{T.to_text(sides.right)}",
        "",
      ),
    )
  end
  return ok(T.Type.Bool)
end
