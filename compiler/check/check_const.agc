## Module constants in the checker (docs/future/44-module-constants.md 44.5 to 44.7). The constants are put in
## initialization order, a cycle is CHECK-CONSTANT-CYCLE, then each initializer is checked in that order with no
## locals in scope and its type recorded for the reads, and the value rules are applied to the checked tree: no call of
## a function of the program, no function value, no while, no builtin with effects (CHECK-CONSTANT-EXPRESSION), and
## only data types (CHECK-CONSTANT-TYPE).

import Ast from "../syntax/ast"
import Model from "../catalog/builtin_model"
import CheckTypes from "check_types"
import ConstWalk from "const_walk"
import State from "check_state"
import Linker from "../modules/linker"
import Source from "../syntax/source"
import T from "../syntax/types"
import {ENTRIES} from "../catalog/builtins"

## What checking the constants leaves: the context with the type of every constant, the state with the types of the
## initializers, and the linked names of the constants in initialization order.
export struct Done
  cx: State.Cx
  st: State.St
  order: List[String]
end

# A constant with the file it is declared in.
struct Entry
  decl: Ast.ConstDecl
  file: String
end

# A constant being visited by the ordering: the index of its entry, its reads, and the next read to look at.
struct Visit
  index: Int
  reads: List[Ast.ConstRef]
  next: Int
end

## Orders and checks the constants of the program (the declarations of the linked modules, in order). A program without
## constants gives its context and state back.
export def check_all(cx: State.Cx, st: State.St, modules: List[Linker.LinkedModule]) -> Result[Done]
  entries = collect(modules)
  if entries.size == 0
    return ok(Done(cx: cx, st: st, order: []))
  end
  order = try order_of(cx, st, entries)
  current = Done(cx: cx, st: st, order: [])
  for index in order
    current = try check_one(current, entries[index])
  end
  return ok(current)
end

def collect(modules: List[Linker.LinkedModule]) -> List[Entry]
  found: List[Entry] = []
  for module in modules
    for decl in module.declarations
      case decl
        Ast.Decl.Constant(node) -> found = found.push(Entry(decl: node, file: module.file))
        _ -> found = found
      end
    end
  end
  return found
end

def check_one(done: Done, entry: Entry) -> Result[Done]
  here = done.cx.with(file: entry.file)
  declared = T.Type.Unknown
  case entry.decl.type
    Ast.Optional.Present(annotation) -> declared = try CheckTypes.resolve_type(here, done.st, annotation, false)
    Ast.Optional.Absent -> declared = declared
  end
  out = try State.expr(here, done.st, entry.decl.value, declared)
  try validate(here, out.st, entry.decl.value)
  type = out.type
  if !T.unknown?(declared)
    type = declared
  end
  return ok(
    Done(
      cx: done.cx.with(constants: done.cx.constants.put(entry.decl.name, type)),
      st: out.st,
      order: done.order.push(entry.decl.name),
    ),
  )
end

# The entries in initialization order, as indexes. To visit a constant, first visit the constants its initializer
# reads, in the order of the reads, then emit it; the first read that reaches a constant already on the path is a
# cycle. The path is an explicit stack: a chain of constants is not bounded by the checker's nesting limit.
def order_of(cx: State.Cx, st: State.St, entries: List[Entry]) -> Result[List[Int]]
  index_of: Map[String, Int] = {}
  at = 0
  while at < entries.size
    index_of = index_of.put(entries[at].decl.name, at)
    at += 1
  end
  state: Map[String, Int] = {}
  emitted: List[Int] = []
  start = 0
  while start < entries.size
    if !state.has_key?(entries[start].decl.name)
      stack: List[Visit] = [begin_visit(entries, start)]
      state = state.put(entries[start].decl.name, 1)
      while stack.size > 0
        top = stack[stack.size - 1]
        if top.next >= top.reads.size
          stack = stack.take(stack.size - 1)
          state = state.put(entries[top.index].decl.name, 2)
          emitted = emitted.push(top.index)
        else
          read = top.reads[top.next]
          stack = stack.set(stack.size - 1, top.with(next: top.next + 1))
          seen = state.get(read.name, 0)
          if seen == 1
            return error(cycle_failure(cx, st, entries, stack, read))
          elsif seen == 0
            state = state.put(read.name, 1)
            stack = stack.push(begin_visit(entries, index_of[read.name]))
          end
        end
      end
    end
    start += 1
  end
  return ok(emitted)
