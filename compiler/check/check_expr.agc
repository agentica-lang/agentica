## Expressions. check_expression is the function that
## Cx.expression holds: every part of the checker reaches an expression through it. It counts the nesting
## (CHECK-TOO-DEEP), checks the node by its kind, records the type by node id, and refuses a Void value that is not a
## completion.

import {ENTRIES} from "../catalog/builtins"
import Failure from "../diagnostics/problem"
import Ast from "../syntax/ast"
import Source from "../syntax/source"
import T from "../syntax/types"
import BuiltinRef from "builtin_ref"
import {REFS_MODULE} from "builtin_ref"
import Args from "check_args"
import Calls from "check_call"
import Help from "check_help"
import {ERROR_TEXT_HELP} from "check_help"
import Methods from "check_method"
import CheckRegex from "check_regex"
import Rules from "check_rules"
import State from "check_state"
import Statements from "check_stmt"
import CheckTypes from "check_types"

## Checks an expression against the type the context expects (Unknown when none). completion says a Void value is
## allowed here: a statement, the last expression of a block, a return.
def check_expression(
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
  if T.is?(checked.type, "Void") and !completion
    return error(
      State.fail(cx, checked.st, "CHECK-VOID-VALUE", "a Void call has no value; use it as a statement", span),
    )
  end

  actual = checked.type
  if !T.unknown?(expected) and !matches_expected?(node, expected)
    actual = try State.ensure(cx, checked.st, checked.type, expected, span)
  end

  recorded = State.record_type(checked.st, Ast.expr_id(node), checked.type)
  ok(State.Out(st: recorded.with(nest: st.nest), type: actual))
end

private

# The types whose left side of == gives the right side its expected type (check_sides).
EXPECTING_SIDES = Set.new(["List", "Map", "Set", "Optional", "Result", "Struct", "Enum"])

# The operators on two numbers, and of those the ones that give a number: an integer literal on one side takes the
# narrow type of the other side (check_sides).
NUMBER_OPERATORS = Set.new([
  "plus",
  "minus",
  "multiply",
  "divide",
  "modulo",
  "less",
  "less-equal",
  "greater",
  "greater-equal",
  "equal",
  "not-equal",
])

# What the two sides of a binary operator are, checked in order. The right side of a range is checked with the methods
# and fields of its chain marked, so that the help can say a method call on a range needs parentheses.
struct Sides
  st: State.St
  left: T.Type
  right: T.Type
end

# True when the type of the node is the expected type without a look: some(x) against Optional[T], ok(x) against
# Result[T] and [x, ...] against List[T], T known. check_some, check_ok and check_list check x against T, so the
# type they build around x's passes Types.same?. Comparing it again at each level of nested some(...) walks the whole
# type below, quadratic in the depth.
def matches_expected?(node: Ast.Expr, expected: T.Type) -> Bool
  case node
    Ast.Expr.Call(call) ->
      if call.args.size != 1
        return false
      elsif call.name == "some"
        return known_item?(expected, "Optional")
      end

      call.name == "ok" and known_item?(expected, "Result")
    Ast.Expr.ListLit(list) -> list.elements.size > 0 and known_item?(expected, "List")
    _ -> false
  end
end

# True when the type is a word (List, Optional, Result) of a known type.
def known_item?(type: T.Type, word: String) -> Bool = T.is?(type, word) and !T.unknown?(T.item(type))

# An Int literal past the largest Int is CHECK-INT-RANGE, except this one under a minus.
def int_min_digits() -> String = "9223372036854775808"

# The type of the node by its kind, before the Void and expected-type checks.
def expression_inside(cx: State.Cx, st: State.St, node: Ast.Expr, expected: T.Type) -> Result[State.Out]
  try chain_after_end(cx, st, node)
  case node
    Ast.Expr.Literal(found) -> check_literal(cx, st, found, expected)
    Ast.Expr.Name(found) -> check_name(cx, st, found)
    Ast.Expr.Unary(found) -> check_unary(cx, st, found, expected)
    Ast.Expr.Binary(found) -> check_binary(cx, st, found, expected)
    Ast.Expr.Call(found) -> Calls.check_call(cx, st, found, expected)
    Ast.Expr.EnumConstructor(found) ->
      Calls.check_enum_constructor(
        cx,
        st,
        found.enum_name,
        found.variant_name,
        found.args,
        found.named.size,
        found.span,
        expected,
      )
    Ast.Expr.FunctionRef(found) -> check_function_ref(cx, st, found, expected)
    Ast.Expr.Invoke(found) -> check_invoke(cx, st, found)
    Ast.Expr.Try(found) -> check_try(cx, st, found, expected)
    Ast.Expr.Construct(found) -> Calls.check_construct(cx, st, found, expected)
    Ast.Expr.Update(found) -> Calls.check_struct_update(cx, st, found)
    Ast.Expr.ListLit(found) -> check_list(cx, st, found, expected)
    Ast.Expr.MapLit(found) -> check_map(cx, st, found, expected)
    Ast.Expr.FieldAccess(found) -> Methods.check_field_access(cx, st, found, expected)
    Ast.Expr.MethodCall(found) -> Methods.check_method(cx, st, found, expected)
    Ast.Expr.Typed(found) -> ok(State.Out(st: st, type: found.type))
    Ast.Expr.BlockLit(found) -> check_block_lit(cx, st, found, expected)
    Ast.Expr.Interpolation(found) -> check_interpolation(cx, st, found)
    Ast.Expr.Index(found) -> check_index(cx, st, found)
    Ast.Expr.TypeName(found) -> check_type_name(cx, st, found)
    Ast.Expr.ConstRef(found) -> check_const_ref(cx, st, found)
    Ast.Expr.RegexLit(found) -> CheckRegex.check_regex(cx, st, found)
    Ast.Expr.EagLit(found) -> State.expr(cx, st, found.call, T.Type.Unknown)
    Ast.Expr.Case(found) -> Statements.check_case_value(cx, st, found, expected)
  end
end

# An integer literal is Int, or the narrow integer type that its context expects (narrow_target).
def check_literal(cx: State.Cx, st: State.St, node: Ast.Literal, expected: T.Type) -> Result[State.Out]
  target = narrow_target(expected)
  case node.value
    Ast.LitValue.Whole(value) if T.sized_int?(target) ->
      narrow_literal(cx, st, value, "#{value}", false, target, node.span)
    Ast.LitValue.Whole(_) -> ok(State.Out(st: st, type: T.Type.Int))
    Ast.LitValue.Huge(digits) if T.sized_int?(target) -> narrow_literal(cx, st, 0, digits, true, target, node.span)
    Ast.LitValue.Huge(_) ->
      error(State.fail(cx, st, "CHECK-INT-RANGE", "Int literal is outside the signed 64-bit range", node.span))
    Ast.LitValue.Real(number, text) ->
      type = T.Type.Float
      if T.is?(target, "Float32")
        type = T.Type.Float32
      end

      real_literal(cx, st, number, text, type, node.span)
    Ast.LitValue.Text(_) -> ok(State.Out(st: st, type: T.Type.String))
    Ast.LitValue.Flag(_) -> ok(State.Out(st: st, type: T.Type.Bool))
    Ast.LitValue.Nothing -> ok(State.Out(st: st, type: T.Type.Nil))
  end
end

# The sized type that a number literal takes where `expected` is expected, or Unknown: an integer literal takes a
# narrow integer type and is otherwise an Int, a float literal takes Float32 and is otherwise a Float.
def narrow_target(expected: T.Type) -> T.Type
  return expected if sized?(expected)

  T.Type.Unknown
end

# True for the sized integer types and Float32, which a literal takes from its context.
def sized?(type: T.Type) -> Bool = T.sized_int?(type) or T.is?(type, "Float32")

# A float literal of type (Float or Float32), with its value and its text: CHECK-FLOAT-RANGE when it rounds to an
# infinity there.
def real_literal(
  cx: State.Cx,
  st: State.St,
  number: Float,
  text: String,
  type: T.Type,
  span: Source.Span,
) -> Result[State.Out]
  return ok(State.Out(st: st, type: type)) if !T.float_overflow?(type, number, text)

  error(State.fail(cx, st, "CHECK-FLOAT-RANGE", T.float_outside(type, text), span))
end

# An integer literal of the narrow type `target`: CHECK-INT-RANGE when its value is outside the type. `text` is
# what the
# message shows: the decimal value, or for a huge literal, past the Int range, its digits, which fit no type; either
# with the minus folded in.
def narrow_literal(
  cx: State.Cx,
  st: State.St,
  value: Int,
  text: String,
  huge: Bool,
  target: T.Type,
  span: Source.Span,
) -> Result[State.Out]
  fits = T.narrow_fits?(target, value)
  if huge
    fits = T.uint64?(target) and T.uint64_digits_fit?(text)
  end

  return error(State.fail(cx, st, "CHECK-INT-RANGE", T.narrow_outside(target, text), span)) if !fits

  ok(State.Out(st: st, type: target))
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
  return ok(State.Out(st: State.read(st, binding.unwrap!), type: binding.unwrap!.type)) if binding.some?

  if cx.functions.has_key?(node.name) or ENTRIES.has_key?(node.name)
    return error(
      State.fail(cx, st, "CHECK-UNKNOWN-NAME", "\"#{node.name}\" is a function; functions are not values", node.span),
    )
  end

  help = name_help(cx, st, node.name)
  error(State.fail_maybe(cx, st, "CHECK-UNKNOWN-NAME", "unknown name \"#{node.name}\"", node.span, help))
end

# The help of an unknown name: a close name in scope, or the name another language uses.
def name_help(cx: State.Cx, st: State.St, name: String) -> String
  guess = Help.near(name, State.visible_names(cx, st), [])
  return guess if guess != ""

  Help.foreign(cx.help, name)
end

# A constant is read after its initializer was checked, because the constants are checked in dependency order.
def check_const_ref(cx: State.Cx, st: State.St, node: Ast.ConstRef) -> Result[State.Out]
  type = cx.constants.get(node.name)
  return error(State.fail(cx, st, "CHECK-INTERNAL", "constant read before it was checked", node.span)) if type.none?

  ok(State.Out(st: st, type: type.unwrap!))
end

def check_type_name(cx: State.Cx, st: State.St, node: Ast.TypeName) -> Result[State.Out]
  error(
    State.fail_maybe(
      cx,
      st,
      "CHECK-TYPE-MISMATCH",
      "a type name is only valid as a JSON type argument or before .members or .codec",
      node.span,
      Help.foreign(cx.help, node.name),
    ),
  )
end

# &name. A generic function is a value only where the expected Fn type fixes each of its type parameters (a type
# parameter of the enclosing function counts as fixed); the type is then the Fn type with them put in.
def check_function_ref(cx: State.Cx, st: State.St, node: Ast.FunctionRef, expected: T.Type) -> Result[State.Out]
  entry = cx.functions.get(node.name)
  return check_builtin_ref(cx, st, node) if entry.none?

  signature = entry.unwrap!
  type = T.Type.Fn(signature.params, signature.result)
  return ok(State.Out(st: st, type: type)) if signature.type_parameters.size == 0

  found = CheckTypes.learn(type, expected, {})
  unresolved = signature.type_parameters.filter do |name: String| !found.has_key?(name) end
  if unresolved.size > 0
    return error(
      State.fail_help(
        cx,
        st,
        "CHECK-ENUM-TYPE-INFERENCE",
        "cannot infer type parameter(s) #{unresolved.join(", ")} of #{T.display_name(node.name)}",
        node.span,
        "a generic function is a value only where the Fn type is known, such as f: Fn[List[Int], Int, Int] = &name",
      ),
    )
  end

  current = try CheckTypes.check_json_needs(cx, st, node.name, found, [], [], node.span)
  ok(State.Out(st: current, type: CheckTypes.substitute(type, found)))
end

# &Time.now_ms or &Int.to_s (builtin_ref.agc): the Fn type of the builtin, and the prelude function that calls it
# recorded by the id of the reference, as for a call of a prelude method.
def check_builtin_ref(cx: State.Cx, st: State.St, node: Ast.FunctionRef) -> Result[State.Out]
  case BuiltinRef.find(node.name)
    BuiltinRef.Found.Missing ->
      error(
        State.fail_maybe(
          cx,
          st,
          "CHECK-UNKNOWN-NAME",
          "a function reference requires a declared function",
          node.span,
          missing_ref_help(cx, node.name),
        ),
      )
    BuiltinRef.Found.Refused(help) ->
      error(
        State.fail_help(
          cx,
          st,
          "CHECK-UNKNOWN-NAME",
          "#{T.display_name(node.name)} cannot be a function value",
          node.span,
          help,
        ),
      )
    BuiltinRef.Found.Builtin(ref) ->
      recorded = st.with(bodies: st.bodies.put(node.id, "#{REFS_MODULE}::#{node.name}"))
      ok(State.Out(st: recorded, type: BuiltinRef.fn_type(ref)))
  end
end

# The help of &name when no function or builtin has the name: the Ruby form of an old or foreign name of a builtin
# (&String.trim, &String.from_int), or "".
def missing_ref_help(cx: State.Cx, name: String) -> String
  help = Help.foreign(cx.help, name)
  return help if help != ""

  cx.help.kind_methods.get(name).unwrap_or("")
end

# target.call(args): the target is a function value and the arguments match its parameters.
def check_invoke(cx: State.Cx, st: State.St, node: Ast.Invoke) -> Result[State.Out]
  target = try State.expr(cx, st, node.target, T.Type.Unknown)
  if !T.is?(target.type, "Fn")
    return error(State.fail(cx, target.st, "CHECK-TYPE-MISMATCH", ".call requires a function value", node.span))
  end

  Methods.apply_function(cx, target.st, target.type, node.args, node.span)
end

# try needs a function, or a block, that returns a Result (a block with an inferred result qualifies only when it must
# give a Result), and an operand that is a Result. In the block of a Lazy method any `try` works: its error ends the
# pipeline and is the terminal's result, so it is recorded for the lowering (try-step).
def check_try(cx: State.Cx, st: State.St, node: Ast.TryExpr, expected: T.Type) -> Result[State.Out]
  if !State.try_allowed?(st)
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
  if !T.is?(out.type, "Result")
    return error(State.mismatch(cx, out.st, T.Type.Result(T.Type.Var("T")), out.type, Ast.expr_span(node.operand)))
  end

  after = out.st
  if st.step
    after = after.with(step_tries: after.step_tries.add(node.id))
  end

  ok(State.Out(st: after, type: T.item(out.type)))
end

def check_interpolation(cx: State.Cx, st: State.St, node: Ast.Interpolation) -> Result[State.Out]
  current = st
  for part in node.parts
    case part
      Ast.Part.Code(code) ->
        out = try State.expr(cx, current, code, T.Type.Unknown)
        try Rules.ensure_printable(cx, out.st, out.type, Ast.expr_span(code))
        current = out.st
      Ast.Part.Text(_) -> current = current
    end
  end

  ok(State.Out(st: current, type: T.Type.String))
end

# CHECK-CHAIN-AFTER-END: a method call, field, `.call`, `.with`, index or `|>` right after the `end` of a `do` block,
# as in `xs.map do |x| f(x) end.join(", ")`. The parser keeps no node for parentheses, and fmt prints `(... end).size`
# as `... end.size`, so parentheses do not hide it. A block in braces and a lambda may be chained. A pipe into a method
# is a method call that the linker made (Calls.piped_method?), and is reported as the `|>` it was written as.
def chain_after_end(cx: State.Cx, st: State.St, node: Ast.Expr) -> Result[Bool]
  case node
    Ast.Expr.FieldAccess(found) -> chain_link(cx, st, found.target, found.name_span, "a method call", "")
    Ast.Expr.MethodCall(found) if Calls.piped_method?(found) ->
      chain_link(cx, st, found.target, found.span, "|>", step_text(found.name, found.args.size))
    Ast.Expr.MethodCall(found) ->
      chain_link(cx, st, found.target, found.name_span, "a method call", step_text(found.name, found.args.size))
    Ast.Expr.Invoke(found) -> chain_link(cx, st, found.target, found.span, "a method call", "")
    Ast.Expr.Update(found) -> chain_link(cx, st, found.target, found.span, "a method call", "")
    Ast.Expr.Index(found) -> chain_link(cx, st, found.target, found.span, "an index", "")
    Ast.Expr.Call(found) if found.piped and found.args.size > 0 ->
      chain_link(cx, st, found.args[0], found.span, "|>", step_text(T.display_name(found.name), found.args.size - 1))
    _ -> ok(true)
  end
end

# A pipe step as a help writes it: `name()`, or `name(...)` when it has arguments of its own.
def step_text(name: String, count: Int) -> String
  return "#{name}(...)" if count > 0

  "#{name}()"
end

# The error when `target` ends with a `do` block. The span goes from that `end` (one token, on one line) to the end of
# `link`, the name, index or call that follows it. The help shows the block as a lambda in the parentheses, followed
# by `step` as a pipe step when the link is a method call with `()` or a pipe (`step` is "" for a name without `()`,
# which may be a struct field, an index, `.call` and `.with`), then a block in braces when it fits, then a name for
# the result.
def chain_link(
  cx: State.Cx,
  st: State.St,
  target: Ast.Expr,
  link: Source.Span,
  what: String,
  step: String,
) -> Result[Bool]
  found = do_block(target)
  return ok(true) if found.none?

  stop = found.unwrap!.span.stop
  start = Source.Position(offset: stop.offset - 3, line: stop.line, column: stop.column - 3)
  help = "pass a lambda in the parentheses: #{lambda_form(cx, target, found.unwrap!, step)}"
  if braces_fit?(cx, target)
    help = "#{help}; or, outside a condition, a one-line block in braces: {#{block_bars(found.unwrap!.params)} ... }"
  end

  help = "#{help}; or bind the result to a name first"
  error(
    State.fail_help(
      cx,
      st,
      "CHECK-CHAIN-AFTER-END",
      "#{what} after the end of a do block",
      Source.Span(start: start, stop: link.stop),
      help,
    ),
  )
end

# The call `target`, which ends with `block`, written with the block as a lambda in its parentheses and `step` piped
# after it: `xs |> map(->(x) { ... }) |> join(...)`. A method call and a piped call show their receiver (`...` when it
# is long), and a link with no pipe form (`step` is "") follows a method call as `xs.map(->(x) { ... })`.
def lambda_form(cx: State.Cx, target: Ast.Expr, block: Ast.BlockLit, step: String) -> String
  lambda = "-> { ... }"
  if block.params.size > 0
    names = block.params.map do |param: Ast.BlockParam| param.name end
    lambda = "->(#{names.join(", ")}) { ... }"
  end

  name = ""
  others = 0
  piped = false
  receiver: Optional[Ast.Expr] = none
  case target
    Ast.Expr.MethodCall(call) ->
      name = call.name
      others = call.args.size - 1
      piped = Calls.piped_method?(call)
      receiver = some(call.target)
    Ast.Expr.Call(call) ->
      name = T.display_name(call.name)
      others = call.args.size - 1
      if call.piped and call.args.size > 0
        others -= 1
        piped = true
        receiver = some(call.args[0])
      end

    _ -> name = name
  end

  if others > 0
    lambda = "..., #{lambda}"
  end

  form = "#{name}(#{lambda})"
  case receiver
    some(value) ->
      text = Calls.extent_text(cx, value)
      if text.length > 40 or text.include?("\n")
        text = "..."
      end

      joint = "."
      if piped or step != ""
        joint = " |> "
      end

      form = "#{text}#{joint}#{form}"
    none -> form = form
  end

  return form if step == ""

  "#{form} |> #{step}"
end

# The `do` block that ends the call `target`: its last argument, when that is a block that is not in braces.
def do_block(target: Ast.Expr) -> Optional[Ast.BlockLit]
  args: List[Ast.Expr] = []
  case target
    Ast.Expr.Call(call) -> args = call.args
    Ast.Expr.MethodCall(call) -> args = call.args
    _ -> return none
  end

  return none if args.size == 0

  case args[args.size - 1]
    Ast.Expr.BlockLit(found) if !found.braces and !found.lambda -> some(found)
    _ -> none
  end
end

# Whether the block of `target` may be written in braces: the call has no other argument, no `()` and is not piped. The
# checker does not know whether the call is in a condition, where braces need parentheses, so the help says so.
def braces_fit?(cx: State.Cx, target: Ast.Expr) -> Bool
  case target
    Ast.Expr.Call(call) -> !call.piped and !call.parenthesized and call.args.size == 1
    Ast.Expr.MethodCall(call) -> call.args.size == 1 and !paren_after_name?(cx, call.name_span)
    _ -> false
  end
end

# Whether the source has `(` right after the method name that ends at `name` (`xs.map() do`); true without the text.
def paren_after_name?(cx: State.Cx, name: Source.Span) -> Bool
  text = cx.texts.get(cx.file)
  return true if text.none? or name.stop.offset < 0 or name.stop.offset >= text.unwrap!.length

  text.unwrap!.slice(name.stop.offset, 1) == "("
end

# The parameters of a block as its head writes them: " |a, b|", or "" when it has none.
def block_bars(params: List[Ast.BlockParam]) -> String
  return "" if params.size == 0

  names = params.map do |param: Ast.BlockParam| param.name end
  " |#{names.join(", ")}|"
end

# A block or a lambda where a function is expected, or anywhere a type is not demanded.
def check_block_lit(cx: State.Cx, st: State.St, node: Ast.BlockLit, expected: T.Type) -> Result[State.Out]
  if T.unknown?(expected)
    return Statements.check_block_body(cx, st, node, none, T.Type.Unknown, none)
  elsif !T.is?(expected, "Fn") and node.lambda
    return error(
      State.fail(cx, st, "CHECK-TYPE-MISMATCH", "expected #{T.to_text(expected)}, found a lambda", node.span),
    )
  elsif !T.is?(expected, "Fn")
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

  Statements.check_block_body(cx, st, node, some(T.params(expected)), T.result(expected), none)
end

# The type of a list with items is built from the first item's checked type or the expected item that every item
# passed, which top_names (lowering.agc) and matches_expected? rely on.
def check_list(cx: State.Cx, st: State.St, node: Ast.ListLit, expected: T.Type) -> Result[State.Out]
  if !T.unknown?(expected) and !T.is?(expected, "List")
    return error(State.fail(cx, st, "CHECK-TYPE-MISMATCH", "expected #{T.to_text(expected)}, found a list", node.span))
  end

  wanted = T.Type.Unknown
  if T.is?(expected, "List")
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

  ok(State.Out(st: current, type: T.Type.List(element)))
end

def check_map(cx: State.Cx, st: State.St, node: Ast.MapLit, expected: T.Type) -> Result[State.Out]
  if !T.unknown?(expected) and !T.is?(expected, "Map")
    return error(State.fail(cx, st, "CHECK-TYPE-MISMATCH", "expected #{T.to_text(expected)}, found a map", node.span))
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
          "annotate the variable: m: Map[String, Int] = {}; " +
          "a parameter, a field or a function result also gives the type",
        ),
      )
    end

    return ok(State.Out(st: st, type: expected))
  end

  wanted_key = T.Type.Unknown
  wanted_value = T.Type.Unknown
  if T.is?(expected, "Map")
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
        "a Map key must be an integer, String, Bytes or Ref, found #{T.to_text(key.type)}",
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

  ok(State.Out(st: current, type: T.Type.Map(key.type, value.type)))
