## Which local a position is on (docs/future/39-semantic-cli.md, 39.3): a parameter of a function or a block, a
## binding, a `for` variable or a name in a `case` pattern, whether the position is on a use of the name or on the
## place that binds it. A local has no declaration in `LinkedModule.declarations`, and the linker keeps its name, so
## the binding is found the way the checker finds it: the scope at the position is rebuilt from the function down to
## the position.
##
## Scopes follow the checker (check/check_stmt.agc). A binding is visible from the statement after it to the end of its
## block; a parameter, a `for` variable and the names of a pattern are visible in the body they open; a binding in a
## block is gone after its `end`. Agentica does not allow shadowing, so one name has one binding at a position, but two
## sibling blocks may bind the same name, and each use belongs to the binding of its own block.
##
## Only the path from the function to the position is walked, one level at a time and with no recursion, so a deep tree
## cannot reach the limit of VM calls.

import Walk from "../check/const_walk"
import Linker from "../modules/linker"
import Ast from "../syntax/ast"
import Source from "../syntax/source"
import T from "../syntax/types"
import At from "at"

## A name bound in a function. `kind` is `parameter` (of a function or a block), `local` (an assignment that introduces
## the name), `loop` (a `for` variable) or `pattern` (a name in a `case` pattern); `discard` is the name `_` of a
## parameter, which `find` answers so that the caller knows the position is on no expression. `span` is the whole
## parameter or binding, and the name alone for a `for` variable and a pattern name, which have no node of their own;
## `name_span` is the name as the binding writes it.
export struct Local
  kind: String
  name: String
  span: Source.Span
  name_span: Source.Span
  type: T.Type
end

## A local found at a position: `site` is the span of what the position is on, a use of the name or the name of its
## binding.
export struct Found
  local: Local
  site: Source.Span
end

# What a walk needs to know that does not change: where the position is, and the types the checker recorded for the
# binding nodes (`Checked.bound`).
struct Query
  offset: Int
  bound: Map[Int, List[T.Type]]
end

# Where the walk is: a list of statements to scan for the one that holds the position, or a statement or an
# expression that holds it.
enum Step
  Block(List[Ast.Stmt])
  Stmt(Ast.Stmt)
  Expr(Ast.Expr)
end

# One step of the walk: the next step, or `none` when there is nothing below; the names in scope for it; and the local
# found, if the position is on one.
struct Move
  step: Optional[Step]
  scope: Map[String, Local]
  found: Optional[Found]
end

# A step of the sweep for the uses of one local, with the names in scope for it.
struct Pending
  step: Step
  scope: Map[String, Local]
end

# What one step of the sweep found: the uses in the step itself, and the steps below it.
struct Visit
  hits: List[Source.Span]
  next: List[Pending]
end

## The local that the character at `offset` is on in the root file `module`, or `none`. `bound` is `Checked.bound`. A
## local whose type the checker recorded none for is not answered.
export def find(
  module: Linker.LinkedModule,
  bound: Map[Int, List[T.Type]],
  offset: Int,
) -> Optional[Found]
  ask = Query(offset: offset, bound: bound)
  for declaration in module.declarations
    case declaration
      Ast.Decl.Function(node) ->
        if At.holds?(node.span, offset)
          return typed(function_found(ask, node))
        end

      Ast.Decl.Constant(node) ->
        # A block in the value of a constant has no function around it: the scope starts empty. No other top-level
        # form holds an expression that can hold a block (a parameter default must be a constant, and a struct field
        # has no default).
        if At.holds?(node.span, offset)
          return typed(walk(ask, Step.Expr(node.value), {}))
        end

      _ -> ask = ask
    end
  end

  return none
end

## The names in `module` that stand for `target`, a local `find` gave, in the order of the walk: every use of it, and
## every assignment to it after the binding (`x += 1`); the binding itself is not one. The walk covers the function or
## constant that holds the binding, once, with the scopes of the checker, so two sibling blocks that bind one name
## keep their uses apart. `bound` is `Checked.bound`.
export def uses(module: Linker.LinkedModule, bound: Map[Int, List[T.Type]], target: Local) -> List[Source.Span]
  ask = Query(offset: -1, bound: bound)
  offset = target.name_span.start.offset
  for declaration in module.declarations
    case declaration
      Ast.Decl.Function(node) ->
        if At.holds?(node.span, offset)
          scope = bind_parameters(ask, parameters_of(ask, node.params), {}).scope
          return sweep(ask, target, Step.Block(node.body), scope)
        end

      Ast.Decl.Constant(node) ->
        if At.holds?(node.span, offset)
          return sweep(ask, target, Step.Expr(node.value), {})
        end

      _ -> ask = ask
    end
  end

  return []
