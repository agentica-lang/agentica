## Module constants in the checker (docs/grammar/06-semantics.md). The constants are put in
## initialization order, a cycle is CHECK-CONSTANT-CYCLE, then each initializer is checked in that order with no
## locals in scope and its type recorded for the reads, and the value rules are applied to the checked tree: no call of
## a function of the program, no function value, no while, no builtin with effects (CHECK-CONSTANT-EXPRESSION), and
## only data types with no Address inside (CHECK-CONSTANT-TYPE). The one exception is a whole initializer ATS.new(),
## a constant table.

import Model from "../catalog/builtin_model"
import {ENTRIES} from "../catalog/builtins"
import Linker from "../modules/linker"
import {REGEX_MODULE} from "../modules/rewrite"
import Ast from "../syntax/ast"
import AstWalk from "../syntax/ast_walk"
import Source from "../syntax/source"
import T from "../syntax/types"
import Collections from "check_collections"
import State from "check_state"
import CheckTypes from "check_types"
import Variables from "check_variables"

## What checking the constants leaves: the context with the type of every constant, the state with the types of the
## initializers, and the linked names of the constants in initialization order.
export struct Done
  cx: State.Cx
  st: State.St
  order: List[String]
end

# A constant with the file and the module prefix it is declared in, and whether an earlier check already did it
# (check_reuse.agc).
struct Entry
  decl: Ast.ConstDecl
  file: String
  prefix: String
  kept: Bool
end

# A constant being visited by the ordering: the index of its entry, its reads, and the next read to look at.
struct Visit
  index: Int
  reads: List[Ast.ConstRef]
  next: Int
end

## Orders and checks the constants of the program (the declarations of the linked modules, in order). A program without
## constants gives its context and state back. The modules of `kept` were checked by an earlier run that the context
## and the state already hold (their constants are not read again, but they take their place in the order).
export def check_all(cx: State.Cx, st: State.St, modules: List[Linker.LinkedModule], kept: Set[String]) -> Result[Done]
  entries = collect(modules, kept)
  return ok(Done(cx: cx, st: st, order: [])) if entries.size == 0

  order = try order_of(cx, st, entries)
  current = Done(cx: cx, st: st, order: [])
  for index in order
    if entries[index].kept
      current = current.with(order: current.order.push(entries[index].decl.name))
    else
      current = try check_one(current, entries[index])
    end
  end

  ok(current)
end

# The constants of std/regex come first: a regex literal in a constant calls its compile, which reads them, and the
# order follows only the reads that an initializer writes.
def collect(modules: List[Linker.LinkedModule], kept: Set[String]) -> List[Entry]
  found: List[Entry] = []
  regex_first = modules.select do |module: Linker.LinkedModule| module.key == REGEX_MODULE end
  others = modules.select do |module: Linker.LinkedModule| module.key != REGEX_MODULE end
  for module in regex_first.concat(others)
    for decl in module.declarations
      case decl
        Ast.Decl.Constant(node) ->
          found = found.push(
            Entry(decl: node, file: module.file, prefix: module.prefix, kept: kept.include?(module.key)),
          )
        _ -> found = found
      end
    end
  end

  found
end

def check_one(done: Done, entry: Entry) -> Result[Done]
  here = State.within(done.cx, entry.file, entry.prefix)
  declared = T.Type.Unknown
  case entry.decl.type
    some(annotation) -> declared = try CheckTypes.resolve_type(here, done.st, annotation, false)
    none -> declared = declared
  end

  out = try State.expr(here, State.forget_locals(done.st), entry.decl.value, declared)
  if !table?(here, out.st, entry.decl.value)
    try validate(here, out.st, entry.decl.value)
  end

  try Variables.check(here, out.st)
  type = out.type
  if !T.unknown?(declared)
    type = declared
  end

  ok(
    Done(
      cx: done.cx.with(constants: done.cx.constants.put(entry.decl.name, type)),
      st: out.st,
      order: done.order.push(entry.decl.name),
    ),
  )
end

# True when the whole initializer is ATS.new(): the one value with state a constant may hold, as an ATS table is
# already shared, atomic and owned by no task. ATS.new takes its type from the annotation (CHECK-EXPECTED-TYPE
# without one), and a table anywhere else in an initializer stays CHECK-CONSTANT-TYPE.
def table?(cx: State.Cx, st: State.St, value: Ast.Expr) -> Bool
  entry = builtin_of(cx, st, AstWalk.Node.Expr(value))
  entry.some? and entry.unwrap!.name == "ATS.new"
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

  ok(emitted)
end

