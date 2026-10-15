## Statements, loops, case and functions (src/lower.rkt: lower-function, lower-block, lower-statement,
## lower-range-for). Expressions are lowered through lower_expr.agc. A block literal becomes a function through
## lower_block_function, which Cx.block points to.

import Ast from "ast"
import Builtins from "builtins"
import Paths from "import_path"
import Ir from "ir"
import Expr from "lower_expr"
import Lowering from "lower_state"
import {INT_MIN, INT_MIN_DIGITS} from "lower_tables"
import Source from "source"
import Types from "types"

## A lowered function, and the state after it: the block functions made inside it and the next function index, for the
## program to collect.
export struct Built
  function: Ir.Function
  fx: Lowering.Fx
end

## Lowers a function. fx is fresh (Lowering.fresh) for the file of the function; the parameters take the first
## registers and the captured names of a block the ones after them. A block gives its last expression statement as its
## value; any other function ends with a Void return.
export def lower_function(
  cx: Lowering.Cx, fx: Lowering.Fx, name: String, params: List[String], captures: List[String],
  statements: List[Ast.Stmt], span: Source.Span, block: Bool
) -> Result[Built]
  for param in params
    fx = Lowering.alloc(fx)
    fx = fx.with(vars: fx.vars.put(param, fx.next - 1))
  end
  count = fx.next
  for capture in captures
    fx = Lowering.alloc(fx)
    fx = fx.with(vars: fx.vars.put(capture, fx.next - 1))
  end
  last = statements.size - 1
  if block and last >= 0 and final_expression?(statements[last])
    fx = try lower_block(cx, fx, statements.take(last))
    final = final_value(statements[last])
    final_span = statement_span(statements[last])
    fx = Lowering.step(fx, final_span)
    out = try Expr.lower_expression(cx, fx, final, -1, true, false)
    fx = Lowering.emit_at(out.fx, "return", [out.slot], final_span)
  else
    fx = try lower_block(cx, fx, statements)
    fx = Lowering.alloc(fx)
    slot = fx.next - 1
    fx = Lowering.emit_const(fx, slot, Ir.Imm.Void, span)
    fx = Lowering.emit_at(fx, "return", [slot], span)
  end
  made = Ir.Function(
    name: name,
    params: count,
    captures: captures.size,
    slots: fx.high,
    body: fx.code,
    file: fx.file,
    span: span,
  )
  return ok(Built(function: made, fx: fx))
end

## Lowers a block literal as a function of the table (Cx.block). The block takes the next function index before its
## body is lowered, so the blocks inside it come after it, as in src/lower.rkt. The state it gives back is the
## caller's, with the blocks and the index count updated.
export def lower_block_function(
  cx: Lowering.Cx, fx: Lowering.Fx, node: Ast.BlockLit, captured: List[String]
) -> Result[Lowering.Fx]
  index = fx.block_count
  name = "block@#{Paths.last_part(cx.file)}:#{node.span.start.line}:#{node.span.start.column}"
  params = node.params.map do |param: Ast.BlockParam| param.name end
  inner = Lowering.fresh(cx.index, fx.blocks, index + 1)
  built = try lower_function(cx, inner, name, params, captured, node.body, node.span, true)
  return ok(fx.with(blocks: built.fx.blocks.put(index, built.function), block_count: built.fx.block_count))
end

# The statements in order.
def lower_block(cx: Lowering.Cx, fx: Lowering.Fx, statements: List[Ast.Stmt]) -> Result[Lowering.Fx]
  for statement in statements
    fx = try lower_statement(cx, fx, statement)
  end
  return ok(fx)
end

# A statement: its `step`, the instructions the loop above it asked for after the step, then its own code.
def lower_statement(cx: Lowering.Cx, fx: Lowering.Fx, statement: Ast.Stmt) -> Result[Lowering.Fx]
  span = statement_span(statement)
  saved = fx.next
  fx = Lowering.step(fx, span)
  if fx.pending.size > 0
    for item in fx.pending
      fx = fx.with(code: fx.code.push(item))
    end
    fx = fx.with(pending: [])
  end
  case statement
    Ast.Stmt.Binding(node) -> return lower_binding(cx, fx, node, saved)
    Ast.Stmt.Return(node) -> return lower_return(cx, fx, node, saved)
    Ast.Stmt.Expression(node) ->
      out = try Expr.lower_expression(cx, fx, node.value, -1, true, false)
      return ok(out.fx.with(next: saved))
    Ast.Stmt.If(node) -> return lower_if(cx, fx, node, saved)
    Ast.Stmt.While(node) -> return lower_while(cx, fx, node, saved)
    Ast.Stmt.Control(node) -> return lower_control(cx, fx, node)
    Ast.Stmt.For(node) -> return lower_for(cx, fx, node, saved)
    Ast.Stmt.Case(node) -> return lower_case(cx, fx, node, saved)
  end
