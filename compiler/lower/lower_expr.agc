## Expressions and calls. Every function takes the register to compute into (want, or -1 for a new one) and returns the
## register that holds the value. The registers above it are free again, except the one returned when none was asked
## for.
##
## A method call or a field access that names a builtin is not rewritten in compiler/: the lowering reads its Resolved
## and lowers the synthetic node it describes.

import Model from "../catalog/builtin_model"
import Builtins from "../catalog/builtins"
import State from "../check/check_state"
import Defaults from "../check/defaults"
import Ast from "../syntax/ast"
import AstWalk from "../syntax/ast_walk"
import Names from "../syntax/prelude_name"
import Source from "../syntax/source"
import Types from "../syntax/types"
import Ir from "ir"
import Data from "lower_data"
import Program from "lower_program"
import Scans from "lower_scan"
import Lowering from "lower_state"
import {
  CODEC_BUILTINS, CODEC_MEMBERS, CODEC_NAME, FLOAT_OPS, INT_MIN, INT_MIN_DIGITS, INT_OPS, NATIVE_LAYOUTS, STRING_OPS,
  VM_BUILTINS,
} from "lower_tables"

## Lowers an expression into the register want (-1: any). void allows a Void value (a statement, a completion); known
## skips the type check of an item whose list or map, or payload whose some(...) or ok(...), was checked as a whole.
def lower_expression(
  cx: Lowering.Cx,
  fx: Lowering.Fx,
  expr: Ast.Expr,
  want: Int,
  void: Bool,
  known: Bool,
) -> Result[Lowering.Out]
  case expr
    Ast.Expr.Call(node) ->
      return lower_optional(cx, fx, node, want, void, true, false) if known and optional_call?(node)

      lower_call(cx, fx, node, want, void, known and ok_call?(node), false)
    Ast.Expr.Binary(node) ->
      try typed(cx, expr, known)
      lower_binary(cx, fx, node, want)
    Ast.Expr.Name(node) ->
      try typed(cx, expr, known)
      lower_name(fx, node, want)
    Ast.Expr.Literal(node) ->
      try typed(cx, expr, known)
      lower_literal(cx, fx, node, want)
    Ast.Expr.ConstRef(node) ->
      try typed(cx, expr, known)
      lower_const_read(cx, fx, node, want)
    Ast.Expr.RegexLit(node) ->
      # A literal in a function body is a constant that lowering.agc made for it; in a constant it is its call.
      hoisted = Scans.regex_constant(node)
      if cx.reads.has_key?(hoisted)
        return lower_const_read(cx, fx, Ast.ConstRef(id: node.id, name: hoisted, span: node.span), want)
      end

      lower_expression(cx, fx, node.call, want, false, known)
    Ast.Expr.EagLit(node) -> lower_expression(cx, fx, node.call, want, false, known)
    Ast.Expr.Unary(node) -> lower_unary_checked(cx, fx, expr, node, want, known)
    Ast.Expr.FieldAccess(node) -> lower_field_checked(cx, fx, expr, node, want, void, known)
    Ast.Expr.MethodCall(node) -> lower_method_checked(cx, fx, expr, node, want, void, known)
    Ast.Expr.Typed(node) ->
      try Lowering.require_type(cx, node.target, false, node.type)
      lower_expression(cx, fx, node.target, want, false, false)
    Ast.Expr.TypeName(node) -> lower_type_name(cx, fx, node, want)
    Ast.Expr.Interpolation(node) -> lower_interpolation(cx, fx, node, want)
    Ast.Expr.Try(node) ->
      try Lowering.require_type(cx, expr, void, Lowering.type_of(cx, expr))
      lower_try(cx, fx, node, want)
    Ast.Expr.Invoke(node) ->
      try Lowering.require_type(cx, expr, void, Lowering.type_of(cx, expr))
      lower_invoke(cx, fx, node, want)
    Ast.Expr.ListLit(node) ->
      try typed(cx, expr, known)
      Data.lower_list(cx, fx, node, want)
    Ast.Expr.MapLit(node) ->
      try typed(cx, expr, known)
      Data.lower_map(cx, fx, node, want)
    Ast.Expr.EnumConstructor(node) ->
      try typed(cx, expr, known)
      Data.lower_enum(cx, fx, node.enum_name, node.variant_name, node.args, node.span, want, false)
    Ast.Expr.Construct(node) ->
      try typed(cx, expr, known)
      Data.lower_struct(cx, fx, node, want)
    Ast.Expr.Update(node) ->
      try typed(cx, expr, known)
      Data.lower_update(cx, fx, node, want)
    Ast.Expr.Index(node) ->
      try typed(cx, expr, known)
      lower_index(cx, fx, node, want)
    Ast.Expr.FunctionRef(node) ->
      try typed(cx, expr, known)
      lower_function_ref(cx, fx, node, want)
    Ast.Expr.BlockLit(node) ->
      try typed(cx, expr, known)
      lower_block_lit(cx, fx, node, want)
    Ast.Expr.Case(node) ->
      try typed(cx, expr, known)
      cx.case_value.call(cx, fx, node, want)
  end
end

