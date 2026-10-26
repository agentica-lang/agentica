## Expressions and calls. Every function takes the register to compute into (want, or -1 for a new one) and returns the
## register that holds the value. The registers above it are free again, except the one returned when none was asked
## for.
##
## A method call or a field access that names a builtin is not rewritten in compiler/: the lowering reads its Resolved
## and lowers the synthetic node it describes.

import Builtins from "../catalog/builtins"
import {PRELUDE} from "../catalog/builtins"
import State from "../check/check_state"
import ConstWalk from "../check/const_walk"
import Defaults from "../check/defaults"
import Ast from "../syntax/ast"
import Names from "../syntax/prelude_name"
import Source from "../syntax/source"
import Types from "../syntax/types"
import Ir from "ir"
import Data from "lower_data"
import Lowering from "lower_state"
import {FLOAT_OPS, INT_MIN, INT_MIN_DIGITS, INT_OPS, STRING_OPS, VM_BUILTINS} from "lower_tables"

## Lowers an expression into the register want (-1: any). void allows a Void value (a statement, a completion); known
## skips the type check of an item whose list or map was checked as a whole.
export def lower_expression(
  cx: Lowering.Cx, fx: Lowering.Fx, expr: Ast.Expr, want: Int, void: Bool, known: Bool
) -> Result[Lowering.Out]
  case expr
    Ast.Expr.Call(node) -> return lower_call(cx, fx, node, want, void, false, false)
    Ast.Expr.Binary(node) ->
      try typed(cx, expr, known)
      return lower_binary(cx, fx, node, want)
    Ast.Expr.Name(node) ->
      try typed(cx, expr, known)
      return lower_name(fx, node, want)
    Ast.Expr.Literal(node) ->
      try typed(cx, expr, known)
      return lower_literal(cx, fx, node, want)
    Ast.Expr.ConstRef(node) ->
      try typed(cx, expr, known)
      return lower_const_read(cx, fx, node, want)
    Ast.Expr.Unary(node) -> return lower_unary_checked(cx, fx, expr, node, want, known)
    Ast.Expr.FieldAccess(node) -> return lower_field_checked(cx, fx, expr, node, want, void, known)
    Ast.Expr.MethodCall(node) -> return lower_method_checked(cx, fx, expr, node, want, void, known)
    Ast.Expr.Typed(node) ->
      try Lowering.require_type(cx, node.target, false, node.type)
      return lower_expression(cx, fx, node.target, want, false, false)
    Ast.Expr.TypeName(node) -> return lower_type_name(cx, fx, node, want)
    Ast.Expr.Interpolation(node) -> return lower_interpolation(cx, fx, node, want)
    Ast.Expr.Try(node) ->
      try Lowering.require_type(cx, expr, void, Lowering.type_of(cx, expr))
      return lower_try(cx, fx, node, want)
    Ast.Expr.Invoke(node) ->
      try Lowering.require_type(cx, expr, void, Lowering.type_of(cx, expr))
      return lower_invoke(cx, fx, node, want)
    Ast.Expr.ListLit(node) ->
      try typed(cx, expr, known)
      return Data.lower_list(cx, fx, node, want)
    Ast.Expr.MapLit(node) ->
      try typed(cx, expr, known)
      return Data.lower_map(cx, fx, node, want)
    Ast.Expr.EnumConstructor(node) ->
      try typed(cx, expr, known)
      return Data.lower_enum(cx, fx, node.enum_name, node.variant_name, node.args, node.span, want)
    Ast.Expr.Construct(node) ->
      try typed(cx, expr, known)
      return Data.lower_struct(cx, fx, node, want)
    Ast.Expr.Update(node) ->
      try typed(cx, expr, known)
      return Data.lower_update(cx, fx, node, want)
    Ast.Expr.Index(node) ->
      try typed(cx, expr, known)
      return lower_index(cx, fx, node, want)
    Ast.Expr.FunctionRef(node) ->
      try typed(cx, expr, known)
      return lower_function_ref(cx, fx, node, want)
    Ast.Expr.BlockLit(node) ->
      try typed(cx, expr, known)
      return lower_block_lit(cx, fx, node, want)
  end
end