end

# A new name takes the register its value is computed in; an assignment to a name in scope computes the value anywhere
# and moves it.
def lower_binding(cx: Lowering.Cx, fx: Lowering.Fx, node: Ast.Binding, saved: Int) -> Result[Lowering.Fx]
  existing = Lowering.lookup(fx, node.name)
  if existing >= 0
    out = try Expr.lower_expression(cx, fx, node.value, -1, false, false)
    fx = out.fx
    if out.slot != existing
      fx = Lowering.emit_at(fx, "move", [existing, out.slot], node.span)
    end
    return ok(fx.with(next: saved))
  end
  fx = Lowering.alloc(fx)
  slot = fx.next - 1
  out = try Expr.lower_expression(cx, fx, node.value, slot, false, false)
  return ok(out.fx.with(vars: out.fx.vars.put(node.name, slot)))
end

# A return of a call of a function of the program is a tail call, which returns by itself.
def lower_return(cx: Lowering.Cx, fx: Lowering.Fx, node: Ast.Return, saved: Int) -> Result[Lowering.Fx]
  case node.value
    Ast.Optional.Present(value) ->
      call = tail_call(cx, value)
      case call
        Ast.Optional.Present(found) ->
          out = try Expr.lower_call(cx, fx, found, -1, true, false, true)
          return ok(out.fx.with(next: saved))
        Ast.Optional.Absent -> fx = fx
      end
      out = try Expr.lower_expression(cx, fx, value, -1, true, false)
      fx = Lowering.emit_at(out.fx, "return", [out.slot], node.span)
    Ast.Optional.Absent ->
      fx = Lowering.alloc(fx)
      slot = fx.next - 1
      fx = Lowering.emit_const(fx, slot, Ir.Imm.Void, node.span)
      fx = Lowering.emit_at(fx, "return", [slot], node.span)
  end
  return ok(fx.with(next: saved))
end

# The call when an expression is a call of a function of the program (not a builtin).
def tail_call(cx: Lowering.Cx, value: Ast.Expr) -> Ast.Optional[Ast.Call]
  case value
    Ast.Expr.Call(node) ->
      if Builtins.ref(cx.catalog, node.name, node.args.size).ok?
        return Ast.Optional.Absent
      end
      return Ast.Optional.Present(node)
    _ -> return Ast.Optional.Absent
  end
end

def lower_if(cx: Lowering.Cx, fx: Lowering.Fx, node: Ast.IfStmt, saved: Int) -> Result[Lowering.Fx]
  fx = Lowering.new_label(fx)
  end_label = fx.labels - 1
  has_else = false
  case node.else_body
    Ast.Optional.Present(body) -> has_else = true
    Ast.Optional.Absent -> has_else = false
  end
  index = 1
  for branch in node.branches
    fx = Lowering.new_label(fx)
    skip = fx.labels - 1
    condition = try Expr.lower_expression(cx, fx, branch.condition, -1, false, false)
    fx = Lowering.emit_at(condition.fx, "jump-if-false", [condition.slot, skip], Ast.expr_span(branch.condition))
    fx = fx.with(next: saved)
    fx = try scoped(cx, fx, branch.body)
    if has_else or index < node.branches.size
      fx = Lowering.emit_at(fx, "jump", [end_label], node.span)
    end
    fx = Lowering.place(fx, skip)
    index += 1
  end
  case node.else_body
    Ast.Optional.Present(body) -> fx = try scoped(cx, fx, body)
    Ast.Optional.Absent -> fx = fx
  end
  return ok(Lowering.place(fx, end_label))
end