end

def begin_visit(entries: List[Entry], index: Int) -> Visit
  return Visit(index: index, reads: ConstWalk.references(entries[index].decl.value), next: 0)
end

# CHECK-CONSTANT-CYCLE at the read that closes the cycle, in the file of the constant that reads it. The help lists the
# constants around the cycle, from the one that is read again: A -> B -> A.
def cycle_failure(cx: State.Cx, st: State.St, entries: List[Entry], stack: List[Visit], read: Ast.ConstRef) -> String
  names: List[String] = []
  for visit in stack
    names = names.push(entries[visit.index].decl.name)
  end
  first = 0
  while names[first] != read.name
    first += 1
  end
  around = names.drop(first).push(read.name).map do |name: String| T.display_name(name) end
  here = cx.with(file: entries[stack[stack.size - 1].index].file)
  return State.fail_help(
    here,
    st,
    "CHECK-CONSTANT-CYCLE",
    "constants depend on each other in a cycle",
    read.span,
    "the cycle is #{around.join(" -> ")}",
  )
end

# The value rules on a checked initializer. A node is visited after its children, in source order; a while is refused
# before its body. A block is allowed only as an argument of a builtin.
def validate(cx: State.Cx, st: State.St, root: Ast.Expr) -> Result[Bool]
  return visit(cx, st, ConstWalk.Node.Expr(root), false)
end

def visit(cx: State.Cx, st: State.St, node: ConstWalk.Node, block_allowed: Bool) -> Result[Bool]
  try refuse_early(cx, st, node, block_allowed)
  entry = builtin_of(cx, st, node)
  inside = has_entry?(entry)
  for child in ConstWalk.children(node)
    try visit(cx, st, child, inside)
  end
  try refuse_form(cx, st, node, entry)
  return check_data(cx, st, node, block_allowed)
end

def has_entry?(entry: Ast.Optional[Model.Builtin]) -> Bool
  case entry
    Ast.Optional.Present(found) -> return true
    Ast.Optional.Absent -> return false
  end
end

def refuse(cx: State.Cx, st: State.St, span: Source.Span, what: String, help: String) -> String
  return State.fail_help(cx, st, "CHECK-CONSTANT-EXPRESSION", what, span, help)
end

def refuse_early(cx: State.Cx, st: State.St, node: ConstWalk.Node, block_allowed: Bool) -> Result[Bool]
  case node
    ConstWalk.Node.Stmt(stmt) ->
      case stmt
        Ast.Stmt.While(found) -> return error(
          refuse(
            cx,
            st,
            found.span,
            "a constant cannot use a while loop",
            "loop with for over a range or a collection, or use a builtin such as reduce",
          ),
        )
        _ -> return ok(true)
      end
    ConstWalk.Node.Expr(expr) ->
      case expr
        Ast.Expr.BlockLit(found) ->
          if !block_allowed
            return error(
              refuse(
                cx,
                st,
                found.span,
                "a block in a constant must be an argument of a builtin",
                "pass the block to a builtin such as map or reduce",
              ),
            )
          end
          return ok(true)
        _ -> return ok(true)
      end
  end
end

# The builtin a call, method call or field access names: not a call of a function of the program.
def builtin_of(cx: State.Cx, st: State.St, node: ConstWalk.Node) -> Ast.Optional[Model.Builtin]
  case node
    ConstWalk.Node.Stmt(stmt) -> return Ast.Optional.Absent
    ConstWalk.Node.Expr(expr) ->
      case expr
        Ast.Expr.Call(found) ->
          if cx.functions.has_key?(found.name)
            return Ast.Optional.Absent
          end
          return entry_named(cx, found.name)
        Ast.Expr.MethodCall(found) -> return entry_resolved(cx, st, found.id)
        Ast.Expr.FieldAccess(found) -> return entry_resolved(cx, st, found.id)
        _ -> return Ast.Optional.Absent
      end
  end