## Lowers a call of a function or builtin by name. checked is set for the call made from a resolved method call, whose
## type check was the method call's own; tail makes it a `tail-call` (a return of a call of a function of the program).
export def lower_call(
  cx: Lowering.Cx, fx: Lowering.Fx, node: Ast.Call, want: Int, void: Bool, checked: Bool, tail: Bool
) -> Result[Lowering.Out]
  span = node.span
  count = node.args.size
  form = Builtins.ref(node.name, count)
  key = ""
  target = node.name
  prelude = form.ok? and PRELUDE.has_key?(node.name)
  if prelude
    # A builtin written in the prelude is an ordinary call of its function (the checker chose which), and never a tail
    # call: the VM reports a runtime error of the callee at the frame of this call.
    target = Names.prelude_name(cx.bodies[node.id])
  elsif form.ok?
    key = form.unwrap!.implementation
  end

  if key == "Task.await"
    key = try await_key(cx, node, checked, count)
  end

  builtin = key != "" and VM_BUILTINS.include?(key)
  if form.ok? and !builtin and !prelude
    return error(Lowering.unsupported(cx, "the builtin #{node.name}", span))
  end

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
  total = count
  if fill.ok?
    total = fill.unwrap!.shape.total
  end

  index = 0
  while index < total
    fx = Lowering.alloc(fx.with(next: base + index))
    out = try lower_argument(cx, fx, node, fill, index)
    fx = out.fx
    index += 1
  end

  if builtin
    spans = [span].concat(node.args.map do |arg: Ast.Expr| Ast.expr_span(arg) end)
    fx = Lowering.emit_builtin(fx, base, key, count, spans)
    if tail
      fx = Lowering.emit_at(fx, "return", [base], span)
    end
  elsif prelude
    # The span of each argument follows the span of the call, so the VM can name the argument a prelude function
    # rejects (docs/vm/03-ir-and-bytecode.md).
    spans = [span].concat(node.args.map do |arg: Ast.Expr| Ast.expr_span(arg) end)
    fx = Lowering.emit(fx, "call", [base, cx.functions[target]], spans)
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

  return ok(Lowering.Out(fx: fx.with(next: base + 1), slot: base))
end

# The value of parameter param of a call: the argument that fills it, or its default value. A function with defaults
# gets all its arguments at the call site, so the bytecode and the VM know nothing about defaults.
def lower_argument(
  cx: Lowering.Cx, fx: Lowering.Fx, node: Ast.Call, fill: Result[Lowering.Fill], param: Int
) -> Result[Lowering.Out]
  source = param
  if fill.ok?
    source = Defaults.argument_for(fill.unwrap!.shape, node.args.size, param)
  end

  if source >= 0
    return lower_expression(cx, fx, node.args[source], fx.next - 1, false, false)
  end

  return lower_default(cx, fx, node, fill.unwrap!, param)
end

# A default is an expression of the file that declares the function, so it is lowered with that file's index (the
# spans of its instructions point into that file) and the file of the call comes back after it.
def lower_default(
  cx: Lowering.Cx, fx: Lowering.Fx, node: Ast.Call, fill: Lowering.Fill, param: Int
) -> Result[Lowering.Out]
  case fill.params[param].default
    Ast.Optional.Present(value) ->
      here = cx.with(file: fill.file, index: fill.index)
      out = try lower_expression(here, fx.with(file: fill.index), value, fx.next - 1, false, false)
      return ok(Lowering.Out(fx: out.fx.with(file: fx.file), slot: out.slot))
    Ast.Optional.Absent -> return error(Lowering.internal(cx, "lower: a missing argument has no default", node.span))
  end
end

# The type of an expression must be one the VM holds, unless the item was checked with its list.
def typed(cx: Lowering.Cx, expr: Ast.Expr, known: Bool) -> Result[Bool]
  if known
    return ok(true)
  end

  return Lowering.require_type(cx, expr, false, Lowering.type_of(cx, expr))
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

  if Types.is?(type, "Result")
    return ok("Task.await_result")
  end

  return ok("Task.await")
end

def lower_name(fx: Lowering.Fx, node: Ast.NameRef, want: Int) -> Result[Lowering.Out]
  fx = Lowering.step(fx, node.span)
  slot = Lowering.lookup(fx, node.name)
  if want >= 0
    fx = Lowering.emit_at(fx, "move", [want, slot], node.span)
    return ok(Lowering.Out(fx: fx, slot: want))
  end

  return ok(Lowering.Out(fx: fx, slot: slot))