## Lowers a call of a function or builtin by name. checked is set for the call made from a resolved method call, whose
## type check was the method call's own; tail makes it a `tail-call` (a return of a call of a function of the program).
def lower_call(
  cx: Lowering.Cx,
  fx: Lowering.Fx,
  written: Ast.Call,
  want: Int,
  void: Bool,
  checked: Bool,
  tail: Bool,
) -> Result[Lowering.Out]
  node = written
  case cx.slots.get(written.id)
    some(slots) -> node = Defaults.bound(written, slots)
    none ->
      # Only error(...) keeps its named arguments, the fields of its Error; any other call has its slots.
      if written.named.size > 0 and written.name != "error"
        return error(Lowering.internal(cx, "lower: a call with named arguments has no slots", written.span))
      end
  end

  span = node.span
  count = node.args.size
  form = Builtins.call_ref(node.name, count, Ast.block_call?(node))
  key = ""
  target = node.name
  prelude = form.ok? and Builtins.prelude_form?(form.unwrap!)
  if prelude
    # A builtin written in the prelude is an ordinary call of its function (the checker chose which), and never a tail
    # call: the VM reports a runtime error of the callee at the frame of this call.
    target = Names.prelude_name(cx.bodies[node.id])
  elsif form.ok?
    key = form.unwrap!.implementation
  end

  if key == "Task.await"
    key = try await_key(cx, node, checked, count)
  elsif key == "Task.monitor" and task_ref?(Lowering.type_of(cx, node.args[0]))
    # A monitor through a TaskRef (Task.current) does not observe a crash: only the holder of the Task[R] can await it.
    key = "Task.monitor_ref"
  elsif form.ok? and CODEC_BUILTINS.include?(node.name)
    return lower_codec(cx, fx, Defaults.in_parameter_order(node), key, want, void, checked, tail)
  elsif optional_call?(node)
    return lower_optional(cx, fx, Defaults.in_parameter_order(node), want, void, checked, tail)
  end

  builtin = key != "" and VM_BUILTINS.include?(key)
  return error(Lowering.unsupported(cx, "the builtin #{node.name}", span)) if form.ok? and !builtin and !prelude

  if !builtin and !cx.functions.has_key?(target)
    return error(Lowering.unsupported(cx, "the call to #{node.name}", span))
  end

  if !checked
    expr = Ast.Expr.Call(node)
    try Lowering.require_type(cx, expr, void, Lowering.type_of(cx, expr))
  end

  fx = Lowering.step(fx, span)
  saved = fx.next
  fx = Lowering.alloc(fx)
  base = fx.next - 1
  fill = cx.fills.get(node.name)
  shape = Defaults.Shape(required: count, total: count, fn_last: false)
  # A builtin or prelude form with defaults; `builtin` and `prelude` are true only when the form exists.
  defaulted = (builtin or prelude) and Builtins.defaulted?(form.unwrap!)
  if fill.some?
    shape = fill.unwrap!.shape
  elsif defaulted
    shape = Defaults.builtin_shape(form.unwrap!)
  end

  total = shape.total
  # The struct builtins of Native and Native.callback take a type name as its layout code or signature (no defaults:
  # one argument per parameter).
  laid_out = builtin and NATIVE_LAYOUTS.include?(key)
  if laid_out
    node = Defaults.in_parameter_order(node)
  end

  index = 0
  if node.slots.size > 0
    fx = try lower_bound_arguments(cx, fx, node, fill, form, defaulted, shape, base)
    index = total
  end

  while index < total
    fx = Lowering.alloc(fx.with(next: base + index))
    if laid_out and type_name?(node.args[index])
      arg = node.args[index]
      fx = try emit_layout(cx, fx, Lowering.type_of(cx, arg), Ast.expr_span(arg))
    elsif node.named.size > 0
      # error(message, kind: ...): the Error record, which the builtin error then places.
      out = try Data.lower_error_record(cx, fx, node, fx.next - 1)
      fx = out.fx
    elsif ok_call?(node)
      # The check of Result[T], this call's or that of the value holding it, covers T: a check at each level of nested
      # ok(...) walks the whole type below it, quadratic in the depth.
      out = try lower_expression(cx, fx, node.args[0], fx.next - 1, false, true)
      fx = out.fx
    elsif defaulted
      out = try lower_builtin_argument(cx, fx, node, form.unwrap!, shape, index)
      fx = out.fx
    else
      out = try lower_argument(cx, fx, node, fill, shape, index)
      fx = out.fx
    end

    index += 1
  end

  spans = builtin_spans(node, shape)
  if laid_out and key == "Native.put_struct"
    # The VM gets the layout of the value's struct as a fourth argument, with the span of the value.
    fx = Lowering.alloc(fx.with(next: base + total))
    value_span = Ast.expr_span(node.args[2])
    fx = try emit_layout(cx, fx, Lowering.type_of(cx, node.args[2]), value_span)
    spans = spans.push(value_span)
    total += 1
  end

  if builtin
    fx = Lowering.emit_builtin(fx, base, key, total, spans)
    if tail
      fx = Lowering.emit_at(fx, "return", [base], span)
    end
  elsif prelude
    # The span of each argument follows the span of the call, so the VM can name the argument a prelude function
    # rejects (docs/vm/03-ir-and-bytecode.md).
    fx = Lowering.emit(fx, "call", [base, cx.functions[target]], builtin_spans(node, shape))
  else
    op = "call"
    if tail
      op = "tail-call"
    end

    fx = Lowering.emit_at(fx, op, [base, cx.functions[target]], span)
  end

  if want >= 0
    fx = Lowering.emit_at(fx, "move", [want, base], span)
    return ok(Lowering.Out(fx: fx.with(next: saved), slot: want))
  end

  ok(Lowering.Out(fx: fx.with(next: base + 1), slot: base))
end

private

# The methods of a codec. A codec is a Codec.Info record at run time (Type.codec, Data.lower_codec): its name is the
# type argument of JSON.decode and its members are what Type.members gives. decode is JSON.decode of the source and
# the name, encode and from are their JSON builtin of the value alone (the struct of a value names itself), and members
# is the field of the record. The receiver is computed first, as the first argument of any call is, into the register
# after the one the builtin takes first.
def lower_codec(
  cx: Lowering.Cx,
  fx: Lowering.Fx,
  node: Ast.Call,
  key: String,
  want: Int,
  void: Bool,
  checked: Bool,
  tail: Bool,
) -> Result[Lowering.Out]
  if !checked
    expr = Ast.Expr.Call(node)
    try Lowering.require_type(cx, expr, void, Lowering.type_of(cx, expr))
  end

  span = node.span
  saved = fx.next
  out = try codec_value(cx, fx, node, key)
  fx = out.fx
  base = out.slot
  if tail
    fx = Lowering.emit_at(fx, "return", [base], span)
  end

  if want >= 0
    if base != want
      fx = Lowering.emit_at(fx, "move", [want, base], span)
    end

    return ok(Lowering.Out(fx: fx.with(next: saved), slot: want))
  end

  ok(Lowering.Out(fx: fx.with(next: base + 1), slot: base))
end

# A call of the builtin some or none.
def optional_call?(node: Ast.Call) -> Bool
  (node.name == "some" or node.name == "none") and Builtins.ref(node.name, node.args.size).ok?
