## The state of the lowering (a state that is passed and returned, not mutated): what is
## fixed for the run (Cx), what changes while one function is lowered (Fx), and the small operations on them that every
## part of the lowering uses. A lowering function takes Cx and Fx and returns the new Fx with its register (Out), or
## fails with a packed LOWER- diagnostic (diagnostics/problem.agc), so `try` stops at the first one.

import State from "../check/check_state"
import Defaults from "../check/defaults"
import Diag from "../diagnostics/diagnostic"
import Failure from "../diagnostics/problem"
import Ast from "../syntax/ast"
import Source from "../syntax/source"
import Types from "../syntax/types"
import Ir from "ir"

## A struct of the program as the lowering reads it: its index in the struct table, its fields in order, and the
## position of each field.
export struct StructInfo
  index: Int
  fields: List[String]
  positions: Map[String, Int]
end

## What a read of a module constant becomes: the literal itself, or a read of the slot of the Globals table.
export enum Read
  Literal(Ir.Imm)
  Slot(Int)
end

## A function with default values, as a call site needs it: its shape, its parameters (the defaults are expressions of
## the file that declares it), that file and its position in the sources. The default is lowered with the instructions
## in that file, because its spans and the names in it belong there.
export struct Fill
  shape: Defaults.Shape
  params: List[Ast.Param]
  file: String
  index: Int
end

## The field defaults of a struct, as a construction needs them: the expression of each field that has one, by field
## name, the file that declares the struct and its position in the sources. Like a parameter default, a field default
## is lowered with the instructions in that file, because its spans and the names in it belong there.
export struct FieldFill
  values: Map[String, Ast.Expr]
  file: String
  index: Int
end

## What is fixed while the program is lowered. types and resolved are those of the checker. user_types maps a struct or
## enum name (the program's and the builtin ones it uses) to "Struct" or "Enum"; structs the struct info by name;
## variants the id of "Enum.Variant"; json_structs the structs JSON.decode may build; layouts the layout code of each
## C struct of an extern block ("{N:CODES}", lower_native.agc), by name; functions the index of each
## declared function; bodies the prelude function each call of a prelude builtin runs, by id of the call
## (prelude_files.agc); step_tries the `try` nodes in the blocks of Lazy methods, which lower to try-step;
## fills the functions that have default values, by name; field_fills the structs that have fields with a default, by
## name; reads what a constant read becomes. file
## is the file of the function being lowered and index its position in the sources. expression lowers an expression,
## and block lowers a block as a function: the cycles between expressions, statements and blocks go through these two
## fields, because a module cannot import one that imports it.
export struct Cx
  types: List[Types.Type]
  resolved: Map[Int, State.Resolved]
  user_types: Map[String, String]
  structs: Map[String, StructInfo]
  variants: Map[String, Int]
  json_structs: Set[String]
  layouts: Map[String, String]
  functions: Map[String, Int]
  bodies: Map[Int, String]
  step_tries: Set[Int]
  fills: Map[String, Fill]
  field_fills: Map[String, FieldFill]
  reads: Map[String, Read]
  file: String
  index: Int
  expression: Fn[Cx, Fx, Ast.Expr, Int, Bool, Bool, Result[Out]]
  block: Fn[Cx, Fx, Ast.BlockLit, List[String], Result[Fx]]
end

## What changes while a function is lowered: the code so far (in order), the next free register and the highest one
## used, the names in scope with their registers (one persistent Map: a scope is a snapshot of it), the number of
## labels made, the labels `next` and `break` jump to (-1 outside a loop), the instructions to put after the next
## statement's `step` (the read of the element of a `for`), the file index of the instructions, and, shared with the
## blocks lowered inside it, the block functions made so far by function index and the next function index.
export struct Fx
  code: List[Ir.Instr]
  next: Int
  high: Int
  vars: Map[String, Int]
  labels: Int
  loop_next: Int
  loop_exit: Int
  pending: List[Ir.Instr]
  file: Int
  blocks: Map[Int, Ir.Function]
  block_count: Int
end

## The result of lowering an expression: the new state and the register that holds the value.
export struct Out
  fx: Fx
  slot: Int
end

## The state at the start of a function in file index: nothing emitted, no names, no registers.
export def fresh(file: Int, blocks: Map[Int, Ir.Function], block_count: Int) -> Fx
  return Fx(
    code: [], next: 0, high: 0, vars: {}, labels: 0, loop_next: -1, loop_exit: -1, pending: [], file: file,
    blocks: blocks, block_count: block_count
  )
end

## The failure of a form the VM does not support: LOWER-UNSUPPORTED "the VM does not support WHAT yet".
export def unsupported(cx: Cx, what: String, span: Source.Span) -> String
  message = "the VM does not support #{what} yet"
  return Failure.pack(Failure.problem(cx.file, "", "LOWER-UNSUPPORTED", message, span, Diag.Help.NoHelp))
end

## The failure for a program the lowering cannot make sense of.
export def internal(cx: Cx, message: String, span: Source.Span) -> String
  return Failure.pack(Failure.problem(cx.file, "", "LOWER-INTERNAL", message, span, Diag.Help.NoHelp))
end

## The state with an instruction emitted. The spans are those the VM reports an error or a stack frame at.
export def emit(fx: Fx, op: String, args: List[Int], spans: List[Source.Span]) -> Fx
  return fx.with(code: fx.code.push(Ir.instr(op, args, fx.file, spans)))
end

## The state with an instruction that has one span.
export def emit_at(fx: Fx, op: String, args: List[Int], span: Source.Span) -> Fx
  return fx.with(code: fx.code.push(Ir.instr(op, args, fx.file, [span])))