end

# A found local is answered only with a type; a discard has none and is kept, so the caller can tell it from a position
# on no local.
def typed(found: Optional[Found]) -> Optional[Found]
  case found
    some(at) ->
      if at.local.kind != "discard" and T.unknown?(at.local.type)
        return none
      end

      return found
    none -> return found
  end
end

# The parameters are in scope for the body. The position on the name of one is the parameter itself.
def function_found(ask: Query, node: Ast.FunctionDecl) -> Optional[Found]
  bound = bind_parameters(ask, parameters_of(ask, node.params), {})
  case bound.found
    some(_) -> return bound.found
    none -> return walk(ask, Step.Block(node.body), bound.scope)
  end
end

def parameters_of(ask: Query, params: List[Ast.Param]) -> List[Local]
  return params.map do |param: Ast.Param| parameter(ask, param.id, param.name, param.span, param.name_span) end
end

def block_parameters_of(ask: Query, params: List[Ast.BlockParam]) -> List[Local]
  return params.map do |param: Ast.BlockParam| parameter(ask, param.id, param.name, param.span, param.name_span) end
end

# The parameters of a function or a block, in order: the one the position is on, or the scope with all of them. The
# name `_` is a discard, answered as one so that the caller gives no expression for it.
def bind_parameters(ask: Query, params: List[Local], scope: Map[String, Local]) -> Move
  inner = scope
  for local in params
    if At.holds?(local.name_span, ask.offset)
      if local.name == "_"
        return hit(scope, discard(local), local.name_span)
      end

      return hit(scope, local, local.name_span)
    end

    inner = declare(inner, local)
  end

  return stop(inner)
end

def discard(local: Local) -> Local
  return Local(kind: "discard", name: local.name, span: local.span, name_span: local.name_span, type: local.type)
end

# Follows the position down the tree. Each step goes into a smaller part of the tree, so the loop ends.
def walk(ask: Query, first: Step, first_scope: Map[String, Local]) -> Optional[Found]
  step = first
  scope = first_scope
  while true
    move = advance(ask, step, scope)
    case move.found
      some(_) -> return move.found
      none -> scope = move.scope
    end

    case move.step
      some(next) -> step = next
      none -> return none
    end
  end

  return none
end

def advance(ask: Query, step: Step, scope: Map[String, Local]) -> Move
  case step
    Step.Block(stmts) -> return scan(ask, stmts, scope)
    Step.Stmt(stmt) -> return into_statement(ask, stmt, scope)
    Step.Expr(expr) -> return into_expression(ask, expr, scope)
  end
end

def go(step: Step, scope: Map[String, Local]) -> Move
  return Move(step: some(step), scope: scope, found: none)
end

def stop(scope: Map[String, Local]) -> Move
  return Move(step: none, scope: scope, found: none)
end

def hit(scope: Map[String, Local], local: Local, site: Source.Span) -> Move
  return Move(step: none, scope: scope, found: some(Found(local: local, site: site)))
end

# The statement of the block that holds the position; the bindings of the statements before it are in scope.
def scan(ask: Query, stmts: List[Ast.Stmt], scope: Map[String, Local]) -> Move
  here = scope
  for stmt in stmts
    span = Ast.stmt_span(stmt)
    if At.holds?(span, ask.offset)
      return go(Step.Stmt(stmt), here)
    elsif span.start.offset > ask.offset
      return stop(here)
    end

    here = declared_by(ask, here, stmt)
  end

  return stop(here)
end

# A statement that comes before the position introduces a name when it is a binding of a name not in scope.
def declared_by(ask: Query, scope: Map[String, Local], stmt: Ast.Stmt) -> Map[String, Local]
  case stmt
    Ast.Stmt.Binding(node) -> return declare(scope, introduced(ask, scope, node))
    _ -> return scope
  end
end

# The local of a binding: the one in scope when the binding assigns an existing name, else a new one.
def introduced(ask: Query, scope: Map[String, Local], node: Ast.Binding) -> Local
  existing = scope.get(node.name)
  if existing.ok?
    return existing.unwrap!
  end

  return Local(
    kind: "local",
    name: node.name,
    span: node.span,
    name_span: node.name_span,
    type: bound_type(ask, node.id, 0),
  )