end

# A call of the builtin ok with a value.
def ok_call?(node: Ast.Call) -> Bool = node.name == "ok" and node.args.size == 1 and Builtins.ref("ok", 1).ok?

# some(x) and none: a value of the builtin enum Optional (Program.OPTIONAL), made by an `enum` instruction. The check
# of Optional[T] covers T, so the payload is lowered as known: a check at each level of nested some(...) walks the
# whole type below it, quadratic in the depth.
def lower_optional(
  cx: Lowering.Cx,
  fx: Lowering.Fx,
  node: Ast.Call,
  want: Int,
  void: Bool,
  checked: Bool,
  tail: Bool,
) -> Result[Lowering.Out]
  if !checked
    expr = Ast.Expr.Call(node)
    try Lowering.require_type(cx, expr, void, Lowering.type_of(cx, expr))
  end

  variant = "None"
  if node.name == "some"
    variant = "Some"
  end

  out = try Data.lower_enum(cx, fx, "Optional", variant, node.args, node.span, want, true)
  return ok(out.with(fx: Lowering.emit_at(out.fx, "return", [out.slot], node.span))) if tail

  ok(out)
end

# The value of a lower_codec call, in a new register: a method of a codec, whose receiver is the first argument.
def codec_value(cx: Lowering.Cx, fx: Lowering.Fx, node: Ast.Call, key: String) -> Result[Lowering.Out]
  if node.name == "Codec.members"
    fx = Lowering.alloc(Lowering.step(fx, node.span))
    base = fx.next - 1
    codec = try lower_expression(cx, fx, node.args[0], base, false, false)
    fx = Lowering.emit_at(codec.fx, "field", [base, base, CODEC_MEMBERS], node.span)
    return ok(Lowering.Out(fx: fx, slot: base))
  end

  fx = Lowering.alloc(Lowering.alloc(Lowering.step(fx, node.span)))
  base = fx.next - 2
  codec = try lower_expression(cx, fx, node.args[0], base + 1, false, false)
  value = try lower_expression(cx, codec.fx, node.args[1], base, false, false)
  spans = [node.span, Ast.expr_span(node.args[1])]
  count = 1
  fx = value.fx
  if key == "JSON.decode"
    spans = spans.push(Ast.expr_span(node.args[0]))
    count = 2
    fx = Lowering.emit_at(fx, "field", [base + 1, base + 1, CODEC_NAME], node.span)
  end

  ok(Lowering.Out(fx: Lowering.emit_builtin(fx, base, key, count, spans), slot: base))
end

# The arguments of a call with named arguments (Ast.Call.slots), which run in source order: the registers of all the
# parameters are taken first, then the defaults of the parameters left out are put in (constants, so their order does
# not matter), each with its scratch registers above its own, then each argument goes to the register of its parameter
# with its scratch registers above the window, so no argument overwrites one put in before it.
def lower_bound_arguments(
  cx: Lowering.Cx,
  fx: Lowering.Fx,
  node: Ast.Call,
  fill: Optional[Lowering.Fill],
  form: Result[Model.Builtin],
  defaulted: Bool,
  shape: Defaults.Shape,
  base: Int,
) -> Result[Lowering.Fx]
  total = shape.total
  current = fx
  for param in 0...total
    current = Lowering.alloc(current.with(next: base + param))
  end

  for param in 0...total
    next if Defaults.argument_for(shape, node.slots, node.args.size, param) >= 0

    here = current.with(next: base + param + 1)
    if defaulted
      out = try lower_builtin_default(cx, here, node, form.unwrap!.parameters[param].default)
      current = out.fx
    else
      out = try lower_default(cx, here, node, fill.unwrap!, param)
      current = out.fx
    end
  end

  top = base + total
  for index in 0...node.args.size
    out = try lower_expression(cx, current.with(next: top), node.args[index], base + node.slots[index], false, false)
    current = out.fx
  end

  ok(current.with(next: top))
end

# The value of parameter param of a call: the argument that fills it, or its default value. A function with defaults
# gets all its arguments at the call site, so the bytecode and the VM know nothing about defaults.
def lower_argument(
  cx: Lowering.Cx,
  fx: Lowering.Fx,
  node: Ast.Call,
  fill: Optional[Lowering.Fill],
  shape: Defaults.Shape,
  param: Int,
) -> Result[Lowering.Out]
  source = Defaults.argument_for(shape, node.slots, node.args.size, param)
  return lower_expression(cx, fx, node.args[source], fx.next - 1, false, false) if source >= 0

  lower_default(cx, fx, node, fill.unwrap!, param)
end

# The same for a builtin form with defaults: the default is the one of the parameter in its catalog row.
def lower_builtin_argument(
  cx: Lowering.Cx,
  fx: Lowering.Fx,
  node: Ast.Call,
  form: Model.Builtin,
  shape: Defaults.Shape,
  param: Int,
) -> Result[Lowering.Out]
  source = Defaults.argument_for(shape, node.slots, node.args.size, param)
  return lower_expression(cx, fx, node.args[source], fx.next - 1, false, false) if source >= 0

  lower_builtin_default(cx, fx, node, form.parameters[param].default)
end

# The spans of a builtin call for the VM: the call's, then each argument's, in the order of the parameters; a default
# has the span of the call.
def builtin_spans(node: Ast.Call, shape: Defaults.Shape) -> List[Source.Span]
  return [node.span].concat(node.args.map do |arg: Ast.Expr| Ast.expr_span(arg) end) if shape.total == node.args.size

  spans = [node.span]
  param = 0
  while param < shape.total
    source = Defaults.argument_for(shape, node.slots, node.args.size, param)
    if source >= 0
      spans = spans.push(Ast.expr_span(node.args[source]))
    else
      spans = spans.push(node.span)
    end

    param += 1
  end

  spans
end

# The default of a builtin parameter, a constant built the way its literal is (an empty Bytes as `"".bytes`).
def lower_builtin_default(
  cx: Lowering.Cx,
  fx: Lowering.Fx,
  node: Ast.Call,
  value: Model.Default,
) -> Result[Lowering.Out]
  Data.lower_catalog_default(cx, fx, value, node.id, node.span, fx.next - 1)