end

def check_index(cx: State.Cx, st: State.St, node: Ast.IndexAccess) -> Result[State.Out]
  target = try State.expr(cx, st, node.target, T.Type.Unknown)
  if T.is?(target.type, "Map")
    index = try State.expr(cx, target.st, node.index, T.key(target.type))
    return ok(State.Out(st: index.st, type: T.value(target.type)))
  elsif T.is?(target.type, "List")
    index = try State.expr(cx, target.st, node.index, T.Type.Int)
    return ok(State.Out(st: index.st, type: T.item(target.type)))
  elsif T.is?(target.type, "Bytes")
    index = try State.expr(cx, target.st, node.index, T.Type.Int)
    return ok(State.Out(st: index.st, type: T.Type.Int))
  end

  error(
    State.fail_maybe(
      cx,
      target.st,
      "CHECK-NOT-INDEXABLE",
      "indexing needs a list, a map or a Bytes, found #{T.to_text(target.type)}",
      node.span,
      index_help(target.type),
    ),
  )
end

def index_help(target: T.Type) -> String
  if T.is?(target, "String")
    return (
      "strings cannot be indexed: s.at(i) reads one character, s.slice(start, length) a part, " +
      "s.split(\"\") gives all characters"
    )
  elsif T.is?(target, "Result")
    return "unwrap the Result first: r.unwrap!, try r inside a function that returns Result, or case r"
  elsif T.is?(target, "Struct")
    return "read a field with .name"
  elsif T.is?(target, "Set")
    return "sets have no positions: s.include?(x) tests membership, s.to_a gives a list in insertion order"
  end

  ""