end

# `_` binds nothing and is never in scope.
def declare(scope: Map[String, Local], local: Local) -> Map[String, Local]
  if local.name == "_"
    return scope
  end

  return scope.put(local.name, local)
end

def parameter(ask: Query, id: Int, name: String, span: Source.Span, name_span: Source.Span) -> Local
  return Local(kind: "parameter", name: name, span: span, name_span: name_span, type: bound_type(ask, id, 0))
end

# The type the checker recorded for the `index`th name the node `id` introduced; Unknown when there is none.
def bound_type(ask: Query, id: Int, index: Int) -> T.Type
  found = ask.bound.get(id)
  if !found.ok?
    return T.Type.Unknown
  end

  types = found.unwrap!
  if index < types.size
    return types[index]
  end

  return T.Type.Unknown
end

# Goes into the statement that holds the position, to the part that holds it: a value, a condition, a body, or the name
# the statement binds.
def into_statement(ask: Query, stmt: Ast.Stmt, scope: Map[String, Local]) -> Move
  case stmt
    Ast.Stmt.Binding(node) ->
      if At.holds?(node.name_span, ask.offset) and node.name != "_"
        return hit(scope, introduced(ask, scope, node), node.name_span)
      end

      return go(Step.Expr(node.value), scope)
    Ast.Stmt.Return(node) -> return into_optional(node.value, scope)
    Ast.Stmt.Expression(node) -> return go(Step.Expr(node.value), scope)
    Ast.Stmt.If(node) -> return into_if(ask, node, scope)
    Ast.Stmt.While(node) -> return into_part(ask, node.condition, node.body, scope)
    Ast.Stmt.For(node) -> return into_for(ask, node, scope)
    Ast.Stmt.Case(node) -> return into_case(ask, node, scope)
    Ast.Stmt.Control(node) -> return stop(scope)
  end
end

def into_optional(value: Optional[Ast.Expr], scope: Map[String, Local]) -> Move
  case value
    some(found) -> return go(Step.Expr(found), scope)
    none -> return stop(scope)
  end
end

# The head of a statement when the position is in it, else its body.
def into_part(ask: Query, head: Ast.Expr, body: List[Ast.Stmt], scope: Map[String, Local]) -> Move
  if reaches?(head, ask.offset)
    return go(Step.Expr(head), scope)
  end

  return go(Step.Block(body), scope)
end

# A condition when the position is in it, else the body of the branch that holds the position, else the else body.
def into_if(ask: Query, node: Ast.IfStmt, scope: Map[String, Local]) -> Move
  for branch in node.branches
    if reaches?(branch.condition, ask.offset)
      return go(Step.Expr(branch.condition), scope)
    elsif At.holds?(branch.span, ask.offset)
      return go(Step.Block(branch.body), scope)
    end
  end

  case node.else_body
    some(body) -> return go(Step.Block(body), scope)
    none -> return stop(scope)
  end
end

# The variable is in scope for the body only, not for the iterable.
def into_for(ask: Query, node: Ast.ForStmt, scope: Map[String, Local]) -> Move
  variable = loop_variable(ask, node)
  if At.holds?(node.variable_span, ask.offset) and node.variable != "_"
    return hit(scope, variable, node.variable_span)
  end

  if reaches?(node.iterable, ask.offset)
    return go(Step.Expr(node.iterable), scope)
  end

  return go(Step.Block(node.body), declare(scope, variable))
end

def loop_variable(ask: Query, node: Ast.ForStmt) -> Local
  return Local(
    kind: "loop",
    name: node.variable,
    span: node.variable_span,
    name_span: node.variable_span,
    type: bound_type(ask, node.id, 0),
  )
end

# The value, or the arm that holds the position. The names of the pattern are in scope for the guard and the body.
def into_case(ask: Query, node: Ast.CaseStmt, scope: Map[String, Local]) -> Move
  if reaches?(node.value, ask.offset)
    return go(Step.Expr(node.value), scope)
  end

  for arm in node.arms
    if At.holds?(arm.span, ask.offset)
      return into_arm(ask, arm, scope)
    end
  end

  return stop(scope)
end

def into_arm(ask: Query, arm: Ast.CaseArm, scope: Map[String, Local]) -> Move
  inner = scope
  for local in pattern_locals(ask, arm.pattern)
    if At.holds?(local.name_span, ask.offset)
      return hit(scope, local, local.name_span)
    end

    inner = declare(inner, local)
  end

  case arm.guard
    some(condition) ->
      if reaches?(condition, ask.offset)
        return go(Step.Expr(condition), inner)
      end

    none -> inner = inner
  end

  return go(Step.Block(arm.body), inner)