end

# A default is an expression of the file that declares the function, so it is lowered with that file's index (the
# spans of its instructions point into that file) and the file of the call comes back after it.
def lower_default(
  cx: Lowering.Cx,
  fx: Lowering.Fx,
  node: Ast.Call,
  fill: Lowering.Fill,
  param: Int,
) -> Result[Lowering.Out]
  case fill.params[param].default
    some(value) ->
      here = cx.with(file: fill.file, index: fill.index)
      out = try lower_expression(here, fx.with(file: fill.index), value, fx.next - 1, false, false)
      ok(Lowering.Out(fx: out.fx.with(file: fx.file), slot: out.slot))
    none -> error(Lowering.internal(cx, "lower: a missing argument has no default", node.span))
  end
end

# The type of an expression must be one the VM holds, unless the item was checked with its list.
def typed(cx: Lowering.Cx, expr: Ast.Expr, known: Bool) -> Result[Bool]
  return ok(true) if known

  Lowering.require_type(cx, expr, false, Lowering.type_of(cx, expr))
end

def type_name?(expr: Ast.Expr) -> Bool
  case expr
    Ast.Expr.TypeName(_) -> true
    _ -> false
  end
end

# The layout code ("{N:CODES}") of the C struct TYPE as a constant in the last register taken. TYPE is the struct that
# the checker resolved (for a type name, an alias gives the struct it names), and the checker lets only a C struct of
# an extern block through, so a missing layout is LOWER-INTERNAL.
def emit_layout(cx: Lowering.Cx, fx: Lowering.Fx, type: Types.Type, span: Source.Span) -> Result[Lowering.Fx]
  layout = ""
  if Types.is?(type, "Struct") or Types.is?(type, "Opaque")
    layout = cx.layouts.get(Types.name(type), "")
  end

  if layout == ""
    return error(Lowering.internal(cx, "lower: no C struct layout or callback for #{Types.to_text(type)}", span))
  end

  ok(Lowering.emit_const(fx, fx.next - 1, Ir.Imm.Text(layout), span))
end

# The key of a Task.await: Task.await_result when the task's result is a Result, because the VM turns a crash into an
# error value then. A call made from a method call has no type of its own.
def await_key(cx: Lowering.Cx, node: Ast.Call, checked: Bool, count: Int) -> Result[String]
  type = Lowering.type_of(cx, Ast.Expr.Call(node))
  if checked or Types.unknown?(type)
    return error(Lowering.internal(cx, "lower: Task.await has no checked type", node.span))
  end

  if count == 2
    type = Types.args(type)[0]
  end

  return ok("Task.await_result") if Types.is?(type, "Result")

  ok("Task.await")
end

def task_ref?(type: Types.Type) -> Bool = Types.is?(type, "Opaque") and Types.name(type) == "TaskRef"

def lower_name(fx: Lowering.Fx, node: Ast.NameRef, want: Int) -> Result[Lowering.Out]
  fx = Lowering.step(fx, node.span)
  slot = Lowering.lookup(fx, node.name)
  if want >= 0
    fx = Lowering.emit_at(fx, "move", [want, slot], node.span)
    return ok(Lowering.Out(fx: fx, slot: want))
  end

  ok(Lowering.Out(fx: fx, slot: slot))
end

def lower_literal(cx: Lowering.Cx, fx: Lowering.Fx, node: Ast.Literal, want: Int) -> Result[Lowering.Out]
  value = Ir.Imm.Nil
  case node.value
    Ast.LitValue.Whole(number) -> value = Ir.Imm.Int(number)
    Ast.LitValue.Real(number) -> value = Ir.Imm.Float(number)
    Ast.LitValue.Text(text) -> value = Ir.Imm.Text(text)
    Ast.LitValue.Flag(flag) -> value = Ir.Imm.Bool(flag)
    Ast.LitValue.Nothing -> value = Ir.Imm.Nil
    Ast.LitValue.Huge(_) -> return error(Lowering.internal(cx, "lower: integer literal out of range", node.span))
  end

  fx = Lowering.step(fx, node.span)
  made = Lowering.target(fx, want)
  ok(Lowering.Out(fx: Lowering.emit_const(made.fx, made.slot, value, node.span), slot: made.slot))
end

# A read of a module constant: the literal itself, or the slot of the Globals table the entry filled.
def lower_const_read(cx: Lowering.Cx, fx: Lowering.Fx, node: Ast.ConstRef, want: Int) -> Result[Lowering.Out]
  fx = Lowering.step(fx, node.span)
  made = Lowering.target(fx, want)
  read = cx.reads.get(node.name)
  return error(Lowering.internal(cx, "lower: constant #{node.name} has no slot", node.span)) if read.none?

  case read.unwrap!
    Lowering.Read.Literal(value) -> fx = Lowering.emit_const(made.fx, made.slot, value, node.span)
    Lowering.Read.Slot(slot) -> fx = Lowering.emit_at(made.fx, "global", [made.slot, slot], node.span)
  end

  ok(Lowering.Out(fx: fx, slot: made.slot))
end

# A type name as a value (JSON.decode(Person, text)): the name as a string, for a struct the VM can decode. The type
# the checker recorded there names it: an alias gives the struct or enum it names, and a List or Map type the struct
# that stands for it (Program.json_list_name).
def lower_type_name(cx: Lowering.Cx, fx: Lowering.Fx, node: Ast.TypeName, want: Int) -> Result[Lowering.Out]
  name = node.name
  type = Lowering.type_of(cx, Ast.Expr.TypeName(node))
  if Types.is?(type, "List") or Types.is?(type, "Map")
    name = Program.json_list_name(type)
  elsif Types.is?(type, "Struct") or Types.is?(type, "Enum")
    name = Types.name(type)
  end

  if !cx.json_types.include?(name)
    return error(Lowering.unsupported(cx, "the type #{Types.display_name(name)}", node.span))
  end

  fx = Lowering.step(fx, node.span)
  made = Lowering.target(fx, want)
  fx = Lowering.emit_const(made.fx, made.slot, Ir.Imm.Text(name), node.span)
  ok(Lowering.Out(fx: fx, slot: made.slot))