end

# - and not. -9223372036854775808 is the one literal that only fits under a minus.
def check_unary(cx: State.Cx, st: State.St, node: Ast.Unary, expected: T.Type) -> Result[State.Out]
  target = narrow_target(expected)
  if node.op == "minus"
    # -1e39 past the largest Float32 is the error of the whole literal, minus included.
    try negative_real(cx, st, node, target)
  end

  inner = T.Type.Unknown
  if node.op == "minus" and !Args.integer_literal?(node.operand)
    # -(1 + 2) and -1.5: the tree under the minus takes the sized type too.
    inner = fitting(node.operand, target)
  end

  operand = try unary_operand(cx, st, node, inner)
  if node.op == "minus" and T.sized_int?(target) and Args.integer_literal?(node.operand)
    # A minus before an integer literal is part of it: -128 is an Int8.
    return negative_literal(cx, operand.st, node, target)
  end

  if node.op == "minus" and T.unsigned?(operand.type)
    help = "an unsigned value has no minus; write 0 - x, which halts below zero"
    message = "unary \"-\" expects a signed number, found #{T.to_text(operand.type)}"
    return error(State.fail_help(cx, operand.st, "CHECK-TYPE-MISMATCH", message, node.op_span, help))
  end

  if node.op == "minus"
    if !CheckTypes.number?(operand.type)
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

  if !T.is?(operand.type, "Bool")
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

  ok(State.Out(st: operand.st, type: T.Type.Bool))