end

def lower_literal(cx: Lowering.Cx, fx: Lowering.Fx, node: Ast.Literal, want: Int) -> Result[Lowering.Out]
  value = Ir.Imm.Nil
  case node.value
    Ast.LitValue.Whole(number) -> value = Ir.Imm.Int(number)
    Ast.LitValue.Real(number) -> value = Ir.Imm.Float(number)
    Ast.LitValue.Text(text) -> value = Ir.Imm.Text(text)
    Ast.LitValue.Flag(flag) -> value = Ir.Imm.Bool(flag)
    Ast.LitValue.Nothing -> value = Ir.Imm.Nil
    Ast.LitValue.Huge(digits) -> return error(Lowering.internal(cx, "lower: integer literal out of range", node.span))
  end

  fx = Lowering.step(fx, node.span)
  made = Lowering.target(fx, want)
  return ok(Lowering.Out(fx: Lowering.emit_const(made.fx, made.slot, value, node.span), slot: made.slot))
end

# A read of a module constant: the literal itself, or the slot of the Globals table the entry filled.
def lower_const_read(cx: Lowering.Cx, fx: Lowering.Fx, node: Ast.ConstRef, want: Int) -> Result[Lowering.Out]
  fx = Lowering.step(fx, node.span)
  made = Lowering.target(fx, want)
  read = cx.reads.get(node.name)
  if !read.ok?
    return error(Lowering.internal(cx, "lower: constant #{node.name} has no slot", node.span))
  end

  case read.unwrap!
    Lowering.Read.Literal(value) -> fx = Lowering.emit_const(made.fx, made.slot, value, node.span)
    Lowering.Read.Slot(slot) -> fx = Lowering.emit_at(made.fx, "global", [made.slot, slot], node.span)
  end

  return ok(Lowering.Out(fx: fx, slot: made.slot))
end

# A type name as a value (JSON.decode(Person, text)): the name as a string, for a struct the VM can decode.
def lower_type_name(cx: Lowering.Cx, fx: Lowering.Fx, node: Ast.TypeName, want: Int) -> Result[Lowering.Out]
  if !cx.json_structs.include?(node.name)
    return error(Lowering.unsupported(cx, "the type #{Types.display_name(node.name)}", node.span))
  end

  fx = Lowering.step(fx, node.span)
  made = Lowering.target(fx, want)
  fx = Lowering.emit_const(made.fx, made.slot, Ir.Imm.Text(node.name), node.span)
  return ok(Lowering.Out(fx: fx, slot: made.slot))
end

# -9223372036854775808 is the only negative literal whose positive part does not fit an Int, so it is one `const`.
def lower_unary_checked(
  cx: Lowering.Cx, fx: Lowering.Fx, expr: Ast.Expr, node: Ast.Unary, want: Int, known: Bool
) -> Result[Lowering.Out]
  case node.operand
    Ast.Expr.Literal(literal) ->
      case literal.value
        Ast.LitValue.Huge(digits) ->
          if node.op == "minus" and digits == INT_MIN_DIGITS
            return lower_min_int(fx, node, literal, want)
          end

        _ -> fx = fx
      end

    _ -> fx = fx
  end

  try typed(cx, expr, known)
  return lower_unary(cx, fx, node, want)
end

def lower_min_int(fx: Lowering.Fx, node: Ast.Unary, literal: Ast.Literal, want: Int) -> Result[Lowering.Out]
  fx = Lowering.step(Lowering.step(fx, node.span), literal.span)
  made = Lowering.target(fx, want)
  return ok(Lowering.Out(fx: Lowering.emit_const(made.fx, made.slot, Ir.Imm.Int(INT_MIN), node.span), slot: made.slot))
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
  return ok(Lowering.Out(fx: Lowering.release(fx, saved, want, made.slot), slot: made.slot))
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

  return ok(Lowering.Out(fx: Lowering.release(fx, saved, want, dst), slot: dst))
end