end

# -9223372036854775808 is the only negative literal whose positive part does not fit an Int, so it is one `const`.
def lower_unary_checked(
  cx: Lowering.Cx,
  fx: Lowering.Fx,
  expr: Ast.Expr,
  node: Ast.Unary,
  want: Int,
  known: Bool,
) -> Result[Lowering.Out]
  case node.operand
    Ast.Expr.Literal(literal) ->
      case literal.value
        Ast.LitValue.Huge(digits) ->
          return lower_min_int(fx, node, literal, want) if node.op == "minus" and digits == INT_MIN_DIGITS

        _ -> fx = fx
      end

    _ -> fx = fx
  end

  try typed(cx, expr, known)
  lower_unary(cx, fx, node, want)
end

def lower_min_int(fx: Lowering.Fx, node: Ast.Unary, literal: Ast.Literal, want: Int) -> Result[Lowering.Out]
  fx = Lowering.step(Lowering.step(fx, node.span), literal.span)
  made = Lowering.target(fx, want)
  ok(Lowering.Out(fx: Lowering.emit_const(made.fx, made.slot, Ir.Imm.Int(INT_MIN), node.span), slot: made.slot))
end

def lower_unary(cx: Lowering.Cx, fx: Lowering.Fx, node: Ast.Unary, want: Int) -> Result[Lowering.Out]
  fx = Lowering.step(fx, node.span)
  saved = fx.next
  made = Lowering.target(fx, want)
  fx = made.fx
  operand = try lower_expression(cx, fx, node.operand, -1, false, false)
  op = "neg-i"
  if node.op == "not"
    op = "not"
  elsif Types.is?(Lowering.type_of(cx, node.operand), "Float")
    op = "neg-f"
  end

  fx = Lowering.emit_at(operand.fx, op, [made.slot, operand.slot], node.op_span)
  ok(Lowering.Out(fx: Lowering.release(fx, saved, want, made.slot), slot: made.slot))
end

def lower_binary(cx: Lowering.Cx, fx: Lowering.Fx, node: Ast.Binary, want: Int) -> Result[Lowering.Out]
  fx = Lowering.step(fx, node.span)
  saved = fx.next
  made = Lowering.target(fx, want)
  fx = made.fx
  dst = made.slot
  op = node.op
  if op == "dot-dot" or op == "dot-dot-dot"
    fx = Lowering.alloc(fx)
    window = fx.next - 1
    left = try lower_expression(cx, fx, node.left, window, false, false)
    right_at = Lowering.alloc(left.fx)
    right = try lower_expression(cx, right_at, node.right, right_at.next - 1, false, false)
    exclusive = 0
    if op == "dot-dot-dot"
      exclusive = 1
    end

    fx = Lowering.emit_at(right.fx, "range", [dst, window, exclusive], node.op_span)
  elsif op == "and" or op == "or"
    fx = Lowering.new_label(fx)
    end_label = fx.labels - 1
    left = try lower_expression(cx, fx, node.left, dst, false, false)
    jump = "jump-if-false"
    if op == "or"
      jump = "jump-if-true"
    end

    fx = Lowering.emit_at(left.fx, jump, [dst, end_label], node.op_span)
    right = try lower_expression(cx, fx, node.right, dst, false, false)
    fx = Lowering.place(right.fx, end_label)
  elsif Types.is?(Lowering.type_of(cx, node.left), "Bytes")
    fx = try lower_bytes_operator(cx, fx, node, dst)
  elsif op == "plus" and Types.is?(Lowering.type_of(cx, node.left), "List")
    # xs + ys is List.concat: a new list, both operands unchanged.
    window = try bytes_call(cx, fx, "List.concat", node.left, node.right, node.op_span)
    fx = Lowering.emit_at(window.fx, "move", [dst, window.slot], node.op_span)
  elsif op == "multiply" and Types.is?(Lowering.type_of(cx, node.left), "String")
    # String * Int is a call: the VM checks the count and the size of the result (String.multiply, vm/strings.c).
    window = try bytes_call(cx, fx, "String.multiply", node.left, node.right, node.op_span)
    fx = Lowering.emit_at(window.fx, "move", [dst, window.slot], node.op_span)
  elsif Types.is?(Lowering.type_of(cx, node.left), "Optional")
    fx = try lower_deep_equality(cx, fx, node, dst, "Optional.equal")
  elsif (op == "equal" or op == "not-equal") and deep_equality?(Lowering.type_of(cx, node.left))
    fx = try lower_deep_equality(cx, fx, node, dst, "Value.equal")
  else
    ops = INT_OPS
    side = Lowering.type_of(cx, node.left)
    if Types.is?(side, "Float")
      ops = FLOAT_OPS
    elsif Types.is?(side, "String")
      ops = STRING_OPS
    end

    left = try lower_expression(cx, fx, node.left, -1, false, false)
    right = try lower_expression(cx, left.fx, node.right, -1, false, false)
    fx = right.fx
    if op == "equal"
      fx = Lowering.emit_at(fx, "eq", [dst, left.slot, right.slot], node.op_span)
    elsif op == "not-equal"
      fx = Lowering.emit_at(fx, "ne", [dst, left.slot, right.slot], node.op_span)
    elsif op == "greater" or op == "greater-equal"
      fx = Lowering.emit_at(fx, ops[op], [dst, right.slot, left.slot], node.op_span)
    else
      fx = Lowering.emit_at(fx, ops[op], [dst, left.slot, right.slot], node.op_span)
    end
  end

  ok(Lowering.Out(fx: Lowering.release(fx, saved, want, dst), slot: dst))
end

# An operator on two Bytes is a call of a builtin: the VM's `eq`, `ne` and `concat` do not take a Bytes (the value
# is outside equal_values, which the interpreter keeps small). `+` is Bytes.plus, `==` Bytes.equal and `!=` its
# negation. The operands go to two new registers, where the call reads them and leaves its result in the first.
def lower_bytes_operator(cx: Lowering.Cx, fx: Lowering.Fx, node: Ast.Binary, dst: Int) -> Result[Lowering.Fx]
  key = "Bytes.plus"
  if node.op == "equal" or node.op == "not-equal"
    key = "Bytes.equal"
  end

  window = try bytes_call(cx, fx, key, node.left, node.right, node.op_span)
  return ok(Lowering.emit_at(window.fx, "not", [dst, window.slot], node.op_span)) if node.op == "not-equal"

  ok(Lowering.emit_at(window.fx, "move", [dst, window.slot], node.op_span))