end

# CHECK-FLOAT-RANGE at a minus and the float literal after it, in Float32 when that is the target, else in Float.
def negative_real(cx: State.Cx, st: State.St, node: Ast.Unary, target: T.Type) -> Result[Void]
  type = T.Type.Float
  if T.is?(target, "Float32")
    type = T.Type.Float32
  end

  case node.operand
    Ast.Expr.Literal(found) ->
      case found.value
        Ast.LitValue.Real(number, text) if T.float_overflow?(type, number, text) ->
          error(State.fail(cx, st, "CHECK-FLOAT-RANGE", T.float_outside(type, "-#{text}"), node.span))
        _ -> ok()
      end

    _ -> ok()
  end
end

# -N where the narrow type `target` is expected, N an integer literal (integer_literal?).
def negative_literal(cx: State.Cx, st: State.St, node: Ast.Unary, target: T.Type) -> Result[State.Out]
  case node.operand
    Ast.Expr.Literal(found) ->
      case found.value
        Ast.LitValue.Whole(value) -> narrow_literal(cx, st, 0 - value, "-#{value}", false, target, node.span)
        Ast.LitValue.Huge(digits) -> narrow_literal(cx, st, 0, "-#{digits}", true, target, node.span)
        _ -> error(State.fail(cx, st, "CHECK-INTERNAL", "not an integer literal", node.span))
      end

    _ -> error(State.fail(cx, st, "CHECK-INTERNAL", "not an integer literal", node.span))
  end