def lower_field(cx: Lowering.Cx, fx: Lowering.Fx, node: Ast.FieldAccess, want: Int) -> Result[Lowering.Out]
  fx = Lowering.step(fx, node.span)
  saved = fx.next
  made = Lowering.target(fx, want)
  source = try lower_expression(cx, made.fx, node.target, -1, false, false)
  info = cx.structs[Types.name(Lowering.static_type(cx, node.target))]
  fx = Lowering.emit_at(source.fx, "field", [made.slot, source.slot, info.positions[node.name]], node.span)
  return ok(Lowering.Out(fx: Lowering.release(fx, saved, want, made.slot), slot: made.slot))
end

def lower_index(cx: Lowering.Cx, fx: Lowering.Fx, node: Ast.IndexAccess, want: Int) -> Result[Lowering.Out]
  fx = Lowering.step(fx, node.span)
  saved = fx.next
  made = Lowering.target(fx, want)
  items = try lower_expression(cx, made.fx, node.target, -1, false, false)
  index = try lower_expression(cx, items.fx, node.index, -1, false, false)
  op = "list-get"
  if Types.is?(Lowering.static_type(cx, node.target), "Map")
    op = "map-get"
  end

  fx = Lowering.emit_at(index.fx, op, [made.slot, items.slot, index.slot], Ast.expr_span(node.index))
  return ok(Lowering.Out(fx: Lowering.release(fx, saved, want, made.slot), slot: made.slot))
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
  return ok(Lowering.Out(fx: Lowering.release(fx, saved, want, made.slot), slot: made.slot))
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

  return ok(Lowering.Out(fx: Lowering.release(fx, saved, want, dst), slot: dst))
end

def lower_part(cx: Lowering.Cx, fx: Lowering.Fx, part: Ast.Part, slot: Int, span: Source.Span) -> Result[Lowering.Fx]
  case part
    Ast.Part.Text(text) -> return ok(Lowering.emit_const(fx, slot, Ir.Imm.Text(text), span))
    Ast.Part.Code(code) ->
      out = try lower_expression(cx, fx, code, slot, false, false)
      return text_of(out.fx, Lowering.static_type(cx, code), slot, span)
  end
end

# The conversion of a value in slot to its text, unless it is a String already.
def text_of(fx: Lowering.Fx, type: Types.Type, slot: Int, span: Source.Span) -> Result[Lowering.Fx]
  if Types.is?(type, "String")
    return ok(fx)
  end

  return ok(Lowering.emit_at(fx, "to-text", [slot, slot], span))
end

def lower_function_ref(cx: Lowering.Cx, fx: Lowering.Fx, node: Ast.FunctionRef, want: Int) -> Result[Lowering.Out]
  fx = Lowering.step(fx, node.span)
  return ok(lower_closure(fx, cx.functions[node.name], [], node.span, want))
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
  return ok(lower_closure(fx, index, slots, node.span, want))
end

def lower_invoke(cx: Lowering.Cx, fx: Lowering.Fx, node: Ast.Invoke, want: Int) -> Result[Lowering.Out]
  fx = Lowering.step(fx, node.span)
  saved = fx.next
  fx = Lowering.alloc(fx)
  base = fx.next - 1
  target = try lower_expression(cx, fx, node.target, base, false, false)
  fx = target.fx
  index = 1
  while index <= node.args.size
    fx = Lowering.alloc(fx.with(next: base + index))
    out = try lower_expression(cx, fx, node.args[index - 1], fx.next - 1, false, false)
    fx = out.fx
    index += 1
  end

  fx = Lowering.emit_at(fx, "call-value", [base, node.args.size], node.span)
  if want >= 0
    fx = Lowering.emit_at(fx, "move", [want, base], node.span)
    return ok(Lowering.Out(fx: fx.with(next: saved), slot: want))
  end

  return ok(Lowering.Out(fx: fx.with(next: base + 1), slot: base))
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

  return Lowering.Out(fx: fx.with(next: base + 1), slot: base)
end

# The resolution of a method call, or of a field access that names a builtin: it takes the type check of the call
# itself.
def lower_method_checked(
  cx: Lowering.Cx, fx: Lowering.Fx, expr: Ast.Expr, node: Ast.MethodCall, want: Int, void: Bool, known: Bool
) -> Result[Lowering.Out]
  resolved = cx.resolved.get(node.id)
  if resolved.ok?
    try Lowering.require_type(cx, expr, void, Lowering.type_of(cx, expr))
    return lower_resolved(cx, fx, node.target, node.args, node.span, node.id, resolved.unwrap!, want, void)
  end

  try typed(cx, expr, known)
  return error(Lowering.unsupported(cx, "this expression", node.span))