end

# True for a type whose == is the deep equality of the VM: anything but a primitive or a Range, which `eq` compares
# (Bytes and Optional have their own builtins). The checker lets only types with equality reach here.
def deep_equality?(type: Types.Type) -> Bool
  for flat in ["Int", "Float", "Bool", "String", "Nil", "Range"]
    return false if Types.is?(type, flat)
  end

  true
end

# == and != on two values that `eq` does not take call a builtin of the deep equality of the VM: Optional.equal for
# two Optionals (it answers `x == none` without a walk), Value.equal for lists, maps, sets, Results, structs and
# enums. != is the negation of the call.
def lower_deep_equality(
  cx: Lowering.Cx,
  fx: Lowering.Fx,
  node: Ast.Binary,
  dst: Int,
  key: String,
) -> Result[Lowering.Fx]
  window = try bytes_call(cx, fx, key, node.left, node.right, node.op_span)
  op = "move"
  if node.op == "not-equal"
    op = "not"
  end

  ok(Lowering.emit_at(window.fx, op, [dst, window.slot], node.op_span))
end

# The call of a builtin on two operands: both are lowered into consecutive new registers, and the call leaves its
# result in the first, which is the slot of the Out. span is the span of the call.
def bytes_call(
  cx: Lowering.Cx,
  fx: Lowering.Fx,
  key: String,
  first: Ast.Expr,
  second: Ast.Expr,
  span: Source.Span,
) -> Result[Lowering.Out]
  fx = Lowering.alloc(fx)
  window = fx.next - 1
  left = try lower_expression(cx, fx, first, window, false, false)
  right_at = Lowering.alloc(left.fx)
  right = try lower_expression(cx, right_at, second, right_at.next - 1, false, false)
  spans = [span, Ast.expr_span(first), Ast.expr_span(second)]
  ok(Lowering.Out(fx: Lowering.emit_builtin(right.fx, window, key, 2, spans), slot: window))
end

def lower_field(cx: Lowering.Cx, fx: Lowering.Fx, node: Ast.FieldAccess, want: Int) -> Result[Lowering.Out]
  fx = Lowering.step(fx, node.span)
  saved = fx.next
  made = Lowering.target(fx, want)
  source = try lower_expression(cx, made.fx, node.target, -1, false, false)
  info = cx.structs[Types.name(Lowering.static_type(cx, node.target))]
  fx = Lowering.emit_at(source.fx, "field", [made.slot, source.slot, info.positions[node.name]], node.span)
  ok(Lowering.Out(fx: Lowering.release(fx, saved, want, made.slot), slot: made.slot))
end

def lower_index(cx: Lowering.Cx, fx: Lowering.Fx, node: Ast.IndexAccess, want: Int) -> Result[Lowering.Out]
  fx = Lowering.step(fx, node.span)
  saved = fx.next
  made = Lowering.target(fx, want)
  builtin = Builtins.index_builtin(Lowering.static_type(cx, node.target))
  if builtin != ""
    # Bytes.at halts at the index argument, as list-get does.
    window = try bytes_call(cx, made.fx, builtin, node.target, node.index, node.span)
    fx = Lowering.emit_at(window.fx, "move", [made.slot, window.slot], node.span)
    return ok(Lowering.Out(fx: Lowering.release(fx, saved, want, made.slot), slot: made.slot))
  end

  items = try lower_expression(cx, made.fx, node.target, -1, false, false)
  index = try lower_expression(cx, items.fx, node.index, -1, false, false)
  op = "list-get"
  if Types.is?(Lowering.static_type(cx, node.target), "Map")
    op = "map-get"
  end

  fx = Lowering.emit_at(index.fx, op, [made.slot, items.slot, index.slot], Ast.expr_span(node.index))
  ok(Lowering.Out(fx: Lowering.release(fx, saved, want, made.slot), slot: made.slot))
end

def lower_try(cx: Lowering.Cx, fx: Lowering.Fx, node: Ast.TryExpr, want: Int) -> Result[Lowering.Out]
  fx = Lowering.step(fx, node.span)
  saved = fx.next
  made = Lowering.target(fx, want)
  operand = try lower_expression(cx, made.fx, node.operand, -1, false, false)
  # A try in the block of a Lazy method returns its error to the terminal, which ends the pipeline with it.
  op = "try"
  if cx.step_tries.include?(node.id)
    op = "try-step"
  end

  fx = Lowering.emit_at(operand.fx, op, [made.slot, operand.slot], node.span)
  ok(Lowering.Out(fx: Lowering.release(fx, saved, want, made.slot), slot: made.slot))
end

# A string with #{...} parts: the first part goes to the result register, each later one to a new register that is
# joined on with `concat`. A part that is not a String is converted with `to-text`.
def lower_interpolation(cx: Lowering.Cx, fx: Lowering.Fx, node: Ast.Interpolation, want: Int) -> Result[Lowering.Out]
  span = node.span
  fx = Lowering.step(fx, span)
  saved = fx.next
  made = Lowering.target(fx, want)
  fx = made.fx
  dst = made.slot
  if node.parts.size == 0
    fx = Lowering.emit_const(fx, dst, Ir.Imm.Text(""), span)
  else
    fx = try lower_part(cx, fx, node.parts[0], dst, span)
    index = 1
    while index < node.parts.size
      fx = Lowering.alloc(fx)
      slot = fx.next - 1
      fx = try lower_part(cx, fx, node.parts[index], slot, span)
      fx = Lowering.emit_at(fx, "concat", [dst, dst, slot], span)
      fx = fx.with(next: slot)
      index += 1
    end
  end

  ok(Lowering.Out(fx: Lowering.release(fx, saved, want, dst), slot: dst))
end