def lower_while(cx: Lowering.Cx, fx: Lowering.Fx, node: Ast.WhileStmt, saved: Int) -> Result[Lowering.Fx]
  fx = Lowering.new_label(Lowering.new_label(fx))
  head = fx.labels - 2
  exit = fx.labels - 1
  fx = Lowering.place(fx, head)
  condition = try Expr.lower_expression(cx, fx, node.condition, -1, false, false)
  fx = Lowering.emit_at(condition.fx, "jump-if-false", [condition.slot, exit], Ast.expr_span(node.condition))
  fx = fx.with(next: saved)
  outer_next = fx.loop_next
  outer_exit = fx.loop_exit
  fx = fx.with(loop_next: head, loop_exit: exit)
  fx = try scoped(cx, fx, node.body)
  fx = fx.with(loop_next: outer_next, loop_exit: outer_exit)
  fx = Lowering.emit_at(fx, "jump", [head], node.span)
  return ok(Lowering.place(fx, exit))
end

# break and next jump to the labels of the innermost loop.
def lower_control(cx: Lowering.Cx, fx: Lowering.Fx, node: Ast.LoopControl) -> Result[Lowering.Fx]
  if fx.loop_next < 0
    return error(Lowering.unsupported(cx, "this statement", node.span))
  end
  label = fx.loop_next
  if node.kind == "break"
    label = fx.loop_exit
  end
  return ok(Lowering.emit_at(fx, "jump", [label], node.span))
end

# A for over a list or a set (a set is read as a list in first-insertion order): the length is read once, an index
# counts up, and each pass starts by reading the element, in the instruction put after the body's first `step`.
def lower_for(cx: Lowering.Cx, fx: Lowering.Fx, node: Ast.ForStmt, saved: Int) -> Result[Lowering.Fx]
  span = node.span
  type = Lowering.static_type(cx, node.iterable)
  if Types.is(type, "Range")
    fx = try lower_range_for(cx, fx, node, span)
    return ok(fx.with(next: saved))
  end
  fx = Lowering.alloc(fx)
  items = fx.next - 1
  out = try Expr.lower_expression(cx, fx, node.iterable, items, false, false)
  fx = out.fx
  if Types.is(type, "Set")
    fx = Lowering.emit_builtin(fx, items, "Set.to_a", 1, [span, span])
  end
  if node.body.size > 0
    fx = Lowering.alloc(Lowering.alloc(Lowering.alloc(Lowering.alloc(fx))))
    index = fx.next - 4
    count = fx.next - 3
    temp = fx.next - 2
    one = fx.next - 1
    fx = Lowering.new_label(Lowering.new_label(Lowering.new_label(Lowering.new_label(fx))))
    top = fx.labels - 4
    increment = fx.labels - 3
    test = fx.labels - 2
    exit = fx.labels - 1
    fx = Lowering.emit_const(fx, index, Ir.Imm.Int(0), span)
    fx = Lowering.emit_at(fx, "list-len", [count, items], span)
    fx = Lowering.emit_const(fx, one, Ir.Imm.Int(1), span)
    fx = Lowering.emit_at(fx, "jump", [test], span)
    outer_next = fx.loop_next
    outer_exit = fx.loop_exit
    fx = fx.with(loop_next: increment, loop_exit: exit)
    before = fx
    fx = Lowering.alloc(fx)
    element = fx.next - 1
    fx = fx.with(vars: fx.vars.put(node.variable, element))
    fx = Lowering.place(fx, top)
    fx = fx.with(pending: [Ir.instr("list-get", [element, items, index], fx.file, [span])])
    fx = try lower_block(cx, fx, node.body)
    fx = leave(fx, before)
    fx = fx.with(loop_next: outer_next, loop_exit: outer_exit)
    fx = Lowering.place(fx, increment)
    fx = Lowering.emit_at(fx, "add-i", [index, index, one], span)
    fx = Lowering.place(fx, test)
    fx = Lowering.emit_at(fx, "lt-i", [temp, index, count], span)
    fx = Lowering.emit_at(fx, "jump-if-true", [temp, top], span)
    fx = Lowering.place(fx, exit)
  end
  return ok(fx.with(next: saved))
end