end

def unary_operand(cx: State.Cx, st: State.St, node: Ast.Unary, expected: T.Type) -> Result[State.Out]
  return ok(State.Out(st: st, type: T.Type.Int)) if node.op == "minus" and min_literal?(node.operand)

  out = try State.expr_completion(cx, st, node.operand, expected)
  if T.is?(out.type, "Void")
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

  ok(out)
end

def min_literal?(node: Ast.Expr) -> Bool
  case node
    Ast.Expr.Literal(found) ->
      case found.value
        Ast.LitValue.Huge(digits) -> digits == int_min_digits()
        _ -> false
      end

    _ -> false
  end
end

# -5.abs is -(5.abs): the help says to write (-5).abs.
def void_negation_help(node: Ast.Unary) -> String
  return "" if node.op != "minus"

  case node.operand
    Ast.Expr.MethodCall(call) ->
      case call.target
        Ast.Expr.Literal(literal) ->
          case literal.value
            Ast.LitValue.Whole(n) -> "-#{n}.#{call.name} is -(#{n}.#{call.name}); write (-#{n}).#{call.name}"
            _ -> ""
          end

        _ -> ""
      end

    _ -> ""
  end
end

def check_sides(cx: State.Cx, st: State.St, node: Ast.Binary, expected: T.Type) -> Result[Sides]
  return literal_sides(cx, st, node, expected) if NUMBER_OPERATORS.include?(node.op) and Args.literal_tree?(node.left)

  left = try State.expr(cx, st, node.left, T.Type.Unknown)
  if node.op == "dot-dot" or node.op == "dot-dot-dot"
    chained = left.st.with(range_chain: chain_ids(node.right))
    right = try State.expr(cx, chained, node.right, T.Type.Unknown)
    return ok(Sides(st: right.st.with(range_chain: left.st.range_chain), left: left.type, right: right.type))
  end

  # A collection, Optional, Result, struct or enum on the left of == gives its type to the right side, so that
  # `x == none`, `xs == []`, `r == ok(1)` and `m == {}` check. Other types keep the mismatch at the operator. A list on
  # the left of + does the same, so that `xs + []` checks.
  wanted = T.Type.Unknown
  if (node.op == "equal" or node.op == "not-equal") and EXPECTING_SIDES.include?(T.tag(left.type))
    wanted = left.type
  elsif node.op == "plus" and T.is?(left.type, "List")
    wanted = left.type
  elsif NUMBER_OPERATORS.include?(node.op)
    wanted = fitting(node.right, left.type)
  end

  right = try State.expr(cx, left.st, node.right, wanted)
  ok(Sides(st: right.st, left: left.type, right: right.type))