end

# The names a pattern binds, nested patterns included. A worklist needs no recursion for a deep pattern; the order
# is not the source order, which nothing here needs.
def pattern_locals(ask: Query, pattern: Ast.Pattern) -> List[Local]
  out: List[Local] = []
  work = [pattern]
  at = 0
  while at < work.size
    case work[at]
      Ast.Pattern.Variant(node) ->
        out = out.concat(slot_locals(ask, node))
        work = work.concat(nested_patterns(node))
      _ -> work = work
    end

    at += 1
  end

  return out
end

# The names in the slots of one variant pattern. The type of the name at a slot is the payload type at its position.
def slot_locals(ask: Query, node: Ast.VariantPattern) -> List[Local]
  out: List[Local] = []
  index = 0
  for slot in node.slots
    case slot
      Ast.Slot.Bind(name, span) ->
        out = out.push(
          Local(kind: "pattern", name: name, span: span, name_span: span, type: bound_type(ask, node.id, index)),
        )
      Ast.Slot.Skip -> out = out
      Ast.Slot.Nested(inner) -> out = out
    end

    index += 1
  end

  return out
end

def nested_patterns(node: Ast.VariantPattern) -> List[Ast.Pattern]
  out: List[Ast.Pattern] = []
  for slot in node.slots
    case slot
      Ast.Slot.Nested(inner) -> out = out.push(inner)
      _ -> out = out
    end
  end

  return out
end

# Visits every step below `first` once. A step only adds steps that lie below it, so the loop ends; the worklist
# keeps a deep tree off the stack of VM calls.
def sweep(ask: Query, target: Local, first: Step, scope: Map[String, Local]) -> List[Source.Span]
  hits: List[Source.Span] = []
  work = [Pending(step: first, scope: scope)]
  at = 0
  while at < work.size
    visit = visit_step(ask, target, work[at])
    hits = hits.concat(visit.hits)
    work = work.concat(visit.next)
    at += 1
  end

  return hits
end

def visit_step(ask: Query, target: Local, pending: Pending) -> Visit
  scope = pending.scope
  case pending.step
    Step.Block(stmts) -> return visit_block(ask, stmts, scope)
    Step.Stmt(stmt) -> return visit_statement(ask, target, stmt, scope)
    Step.Expr(expr) -> return visit_expression(ask, target, expr, scope)
  end
end

def visit_block(ask: Query, stmts: List[Ast.Stmt], scope: Map[String, Local]) -> Visit
  next: List[Pending] = []
  here = scope
  for stmt in stmts
    next = next.push(Pending(step: Step.Stmt(stmt), scope: here))
    here = declared_by(ask, here, stmt)
  end

  return Visit(hits: [], next: next)
end

def visit_statement(ask: Query, target: Local, stmt: Ast.Stmt, scope: Map[String, Local]) -> Visit
  case stmt
    Ast.Stmt.Binding(node) ->
      # The first binding of a name introduces it; a later one assigns the local that is in scope.
      assigned = node.name != "_" and scope.has_key?(node.name) and stands_for?(scope[node.name], target)
      hits: List[Source.Span] = []
      if assigned
        hits = [node.name_span]
      end

      return Visit(hits: hits, next: [pending_expr(node.value, scope)])
    Ast.Stmt.Return(node) -> return below(optional_expr(node.value, scope))
    Ast.Stmt.Expression(node) -> return below([pending_expr(node.value, scope)])
    Ast.Stmt.If(node) -> return below(if_parts(node, scope))
    Ast.Stmt.While(node) ->
      return below([pending_expr(node.condition, scope), Pending(step: Step.Block(node.body), scope: scope)])
    Ast.Stmt.For(node) ->
      inner = declare(scope, loop_variable(ask, node))
      return below([pending_expr(node.iterable, scope), Pending(step: Step.Block(node.body), scope: inner)])
    Ast.Stmt.Case(node) -> return below(case_parts(ask, node, scope))
    Ast.Stmt.Control(node) -> return below([])
  end
end

def below(next: List[Pending]) -> Visit
  return Visit(hits: [], next: next)
end

def pending_expr(expr: Ast.Expr, scope: Map[String, Local]) -> Pending
  return Pending(step: Step.Expr(expr), scope: scope)
end