end

## The state with a `step` for a node.
export def step(fx: Fx, span: Source.Span) -> Fx
  return fx.with(code: fx.code.push(Ir.instr("step", [], fx.file, [span])))
end

## The state with a `const` of a value.
export def emit_const(fx: Fx, dst: Int, value: Ir.Imm, span: Source.Span) -> Fx
  made = Ir.Instr(op: "const", args: [dst], imm: value, name: "", file: fx.file, spans: [span])
  return fx.with(code: fx.code.push(made))
end

## The state with a `call-builtin` of a name and the number of its arguments. spans is the call's span and then each
## argument's.
export def emit_builtin(fx: Fx, base: Int, name: String, count: Int, spans: List[Source.Span]) -> Fx
  made = Ir.Instr(op: "call-builtin", args: [base, count], imm: Ir.Imm.Void, name: name, file: fx.file, spans: spans)
  return fx.with(code: fx.code.push(made))
end

## The state with a label placed here.
export def place(fx: Fx, id: Int) -> Fx
  return fx.with(code: fx.code.push(Ir.label(id, fx.file)))
end

## The state with a new label id; the id is labels - 1 of the result.
export def new_label(fx: Fx) -> Fx
  return fx.with(labels: fx.labels + 1)
end

## The state with one more register taken; the register is next - 1 of the result.
export def alloc(fx: Fx) -> Fx
  next = fx.next + 1
  high = fx.high
  if next > high
    high = next
  end

  return fx.with(next: next, high: high)
end

## The register to compute into: want when there is one (a register of 0 or more), else a new one.
export def target(fx: Fx, want: Int) -> Out
  if want >= 0
    return Out(fx: fx, slot: want)
  end

  taken = alloc(fx)
  return Out(fx: taken, slot: taken.next - 1)
end

## The state after a value is in dst: the registers go back to saved when the caller gave a register to fill (want),
## else only dst stays taken.
export def release(fx: Fx, saved: Int, want: Int, dst: Int) -> Fx
  if want >= 0
    return fx.with(next: saved)
  end

  return fx.with(next: dst + 1)
end

## The register of a name in scope, or -1.
export def lookup(fx: Fx, name: String) -> Int
  return fx.vars.get(name, -1)
end

## The type the checker recorded for an expression (Unknown when none).
export def type_of(cx: Cx, expr: Ast.Expr) -> Types.Type
  return cx.types[Ast.expr_id(expr)]
end

## The type of an expression, or the type a TypedTarget carries.
export def static_type(cx: Cx, expr: Ast.Expr) -> Types.Type
  case expr
    Ast.Expr.Typed(node) -> return node.type
    _ -> return type_of(cx, expr)
  end
end

## True when the VM has a representation for values of the type.
export def vm_type?(cx: Cx, type: Types.Type) -> Bool
  case type
    Types.Type.List(item) -> return vm_type?(cx, item)
    Types.Type.Map(key, value) -> return vm_type?(cx, value)
    Types.Type.ATS(key, value) -> return vm_type?(cx, value)
    Types.Type.Set(item) -> return true
    Types.Type.Result(item) -> return Types.is?(item, "Void") or vm_type?(cx, item)
    Types.Type.Task(item) -> return Types.is?(item, "Void") or vm_type?(cx, item)
    Types.Type.Channel(item) -> return vm_type?(cx, item)
    Types.Type.Lazy(item) -> return vm_type?(cx, item)
    # A codec is the name of its struct at run time (JSON.codec).
    Types.Type.Codec(_) -> return true
    Types.Type.Struct(name, args) -> return cx.user_types.get(name, "") == "Struct"
    Types.Type.Enum(name, args) -> return cx.user_types.get(name, "") == "Enum"
    Types.Type.Fn(params, result) -> return fn_type?(cx, params, result)
    # The checker makes an opaque type only from OPAQUE_TYPES (a builtin handle, TestCase, C.Pointer) or a resource of
    # an extern block (cx.resources): the VM has them all.
    Types.Type.Opaque(name) -> return true
    Types.Type.Int -> return true
    Types.Type.Float -> return true
    Types.Type.Bool -> return true
    Types.Type.Nil -> return true
    Types.Type.String -> return true
    Types.Type.Range -> return true
    Types.Type.Json -> return true
    # A type variable stands for a value of the VM: the functions of the prelude are written for any type, and so is
    # a generic function of the program (its body is checked once, whatever the type argument), and the default of a
    # field of a generic struct (`items: List[T] = []`), which the checker types with the variable. No other variable
    # reaches the lowering: a use of a generic struct, enum or function has its arguments put in, and a builtin
    # signature is instantiated at each call.
    Types.Type.Var(name) -> return true
    _ -> return false
  end
end

## Fails with LOWER-UNSUPPORTED unless the expression has a type the VM can hold. void allows Void; type is the type to
## test (the checker's, or a TypedTarget's).
export def require_type(cx: Cx, expr: Ast.Expr, void: Bool, type: Types.Type) -> Result[Bool]
  if vm_type?(cx, type) or (void and Types.is?(type, "Void"))
    return ok(true)
  end

  what = "this expression"
  if !Types.unknown?(type)
    what = "values of type #{Types.to_text(type)}"
  end

  return error(unsupported(cx, what, Ast.expr_span(expr)))
end

def fn_type?(cx: Cx, params: List[Types.Type], result: Types.Type) -> Bool
  for param in params
    if !vm_type?(cx, param)
      return false
    end
  end

  return Types.is?(result, "Void") or vm_type?(cx, result)
end