end

# The sides of an operator whose left side is a tree of number literals (literal_tree?). With a literal tree on the
# right too, an arithmetic operator gives both sides the narrow type expected of it: `x: UInt8 = 1 + 2`. Else the right
# side is checked first, and a narrow type of it is the type of the left side: `255 == a`.
def literal_sides(cx: State.Cx, st: State.St, node: Ast.Binary, expected: T.Type) -> Result[Sides]
  if Args.literal_tree?(node.right)
    wanted = T.Type.Unknown
    if Args.ARITHMETIC_OPERATORS.include?(node.op)
      wanted = narrow_target(expected)
    end

    left = try State.expr(cx, st, node.left, fitting(node.left, wanted))
    right = try State.expr(cx, left.st, node.right, fitting(node.right, wanted))
    return ok(Sides(st: right.st, left: left.type, right: right.type))
  end

  right = try State.expr(cx, st, node.right, T.Type.Unknown)
  left = try State.expr(cx, right.st, node.left, fitting(node.left, right.type))
  ok(Sides(st: left.st, left: left.type, right: right.type))
end

# `type` when it is a sized type that the literals of node take: a sized integer type for a tree of integer literals,
# Float32 for one of float literals. Else Unknown, and a literal keeps its own type.
def fitting(node: Ast.Expr, type: T.Type) -> T.Type
  return type if T.sized_int?(type) and Args.number_tree?(node, false)
  return type if T.is?(type, "Float32") and Args.number_tree?(node, true)

  T.Type.Unknown
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

  ids