def lower_part(cx: Lowering.Cx, fx: Lowering.Fx, part: Ast.Part, slot: Int, span: Source.Span) -> Result[Lowering.Fx]
  case part
    Ast.Part.Text(text) -> ok(Lowering.emit_const(fx, slot, Ir.Imm.Text(text), span))
    Ast.Part.Code(code) ->
      out = try lower_expression(cx, fx, code, slot, false, false)
      text_of(out.fx, Lowering.static_type(cx, code), slot, span)
  end
end

# The conversion of a value in slot to its text, unless it is a String already.
def text_of(fx: Lowering.Fx, type: Types.Type, slot: Int, span: Source.Span) -> Result[Lowering.Fx]
  return ok(fx) if Types.is?(type, "String")

  ok(Lowering.emit_at(fx, "to-text", [slot, slot], span))
end

# &name, or &Time.now_ms: a builtin is the prelude function that calls it, which the checker chose by the id of the
# reference.
def lower_function_ref(cx: Lowering.Cx, fx: Lowering.Fx, node: Ast.FunctionRef, want: Int) -> Result[Lowering.Out]
  fx = Lowering.step(fx, node.span)
  name = node.name
  if cx.bodies.has_key?(node.id)
    name = Names.prelude_name(cx.bodies[node.id])
  end

  ok(lower_closure(fx, cx.functions[name], [], node.span, want))
end

# A block: the names it reads that are in scope here are copied into the registers just before a `closure` instruction,
# which makes the function value from them; the block itself becomes a function of the table (cx.block).
def lower_block_lit(cx: Lowering.Cx, fx: Lowering.Fx, node: Ast.BlockLit, want: Int) -> Result[Lowering.Out]
  fx = Lowering.step(fx, node.span)
  captured: List[String] = []
  for name in referenced_names(node.body)
    if Lowering.lookup(fx, name) >= 0
      captured = captured.push(name)
    end
  end

  index = fx.block_count
  fx = try cx.block.call(cx, fx, node, captured)
  slots = captured.map do |name: String| Lowering.lookup(fx, name) end
  ok(lower_closure(fx, index, slots, node.span, want))
end

def lower_invoke(cx: Lowering.Cx, fx: Lowering.Fx, node: Ast.Invoke, want: Int) -> Result[Lowering.Out]
  fx = Lowering.step(fx, node.span)
  saved = fx.next
  fx = Lowering.alloc(fx)
  base = fx.next - 1
  target = try lower_expression(cx, fx, node.target, base, false, false)
  finish_invoke(cx, target.fx, node.args, node.span, saved, base, want)
end

# `s.name(args)` for an Fn field: the field is read into the callee register, then called as `.call(args)` is.
def lower_field_call(cx: Lowering.Cx, fx: Lowering.Fx, node: Ast.MethodCall, want: Int) -> Result[Lowering.Out]
  fx = Lowering.step(fx, node.span)
  saved = fx.next
  fx = Lowering.alloc(fx)
  base = fx.next - 1
  source = try lower_expression(cx, fx, node.target, -1, false, false)
  info = cx.structs[Types.name(Lowering.static_type(cx, node.target))]
  fx = Lowering.emit_at(source.fx, "field", [base, source.slot, info.positions[node.name]], node.name_span)
  finish_invoke(cx, fx.with(next: base + 1), node.args, node.span, saved, base, want)
end

def field_call?(resolved: State.Resolved) -> Bool
  case resolved
    State.Resolved.FieldCall -> true
    _ -> false
  end
end

# The arguments go in the registers after the callee at base, then call-value; the result is moved to want, or stays
# in base.
def finish_invoke(
  cx: Lowering.Cx,
  fx: Lowering.Fx,
  args: List[Ast.Expr],
  span: Source.Span,
  saved: Int,
  base: Int,
  want: Int,
) -> Result[Lowering.Out]
  index = 1
  while index <= args.size
    fx = Lowering.alloc(fx.with(next: base + index))
    out = try lower_expression(cx, fx, args[index - 1], fx.next - 1, false, false)
    fx = out.fx
    index += 1
  end

  fx = Lowering.emit_at(fx, "call-value", [base, args.size], span)
  if want >= 0
    fx = Lowering.emit_at(fx, "move", [want, base], span)
    return ok(Lowering.Out(fx: fx.with(next: saved), slot: want))
  end

  ok(Lowering.Out(fx: fx.with(next: base + 1), slot: base))
end

# A closure with at most one captured register is built in the result register itself; otherwise the registers are
# copied to a window first.
def lower_closure(fx: Lowering.Fx, index: Int, slots: List[Int], span: Source.Span, want: Int) -> Lowering.Out
  if want >= 0 and slots.size <= 1
    for slot in slots
      fx = Lowering.emit_at(fx, "move", [want, slot], span)
    end

    return Lowering.Out(fx: Lowering.emit_at(fx, "closure", [want, index], span), slot: want)
  end

  saved = fx.next
  fx = Lowering.alloc(fx)
  base = fx.next - 1
  at = 0
  while at < slots.size
    to = base
    if at > 0
      fx = Lowering.alloc(fx)
      to = fx.next - 1
    end

    fx = Lowering.emit_at(fx, "move", [to, slots[at]], span)
    at += 1
  end

  fx = Lowering.emit_at(fx, "closure", [base, index], span)
  if want >= 0
    fx = Lowering.emit_at(fx, "move", [want, base], span)
    return Lowering.Out(fx: fx.with(next: saved), slot: want)
  end

  Lowering.Out(fx: fx.with(next: base + 1), slot: base)
end

# The resolution of a method call, or of a field access that names a builtin: it takes the type check of the call
# itself.
def lower_method_checked(
  cx: Lowering.Cx,
  fx: Lowering.Fx,
  expr: Ast.Expr,
  node: Ast.MethodCall,
  want: Int,
  void: Bool,
  known: Bool,
) -> Result[Lowering.Out]
  resolved = cx.resolved.get(node.id)
  if resolved.some?
    try Lowering.require_type(cx, expr, void, Lowering.type_of(cx, expr))
    return lower_field_call(cx, fx, node, want) if field_call?(resolved.unwrap!)

    named = node.named
    return lower_resolved(cx, fx, node.target, node.args, named, node.span, node.id, resolved.unwrap!, want, void)
  end

  try typed(cx, expr, known)
  error(Lowering.unsupported(cx, "this expression", node.span))