def optional_expr(value: Optional[Ast.Expr], scope: Map[String, Local]) -> List[Pending]
  case value
    some(found) -> return [pending_expr(found, scope)]
    none -> return []
  end
end

def if_parts(node: Ast.IfStmt, scope: Map[String, Local]) -> List[Pending]
  out: List[Pending] = []
  for branch in node.branches
    out = out.push(pending_expr(branch.condition, scope)).push(Pending(step: Step.Block(branch.body), scope: scope))
  end

  case node.else_body
    some(body) -> return out.push(Pending(step: Step.Block(body), scope: scope))
    none -> return out
  end
end

# The value, and for each arm its guard and body, in the scope that the names of the pattern extend.
def case_parts(ask: Query, node: Ast.CaseStmt, scope: Map[String, Local]) -> List[Pending]
  out: List[Pending] = [pending_expr(node.value, scope)]
  for arm in node.arms
    inner = scope
    for local in pattern_locals(ask, arm.pattern)
      inner = declare(inner, local)
    end

    out = out.concat(optional_expr(arm.guard, inner)).push(Pending(step: Step.Block(arm.body), scope: inner))
  end

  return out
end

def visit_expression(ask: Query, target: Local, expr: Ast.Expr, scope: Map[String, Local]) -> Visit
  case expr
    Ast.Expr.Name(node) ->
      if scope.has_key?(node.name) and stands_for?(scope[node.name], target)
        return Visit(hits: [node.span], next: [])
      end

      return below([])
    Ast.Expr.BlockLit(node) ->
      inner = bind_parameters(ask, block_parameters_of(ask, node.params), scope).scope
      return below([Pending(step: Step.Block(node.body), scope: inner)])
    _ -> return below(Walk.children(Walk.Node.Expr(expr)).map do |child: Walk.Node| child_step(child, scope) end)
  end
end

def child_step(child: Walk.Node, scope: Map[String, Local]) -> Pending
  case child
    Walk.Node.Expr(part) -> return pending_expr(part, scope)
    Walk.Node.Stmt(part) -> return Pending(step: Step.Stmt(part), scope: scope)
  end
end

# Whether `local` is the binding of `target`: a name is bound once, so the place of the name tells.
def stands_for?(local: Local, target: Local) -> Bool
  return local.name_span.start.offset == target.name_span.start.offset
end

# A name is a use of a local when it is in scope; the parts of any other expression are searched for the one that
# holds the position.
def into_expression(ask: Query, expr: Ast.Expr, scope: Map[String, Local]) -> Move
  case expr
    Ast.Expr.Name(node) ->
      found = scope.get(node.name)
      if found.ok? and At.holds?(node.span, ask.offset)
        return hit(scope, found.unwrap!, node.span)
      end

      return stop(scope)
    Ast.Expr.BlockLit(node) -> return into_block(ask, node, scope)
    _ -> return into_child(ask, expr, scope)
  end
end

# The parameters of a block are in scope for its body. A block is the only expression that holds statements.
def into_block(ask: Query, node: Ast.BlockLit, scope: Map[String, Local]) -> Move
  bound = bind_parameters(ask, block_parameters_of(ask, node.params), scope)
  case bound.found
    some(_) -> return bound
    none -> return go(Step.Block(node.body), bound.scope)
  end
end

def into_child(ask: Query, expr: Ast.Expr, scope: Map[String, Local]) -> Move
  for child in Walk.children(Walk.Node.Expr(expr))
    case child
      Walk.Node.Expr(part) ->
        if reaches?(part, ask.offset)
          return go(Step.Expr(part), scope)
        end

      Walk.Node.Stmt(_) -> scope = scope
    end
  end

  return stop(scope)
end

# Whether the character at `offset` is in the expression or in the value piped into it: `x |> f(y)` is a call whose
# span starts at `f`, with `x` as its first argument, and each step of a chain starts earlier than its own span.
def reaches?(expr: Ast.Expr, offset: Int) -> Bool
  span = Ast.expr_span(expr)
  return reach_start(expr) <= offset and offset < span.stop.offset
end

def reach_start(expr: Ast.Expr) -> Int
  start = Ast.expr_span(expr).start.offset
  current = expr
  looping = true
  while looping
    case current
      Ast.Expr.Call(node) ->
        if node.piped and node.args.size > 0
          current = node.args[0]
          start = Ast.expr_span(current).start.offset
        else
          looping = false
        end

      _ -> looping = false
    end
  end

  return start
end