end

def check_binary(cx: State.Cx, st: State.St, node: Ast.Binary, expected: T.Type) -> Result[State.Out]
  sides = try check_sides(cx, st, node, expected)
  type = try binary_type(cx, sides, node)
  ok(State.Out(st: sides.st, type: type))
end

# The result type of the operator, or the first rule it breaks.
def binary_type(cx: State.Cx, sides: Sides, node: Ast.Binary) -> Result[T.Type]
  case node.op
    "plus" ->
      try same_types(cx, sides, node, true)
      plus_type(cx, sides, node)
    "minus" -> arithmetic_type(cx, sides, node)
    "multiply" ->
      return repeat_type(cx, sides, node) if T.is?(sides.left, "String") or T.is?(sides.right, "String")

      arithmetic_type(cx, sides, node)
    "divide" -> arithmetic_type(cx, sides, node)
    "modulo" -> modulo_type(cx, sides, node)
    "less" -> comparison_type(cx, sides, node)
    "less-equal" -> comparison_type(cx, sides, node)
    "greater" -> comparison_type(cx, sides, node)
    "greater-equal" -> comparison_type(cx, sides, node)
    "dot-dot" -> range_type(cx, sides, node)
    "dot-dot-dot" -> range_type(cx, sides, node)
    "equal" -> equality_type(cx, sides, node)
    "not-equal" -> equality_type(cx, sides, node)
    "and" -> logical_type(cx, sides, node)
    "or" -> logical_type(cx, sides, node)
    _ -> error(State.fail(cx, sides.st, "CHECK-INTERNAL", "unsupported operator", node.op_span))
  end
end

def type_error(cx: State.Cx, sides: Sides, node: Ast.Binary, message: String, help: String) -> String
  State.fail_maybe(cx, sides.st, "CHECK-TYPE-MISMATCH", message, node.op_span, help)
end

# Both sides have one type. with_to_s adds to the String help that to_s makes a String of the number.
def same_types(cx: State.Cx, sides: Sides, node: Ast.Binary, with_to_s: Bool) -> Result[Bool]
  return ok(true) if T.same?(sides.left, sides.right)

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

  error(Failure.pack(base.with(expected: left, actual: right, labels: labels)))
end

# The method that gives the Int of a sized integer type: to_i, which a UInt64 has as a Result, so to_i! there.
def to_int(type: T.Type) -> String
  return "to_i!" if T.uint64?(type)

  "to_i"
end

def same_help(sides: Sides, with_to_s: Bool) -> String
  either_int = T.is?(sides.left, "Int") or T.is?(sides.right, "Int")
  either_float = T.is?(sides.left, "Float") or T.is?(sides.right, "Float")
  either_string = T.is?(sides.left, "String") or T.is?(sides.right, "String")
  either_error = T.error?(sides.left) or T.error?(sides.right)
  narrow = sides.left
  other = sides.right
  if !T.sized_int?(narrow)
    narrow = sides.right
    other = sides.left
  end

  if T.sized_int?(narrow) and T.sized_int?(other)
    name = T.tag(narrow)
    gives = "x.#{to_int(narrow)} gives the Int of either side"
    if to_int(narrow) != to_int(other)
      gives = "x.#{to_int(narrow)} gives the Int of #{name} values, x.#{to_int(other)} of #{T.tag(other)} values"
    end

    return "make both sides one type: #{gives}, n.to_#{name.downcase}! the #{name} of an Int"
  elsif T.sized_int?(narrow) and T.is?(other, "Int")
    name = T.tag(narrow)
    return (
      "make both sides one type: x.#{to_int(narrow)} gives the Int of a #{name}, " +
      "n.to_#{name.downcase}! the #{name} of an Int"
    )
  elsif T.is?(sides.left, "Float32") and converts_to_float32?(sides.right)
    return "make both sides one type: x.to_float32 gives the Float32 of a #{T.tag(sides.right)}"
  elsif T.is?(sides.right, "Float32") and converts_to_float32?(sides.left)
    return "make both sides one type: x.to_float32 gives the Float32 of a #{T.tag(sides.left)}"
  elsif either_string and either_error
    return ERROR_TEXT_HELP
  elsif either_float and (T.is?(sides.left, "Float32") or T.is?(sides.right, "Float32"))
    return "make both sides one type: x.to_f gives the Float of a Float32, f.to_float32 the Float32 of a Float"
  elsif either_int and either_float
    return "make both sides the same type: n.to_f turns the Int into a Float, " + "x.to_i! truncates the Float"
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

  ""
end

# True for Int and the narrow integer types, which have to_float32; UInt64 has not.
def converts_to_float32?(type: T.Type) -> Bool = T.is?(type, "Int") or (T.sized_int?(type) and !T.uint64?(type))