end

def lower_field_checked(
  cx: Lowering.Cx,
  fx: Lowering.Fx,
  expr: Ast.Expr,
  node: Ast.FieldAccess,
  want: Int,
  void: Bool,
  known: Bool,
) -> Result[Lowering.Out]
  resolved = cx.resolved.get(node.id)
  if resolved.some?
    try Lowering.require_type(cx, expr, void, Lowering.type_of(cx, expr))
    return lower_resolved(cx, fx, node.target, [], [], node.span, node.id, resolved.unwrap!, want, void)
  end

  try typed(cx, expr, known)
  lower_field(cx, fx, node, want)
end

# What the synthetic node of the checker becomes. The receiver is checked already, with the type the resolution
# carries.
def lower_resolved(
  cx: Lowering.Cx,
  fx: Lowering.Fx,
  receiver: Ast.Expr,
  args: List[Ast.Expr],
  named: List[Ast.NamedArg],
  span: Source.Span,
  id: Int,
  resolved: State.Resolved,
  want: Int,
  void: Bool,
) -> Result[Lowering.Out]
  case resolved
    State.Resolved.Self(type) ->
      try Lowering.require_type(cx, receiver, false, type)
      lower_expression(cx, fx, receiver, want, false, false)
    State.Resolved.Text(type) -> lower_text(cx, fx, receiver, type, span, want)
    State.Resolved.Inspect(type) -> lower_inspect(cx, fx, receiver, type, span, want)
    State.Resolved.Members(fields) -> Data.lower_members(cx, fx, fields, span, want)
    State.Resolved.Codec(name, fields) -> Data.lower_codec(cx, fx, name, fields, span, want)
    State.Resolved.FieldCall -> error(Lowering.internal(cx, "a field call is lowered with its method call", span))
    State.Resolved.Call(name, type) ->
      literal = literal_text(receiver)
      if name == "String.bytes" and args.empty? and literal.some?
        return lower_literal_bytes(fx, span, literal.unwrap!, want)
      end

      target = Ast.TypedTarget(id: Ast.expr_id(receiver), target: receiver, type: type, span: Ast.expr_span(receiver))
      call = Ast.Call(
        id: id,
        name: name,
        args: [Ast.Expr.Typed(target)].concat(args),
        piped: false,
        parenthesized: false,
        span: span,
        named: named,
      )

      lower_call(cx, fx, call, want, void, true, false)
  end
end

# The literal node when the expression is a string literal with no interpolation, whose text lowering knows.
def literal_text(expr: Ast.Expr) -> Optional[Ast.Literal]
  case expr
    Ast.Expr.Literal(node) ->
      case node.value
        Ast.LitValue.Text(_) -> some(node)
        _ -> none
      end

    _ -> none
  end
end

# `"text".bytes` on a literal: one Bytes constant, which the VM makes once when it loads the program, in place of a
# String constant and a String.bytes call that copies it on each run. The call and the literal keep their steps.
def lower_literal_bytes(fx: Lowering.Fx, span: Source.Span, literal: Ast.Literal, want: Int) -> Result[Lowering.Out]
  text = ""
  case literal.value
    Ast.LitValue.Text(value) -> text = value
    _ -> text = ""
  end

  fx = Lowering.step(Lowering.step(fx, span), literal.span)
  made = Lowering.target(fx, want)
  ok(Lowering.Out(fx: Lowering.emit_const(made.fx, made.slot, Ir.Imm.Bytes(text), span), slot: made.slot))
end

# to_s on a value: the interpolation of one part.
def lower_text(
  cx: Lowering.Cx,
  fx: Lowering.Fx,
  receiver: Ast.Expr,
  type: Types.Type,
  span: Source.Span,
  want: Int,
) -> Result[Lowering.Out]
  fx = Lowering.step(fx, span)
  saved = fx.next
  made = Lowering.target(fx, want)
  try Lowering.require_type(cx, receiver, false, type)
  out = try lower_expression(cx, made.fx, receiver, made.slot, false, false)
  fx = try text_of(out.fx, type, made.slot, span)
  ok(Lowering.Out(fx: Lowering.release(fx, saved, want, made.slot), slot: made.slot))
end

def lower_inspect(
  cx: Lowering.Cx,
  fx: Lowering.Fx,
  receiver: Ast.Expr,
  type: Types.Type,
  span: Source.Span,
  want: Int,
) -> Result[Lowering.Out]
  fx = Lowering.step(fx, span)
  saved = fx.next
  made = Lowering.target(fx, want)
  try Lowering.require_type(cx, receiver, false, type)
  operand = try lower_expression(cx, made.fx, receiver, -1, false, false)
  fx = Lowering.emit_at(operand.fx, "inspect", [made.slot, operand.slot], span)
  ok(Lowering.Out(fx: Lowering.release(fx, saved, want, made.slot), slot: made.slot))
end

# The names a block's body reads, in the order of their first read: the walk collects every name and sorts them by
# where they start in the source, which is the order the lowering finds them in.
def referenced_names(body: List[Ast.Stmt]) -> List[String]
  work: List[AstWalk.Node] = body.map do |stmt: Ast.Stmt| AstWalk.Node.Stmt(stmt) end
  reads: List[Ast.NameRef] = []
  at = 0
  while at < work.size
    node = work[at]
    at += 1
    case node
      AstWalk.Node.Expr(expr) -> reads = push_name(reads, expr)
      AstWalk.Node.Stmt(_) -> reads = reads
    end

    work = work.concat(AstWalk.children(node))
  end

  ordered = reads.sort_by do |read: Ast.NameRef| read.span.start.offset end
  seen: Set[String] = Set.new([])
  names: List[String] = []
  for read in ordered
    if !seen.include?(read.name)
      seen = seen.add(read.name)
      names = names.push(read.name)
    end
  end

  names
end

def push_name(reads: List[Ast.NameRef], expr: Ast.Expr) -> List[Ast.NameRef]
  case expr
    Ast.Expr.Name(read) -> reads.push(read)
    _ -> reads
  end
end