def begin_visit(entries: List[Entry], index: Int) -> Visit
  Visit(index: index, reads: AstWalk.references(entries[index].decl.value), next: 0)
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
  State.fail_help(
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
  visit(cx, st, AstWalk.Node.Expr(root), false)
end

def visit(cx: State.Cx, st: State.St, node: AstWalk.Node, block_allowed: Bool) -> Result[Bool]
  try refuse_early(cx, st, node, block_allowed)
  entry = builtin_of(cx, st, node)
  inside = has_entry?(entry)
  for child in AstWalk.children(node)
    try visit(cx, st, child, inside)
  end

  try refuse_form(cx, st, node, entry)
  check_data(cx, st, node, block_allowed)
end

def has_entry?(entry: Optional[Model.Builtin]) -> Bool = entry.some?

def refuse(cx: State.Cx, st: State.St, span: Source.Span, what: String, help: String) -> String
  State.fail_help(cx, st, "CHECK-CONSTANT-EXPRESSION", what, span, help)
end

def refuse_early(cx: State.Cx, st: State.St, node: AstWalk.Node, block_allowed: Bool) -> Result[Bool]
  case node
    AstWalk.Node.Stmt(stmt) ->
      case stmt
        Ast.Stmt.While(found) ->
          error(
            refuse(
              cx,
              st,
              found.span,
              "a constant cannot use a while loop",
              "loop with for over a range or a collection, or use a builtin such as reduce",
            ),
          )
        _ -> ok(true)
      end

    AstWalk.Node.Expr(expr) ->
      case expr
        Ast.Expr.BlockLit(found) ->
          if !block_allowed and found.lambda
            return error(
              refuse(
                cx,
                st,
                found.span,
                "a lambda is not constant data",
                "declare a function with def, or build the lambda where it is used",
              ),
            )
          elsif !block_allowed
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

          ok(true)
        _ -> ok(true)
      end
  end
end

# The builtin a call, method call or field access names: not a call of a function of the program.
def builtin_of(cx: State.Cx, st: State.St, node: AstWalk.Node) -> Optional[Model.Builtin]
  case node
    AstWalk.Node.Stmt(_) -> none
    AstWalk.Node.Expr(expr) ->
      case expr
        Ast.Expr.Call(found) ->
          return none if cx.functions.has_key?(found.name)

          entry_named(cx, found.name)
        Ast.Expr.MethodCall(found) -> entry_resolved(cx, st, found.id)
        Ast.Expr.FieldAccess(found) -> entry_resolved(cx, st, found.id)
        _ -> none
      end
  end
end

def entry_named(cx: State.Cx, name: String) -> Optional[Model.Builtin]
  found = ENTRIES.get(name)
  return some(found.unwrap!) if found.some?

  none
end

def entry_resolved(cx: State.Cx, st: State.St, id: Int) -> Optional[Model.Builtin]
  resolved = st.resolved.get(id)
  return none if resolved.none?

  case resolved.unwrap!
    State.Resolved.Call(name, _) -> entry_named(cx, name)
    _ -> none
  end
end

def refuse_form(cx: State.Cx, st: State.St, node: AstWalk.Node, entry: Optional[Model.Builtin]) -> Result[Bool]
  case node
    AstWalk.Node.Stmt(_) -> ok(true)
    AstWalk.Node.Expr(expr) -> refuse_expr(cx, st, expr, entry)
  end
end

def refuse_expr(cx: State.Cx, st: State.St, expr: Ast.Expr, entry: Optional[Model.Builtin]) -> Result[Bool]
  span = Ast.expr_span(expr)
  case expr
    Ast.Expr.FunctionRef(_) ->
      error(
        refuse(
          cx,
          st,
          span,
          "a constant cannot hold a function value",
          "a constant is built from literals, constructors and builtins",
        ),
      )
    Ast.Expr.Invoke(_) ->
      error(
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

      refuse_effects(cx, st, span, entry)
    _ -> refuse_effects(cx, st, span, entry)
  end
end

def refuse_effects(cx: State.Cx, st: State.St, span: Source.Span, entry: Optional[Model.Builtin]) -> Result[Bool]
  case entry
    some(found) ->
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

      ok(true)
    none -> ok(true)
  end
end

# CHECK-CONSTANT-TYPE for an expression whose type is not a data type. A block passed to a builtin is not a value of
# the constant.
def check_data(cx: State.Cx, st: State.St, node: AstWalk.Node, block_allowed: Bool) -> Result[Bool]
  case node
    AstWalk.Node.Stmt(_) -> ok(true)
    AstWalk.Node.Expr(expr) ->
      type = st.types[Ast.expr_id(expr)]
      return ok(true) if T.unknown?(type) or (block_allowed and block?(expr)) or constant_data?(cx, type)

      error(
        State.fail_help(
          cx,
          st,
          "CHECK-CONSTANT-TYPE",
          data_message(cx, type),
          Ast.expr_span(expr),
          data_help(cx, type),
        ),
      )
  end
end

# A data type with no Address inside. An address is data, but it names a channel, and no channel exists before main:
# a constant that keeps addresses is a table of them (ATS[String, Address[M]]), filled while the program runs.
def constant_data?(cx: State.Cx, type: T.Type) -> Bool
  CheckTypes.data?(cx, type) and !Collections.holds_address?(cx, type)
end

# A data type refused here holds an Address (constant_data?).
def data_message(cx: State.Cx, type: T.Type) -> String
  return "a constant cannot hold an Address, found #{T.to_text(type)}" if CheckTypes.data?(cx, type)

  "a constant expression must have a data type, found #{T.to_text(type)}"
end

def data_help(cx: State.Cx, type: T.Type) -> String
  return "a constant's value must be data: write nil, not a Void call" if T.is?(type, "Void")
  return "a constant table is the whole initializer: NAMES: ATS[String, Int] = ATS.new()" if T.is?(type, "ATS")
  if CheckTypes.data?(cx, type)
    return "an address names a channel of the running program: keep it in a constant table, ATS[String, Address[M]]"
  end

  (
    "a constant holds numbers, text, collections, structs and enums of those; " +
    "functions, tasks, channels, handles and tables are not data"
  )
end

def block?(expr: Ast.Expr) -> Bool
  case expr
    Ast.Expr.BlockLit(_) -> true
    _ -> false
  end
end