end

def lower_field_checked(
  cx: Lowering.Cx, fx: Lowering.Fx, expr: Ast.Expr, node: Ast.FieldAccess, want: Int, void: Bool, known: Bool
) -> Result[Lowering.Out]
  resolved = cx.resolved.get(node.id)
  if resolved.ok?
    try Lowering.require_type(cx, expr, void, Lowering.type_of(cx, expr))
    return lower_resolved(cx, fx, node.target, [], node.span, node.id, resolved.unwrap!, want, void)
  end

  try typed(cx, expr, known)
  return lower_field(cx, fx, node, want)
end

# What the synthetic node of the checker becomes. The receiver is checked already, with the type the resolution
# carries.
def lower_resolved(
  cx: Lowering.Cx, fx: Lowering.Fx, receiver: Ast.Expr, args: List[Ast.Expr], span: Source.Span, id: Int,
  resolved: State.Resolved, want: Int, void: Bool
) -> Result[Lowering.Out]
  case resolved
    State.Resolved.Self(type) ->
      try Lowering.require_type(cx, receiver, false, type)
      return lower_expression(cx, fx, receiver, want, false, false)
    State.Resolved.Text(type) -> return lower_text(cx, fx, receiver, type, span, want)
    State.Resolved.Inspect(type) -> return lower_inspect(cx, fx, receiver, type, span, want)
    State.Resolved.Call(name, type) ->
      target = Ast.TypedTarget(id: Ast.expr_id(receiver), target: receiver, type: type, span: Ast.expr_span(receiver))
      call = Ast.Call(
        id: id,
        name: name,
        args: [Ast.Expr.Typed(target)].concat(args),
        piped: false,
        parenthesized: false,
        span: span,
      )
      return lower_call(cx, fx, call, want, void, true, false)
  end
end

# to_s on a value: the interpolation of one part.
def lower_text(
  cx: Lowering.Cx, fx: Lowering.Fx, receiver: Ast.Expr, type: Types.Type, span: Source.Span, want: Int
) -> Result[Lowering.Out]
  fx = Lowering.step(fx, span)
  saved = fx.next
  made = Lowering.target(fx, want)
  try Lowering.require_type(cx, receiver, false, type)
  out = try lower_expression(cx, made.fx, receiver, made.slot, false, false)
  fx = try text_of(out.fx, type, made.slot, span)
  return ok(Lowering.Out(fx: Lowering.release(fx, saved, want, made.slot), slot: made.slot))
end

def lower_inspect(
  cx: Lowering.Cx, fx: Lowering.Fx, receiver: Ast.Expr, type: Types.Type, span: Source.Span, want: Int
) -> Result[Lowering.Out]
  fx = Lowering.step(fx, span)
  saved = fx.next
  made = Lowering.target(fx, want)
  try Lowering.require_type(cx, receiver, false, type)
  operand = try lower_expression(cx, made.fx, receiver, -1, false, false)
  fx = Lowering.emit_at(operand.fx, "inspect", [made.slot, operand.slot], span)
  return ok(Lowering.Out(fx: Lowering.release(fx, saved, want, made.slot), slot: made.slot))
end

# The names a block's body reads, in the order of their first read: the walk collects every name and sorts them by
# where they start in the source, which is the order the lowering finds them in.
def referenced_names(body: List[Ast.Stmt]) -> List[String]
  work: List[ConstWalk.Node] = body.map do |stmt: Ast.Stmt| ConstWalk.Node.Stmt(stmt) end
  reads: List[Ast.NameRef] = []
  at = 0
  while at < work.size
    node = work[at]
    at += 1
    case node
      ConstWalk.Node.Expr(expr) -> reads = push_name(reads, expr)
      ConstWalk.Node.Stmt(stmt) -> reads = reads
    end

    work = work.concat(ConstWalk.children(node))
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

  return names
end

def push_name(reads: List[Ast.NameRef], expr: Ast.Expr) -> List[Ast.NameRef]
  case expr
    Ast.Expr.Name(read) -> return reads.push(read)
    _ -> return reads
  end
end