end

def entry_named(cx: State.Cx, name: String) -> Ast.Optional[Model.Builtin]
  found = ENTRIES.get(name)
  if found.ok?
    return Ast.Optional.Present(found.unwrap!)
  end
  return Ast.Optional.Absent
end

def entry_resolved(cx: State.Cx, st: State.St, id: Int) -> Ast.Optional[Model.Builtin]
  resolved = st.resolved.get(id)
  if !resolved.ok?
    return Ast.Optional.Absent
  end
  case resolved.unwrap!
    State.Resolved.Call(name, type) -> return entry_named(cx, name)
    _ -> return Ast.Optional.Absent
  end
end

def refuse_form(cx: State.Cx, st: State.St, node: ConstWalk.Node, entry: Ast.Optional[Model.Builtin]) -> Result[Bool]
  case node
    ConstWalk.Node.Stmt(stmt) -> return ok(true)
    ConstWalk.Node.Expr(expr) -> return refuse_expr(cx, st, expr, entry)
  end
end

def refuse_expr(cx: State.Cx, st: State.St, expr: Ast.Expr, entry: Ast.Optional[Model.Builtin]) -> Result[Bool]
  span = Ast.expr_span(expr)
  case expr
    Ast.Expr.FunctionRef(found) -> return error(
      refuse(
        cx,
        st,
        span,
        "a constant cannot hold a function value",
        "a constant is built from literals, constructors and builtins",
      ),
    )
    Ast.Expr.Invoke(found) -> return error(
      refuse(
        cx,
        st,
        span,
        "a constant cannot call a function value",
        "a constant is built from literals, constructors and builtins",
      ),
    )
    Ast.Expr.Call(found) ->
      if cx.functions.has_key?(found.name)
        return error(
          refuse(
            cx,
            st,
            span,
            "a constant cannot call #{T.display_name(found.name)}, a function declared in the program",
            "build the value from literals, constructors and builtins, or compute it in a function",
          ),
        )
      end
      return refuse_effects(cx, st, span, entry)
    _ -> return refuse_effects(cx, st, span, entry)
  end
end

def refuse_effects(cx: State.Cx, st: State.St, span: Source.Span, entry: Ast.Optional[Model.Builtin]) -> Result[Bool]
  case entry
    Ast.Optional.Present(found) ->
      if found.effects.size > 0
        return error(
          refuse(
            cx,
            st,
            span,
            "a constant cannot call #{T.display_name(found.name)}, which has effects (#{found.effects.join(", ")})",
            "a constant is built from literals, constructors and builtins without effects",
          ),
        )
      end
      return ok(true)
    Ast.Optional.Absent -> return ok(true)
  end
end

# CHECK-CONSTANT-TYPE for an expression whose type is not a data type. A block passed to a builtin is not a value of
# the constant.
def check_data(cx: State.Cx, st: State.St, node: ConstWalk.Node, block_allowed: Bool) -> Result[Bool]
  case node
    ConstWalk.Node.Stmt(stmt) -> return ok(true)
    ConstWalk.Node.Expr(expr) ->
      type = st.types[Ast.expr_id(expr)]
      if T.unknown?(type) or (block_allowed and block?(expr)) or CheckTypes.data?(cx, type, [])
        return ok(true)
      end
      return error(
        State.fail_help(
          cx,
          st,
          "CHECK-CONSTANT-TYPE",
          "a constant expression must have a data type, found #{T.to_text(type)}",
          Ast.expr_span(expr),
          data_help(type),
        ),
      )
  end
end

def data_help(type: T.Type) -> String
  if T.is(type, "Void")
    return "a constant's value must be data: write nil, not a Void call"
  end
  return (
    "a constant holds numbers, text, collections, structs and enums of those; " +
    "functions, tasks, channels and handles are not data"
  )
end

def block?(expr: Ast.Expr) -> Bool
  case expr
    Ast.Expr.BlockLit(found) -> return true
    _ -> return false
  end
end