# A for over a range counts its bounds in registers; a literal range a..b or a...b is not built, and the body runs
# while the counter has not reached the last value.
def lower_range_for(cx: Lowering.Cx, fx: Lowering.Fx, node: Ast.ForStmt, span: Source.Span) -> Result[Lowering.Fx]
  fx = Lowering.alloc(Lowering.alloc(Lowering.alloc(fx)))
  bounds = fx.next - 3
  last_slot = fx.next - 2
  nonempty = fx.next - 1
  literal = false
  exclusive = false
  case node.iterable
    Ast.Expr.Binary(range) ->
      if range.op == "dot-dot" or range.op == "dot-dot-dot"
        literal = true
        exclusive = range.op == "dot-dot-dot"
        fx = Lowering.step(fx, range.span)
        left = try Expr.lower_expression(cx, fx, range.left, bounds, false, false)
        right = try Expr.lower_expression(cx, left.fx, range.right, last_slot, false, false)
        compare = "le-i"
        if exclusive
          compare = "lt-i"
        end
        fx = Lowering.emit_at(right.fx, compare, [nonempty, bounds, last_slot], span)
      end
    _ -> literal = false
  end
  if !literal
    source = try Expr.lower_expression(cx, fx, node.iterable, -1, false, false)
    fx = Lowering.emit_at(source.fx, "range-bounds", [bounds, source.slot], span)
  end
  fx = Lowering.new_label(Lowering.new_label(Lowering.new_label(fx)))
  exit = fx.labels - 3
  top = fx.labels - 2
  increment = fx.labels - 1
  fx = Lowering.alloc(Lowering.alloc(fx))
  one = fx.next - 2
  temp = fx.next - 1
  fx = Lowering.emit_at(fx, "jump-if-false", [nonempty, exit], span)
  fx = Lowering.emit_const(fx, one, Ir.Imm.Int(1), span)
  if exclusive
    fx = Lowering.emit_at(fx, "sub-i", [last_slot, last_slot, one], span)
  end
  outer_next = fx.loop_next
  outer_exit = fx.loop_exit
  fx = fx.with(loop_next: increment, loop_exit: exit)
  before = fx
  fx = fx.with(vars: fx.vars.put(node.variable, bounds))
  fx = Lowering.place(fx, top)
  fx = Lowering.step(fx, span)
  fx = try lower_block(cx, fx, node.body)
  fx = leave(fx, before)
  fx = fx.with(loop_next: outer_next, loop_exit: outer_exit)
  fx = Lowering.place(fx, increment)
  fx = Lowering.emit_at(fx, "eq", [temp, bounds, last_slot], span)
  fx = Lowering.emit_at(fx, "jump-if-true", [temp, exit], span)
  fx = Lowering.emit_at(fx, "add-i", [bounds, bounds, one], span)
  fx = Lowering.emit_at(fx, "jump", [top], span)
  return ok(Lowering.place(fx, exit))
end

# A case: each arm tests the scrutinee, jumps to the next arm when it does not match, binds the payload names in a
# scope of its own, and jumps to the end after its body (except the last arm).
def lower_case(cx: Lowering.Cx, fx: Lowering.Fx, node: Ast.CaseStmt, saved: Int) -> Result[Lowering.Fx]
  type = Lowering.static_type(cx, node.value)
  scrutinee = try Expr.lower_expression(cx, fx, node.value, -1, false, false)
  fx = Lowering.new_label(scrutinee.fx)
  end_label = fx.labels - 1
  value = scrutinee.slot
  index = 1
  for arm in node.arms
    fx = Lowering.new_label(fx)
    skip = fx.labels - 1
    test_slot = fx.next
    fx = try lower_test(cx, fx, arm.pattern, type, value, skip)
    fx = fx.with(next: test_slot)
    before = fx
    fx = try bind_payload(cx, fx, arm.pattern, type, value)
    fx = try lower_block(cx, fx, arm.body)
    fx = leave(fx, before)
    if index < node.arms.size
      fx = Lowering.emit_at(fx, "jump", [end_label], node.span)
    end
    fx = Lowering.place(fx, skip)
    index += 1
  end
  return ok(Lowering.place(fx, end_label).with(next: saved))
end

# The instructions that jump to skip when the scrutinee in value does not match the pattern.
def lower_test(
  cx: Lowering.Cx, fx: Lowering.Fx, pattern: Ast.Pattern, type: Types.Type, value: Int, skip: Int
) -> Result[Lowering.Fx]
  span = Ast.pattern_span(pattern)
  case pattern
    Ast.Pattern.Wildcard(node) -> return ok(fx)
    Ast.Pattern.Literal(node) -> return lower_literal_test(cx, fx, node, value, skip)
    Ast.Pattern.Variant(node) ->
      fx = Lowering.alloc(fx)
      slot = fx.next - 1
      if Types.is(type, "Result")
        fx = Lowering.emit_at(fx, "is-ok", [slot, value], span)
        jump = "jump-if-true"
        if node.variant_name == "Ok"
          jump = "jump-if-false"
        end
        return ok(Lowering.emit_at(fx, jump, [slot, skip], span))
      end
      id = cx.variants["#{node.enum_name}.#{node.variant_name}"]
      fx = Lowering.emit_at(fx, "is-variant", [slot, value, id], span)
      return ok(Lowering.emit_at(fx, "jump-if-false", [slot, skip], span))
  end