def plus_type(cx: State.Cx, sides: Sides, node: Ast.Binary) -> Result[T.Type]
  if CheckTypes.number?(sides.left) and CheckTypes.number?(sides.right)
    return ok(sides.left)
  elsif T.is?(sides.left, "String") and T.is?(sides.right, "String")
    return ok(T.Type.String)
  elsif T.is?(sides.left, "Bytes") and T.is?(sides.right, "Bytes")
    return ok(T.Type.Bytes)
  elsif T.is?(sides.left, "List") and T.is?(sides.right, "List")
    # A new list with the items of both, as Ruby's Array#+ (same_types made the item types one).
    return ok(sides.left)
  end

  error(
    type_error(
      cx,
      sides,
      node,
      "\"+\" expects two numbers, two strings, two Bytes or two lists, found #{T.to_text(sides.left)}",
      "",
    ),
  )
end

# `s * n` repeats a String n times, as Ruby's String#*: a String first and an Int count second, never two Strings.
def repeat_type(cx: State.Cx, sides: Sides, node: Ast.Binary) -> Result[T.Type]
  return ok(T.Type.String) if T.is?(sides.left, "String") and T.is?(sides.right, "Int")

  left = T.to_text(sides.left)
  right = T.to_text(sides.right)
  message = "\"*\" repeats a String by an Int count, found #{left} * #{right}"
  error(type_error(cx, sides, node, message, "write the String first and an Int count second: \"ab\" * 3"))
end

def arithmetic_type(cx: State.Cx, sides: Sides, node: Ast.Binary) -> Result[T.Type]
  try same_types(cx, sides, node, false)
  if !CheckTypes.number?(sides.left) or !CheckTypes.number?(sides.right)
    return error(type_error(cx, sides, node, "arithmetic expects two numbers, found #{T.to_text(sides.left)}", ""))
  end

  ok(sides.left)
end

def modulo_type(cx: State.Cx, sides: Sides, node: Ast.Binary) -> Result[T.Type]
  if T.sized_int?(sides.left) or T.sized_int?(sides.right)
    try same_types(cx, sides, node, false)
    return ok(sides.left)
  end

  if !T.is?(sides.left, "Int") or !T.is?(sides.right, "Int")
    help = ""
    if T.is?(sides.left, "String")
      help = "a format string is the first argument of format: format(\"%05d\", n)"
    end

    return error(
      type_error(
        cx,
        sides,
        node,
        "\"%\" expects two Ints, found #{T.to_text(sides.left)} and #{T.to_text(sides.right)}",
        help,
      ),
    )
  end

  ok(T.Type.Int)
end

def comparison_type(cx: State.Cx, sides: Sides, node: Ast.Binary) -> Result[T.Type]
  try same_types(cx, sides, node, false)
  if !CheckTypes.number?(sides.left) or !CheckTypes.number?(sides.right)
    help = ""
    if T.is?(sides.left, "String")
      help = "< <= > >= only take Int or Float; compare Strings with == and !=, or order a List[String] with xs.sort"
    elsif CheckTypes.ref?(sides.left)
      help = "< <= > >= only take Int or Float; order Refs by when they were made with xs.sort or xs.sort_by"
    end

    return error(type_error(cx, sides, node, "comparison expects two numbers, found #{T.to_text(sides.left)}", help))
  end

  ok(T.Type.Bool)
end

def range_type(cx: State.Cx, sides: Sides, node: Ast.Binary) -> Result[T.Type]
  if !T.is?(sides.left, "Int") or !T.is?(sides.right, "Int")
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

  ok(T.Type.Range)
end

def equality_type(cx: State.Cx, sides: Sides, node: Ast.Binary) -> Result[T.Type]
  try same_types(cx, sides, node, true)
  if !CheckTypes.equality?(cx, sides.left)
    message = "#{T.to_text(sides.left)} has no equality"
    gap = CheckTypes.equality_gap(cx, sides.left)
    if gap.why != ""
      message += ": #{gap.why}"
    end

    help = (
      "== compares numbers, Bool, String, nil, ranges, Bytes, JSON.Value, and lists, maps, sets, Optionals, " +
      "Results, structs and enums of those; functions, tasks, channels, handles, C.Pointer, Time.DateTime and a " +
      "generic T have no equality"
    )

    if CheckTypes.instant?(sides.left)
      help = "Time.compare(a, b) == 0 compares two Time.DateTime values by instant; Test.eq compares their fields"
    elsif gap.instant
      help = "a Time.DateTime inside has no ==; compare those values with Time.compare(a, b) == 0"
    end

    base = Failure.problem(
      cx.file,
      sides.st.signature,
      "CHECK-TYPE-MISMATCH",
      message,
      node.op_span,
      State.hint_of(help),
    )

    return error(Failure.pack(base.with(labels: field_labels(cx, gap))))
  end

  ok(T.Type.Bool)
end

# The note on the field that blocks ==, when the field is declared in the file being checked: a note holds a span and
# no file, so a field of another file is left to the message.
def field_labels(cx: State.Cx, gap: CheckTypes.Gap) -> List[Failure.Label]
  return [] if gap.file != cx.file or !gap.field.some?

  [Failure.Label(span: gap.field.unwrap!, text: "this field has no equality")]
end

def logical_type(cx: State.Cx, sides: Sides, node: Ast.Binary) -> Result[T.Type]
  if !T.is?(sides.left, "Bool") or !T.is?(sides.right, "Bool")
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

  ok(T.Type.Bool)
end