end

# A literal pattern compares with `same`. An integer that is not an Int never matches, so its arm is skipped at once.
def lower_literal_test(
  cx: Lowering.Cx, fx: Lowering.Fx, node: Ast.LiteralPattern, value: Int, skip: Int
) -> Result[Lowering.Fx]
  imm = Ir.Imm.Nil
  case node.value
    Ast.LitValue.Whole(number) -> imm = Ir.Imm.Int(number)
    Ast.LitValue.Real(number) -> imm = Ir.Imm.Float(number)
    Ast.LitValue.Text(text) -> imm = Ir.Imm.Text(text)
    Ast.LitValue.Flag(flag) -> imm = Ir.Imm.Bool(flag)
    Ast.LitValue.Nothing -> imm = Ir.Imm.Nil
    Ast.LitValue.Huge(digits) ->
      if digits != "-#{INT_MIN_DIGITS}"
        return ok(Lowering.emit_at(fx, "jump", [skip], node.span))
      end
      imm = Ir.Imm.Int(INT_MIN)
  end
  fx = Lowering.alloc(fx)
  slot = fx.next - 1
  fx = Lowering.emit_const(fx, slot, imm, node.span)
  fx = Lowering.emit_at(fx, "same", [slot, value, slot], node.span)
  return ok(Lowering.emit_at(fx, "jump-if-false", [slot, skip], node.span))
end

# The names of a variant pattern get a register each, filled from the payload of the scrutinee (a `_` takes none).
def bind_payload(
  cx: Lowering.Cx, fx: Lowering.Fx, pattern: Ast.Pattern, type: Types.Type, value: Int
) -> Result[Lowering.Fx]
  case pattern
    Ast.Pattern.Variant(node) ->
      item = 0
      for binding in node.bindings
        case binding
          Ast.Optional.Present(name) ->
            fx = Lowering.alloc(fx)
            slot = fx.next - 1
            fx = fx.with(vars: fx.vars.put(name, slot))
            if Types.is(type, "Result")
              fx = Lowering.emit_at(fx, "result-value", [slot, value], node.span)
            else
              fx = Lowering.emit_at(fx, "payload", [slot, value, item], node.span)
            end
          Ast.Optional.Absent -> fx = fx
        end
        item += 1
      end
    _ -> fx = fx
  end
  return ok(fx)
end

# A block of statements in a scope of its own: the names it makes and the registers it takes are gone after it.
def scoped(cx: Lowering.Cx, fx: Lowering.Fx, statements: List[Ast.Stmt]) -> Result[Lowering.Fx]
  inner = try lower_block(cx, fx, statements)
  return ok(leave(inner, fx))
end

# Closes a scope: the names and the register count go back to what they were when it opened.
def leave(fx: Lowering.Fx, before: Lowering.Fx) -> Lowering.Fx
  return fx.with(vars: before.vars, next: before.next)
end

def final_expression?(statement: Ast.Stmt) -> Bool
  case statement
    Ast.Stmt.Expression(node) -> return true
    _ -> return false
  end
end

def final_value(statement: Ast.Stmt) -> Ast.Expr
  case statement
    Ast.Stmt.Expression(node) -> return node.value
    _ -> return Ast.Expr.Literal(Ast.Literal(id: 0, value: Ast.LitValue.Nothing, span: statement_span(statement)))
  end
end

# The span of a statement node.
def statement_span(statement: Ast.Stmt) -> Source.Span
  case statement
    Ast.Stmt.Binding(node) -> return node.span
    Ast.Stmt.Return(node) -> return node.span
    Ast.Stmt.Expression(node) -> return node.span
    Ast.Stmt.If(node) -> return node.span
    Ast.Stmt.While(node) -> return node.span
    Ast.Stmt.For(node) -> return node.span
    Ast.Stmt.Control(node) -> return node.span
    Ast.Stmt.Case(node) -> return node.span
  end
end
