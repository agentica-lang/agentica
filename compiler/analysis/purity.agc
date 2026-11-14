## Purity for `bodies` (#1159): why a function of a linked program is not pure, through every function it calls. A
## builtin is pure when its catalog row lists no `effects`, so one that can halt (`+`, `b[i]`, `unwrap!`) is pure. A
## call of an `extern module` function is not, nor is anything that may run a function value: `f.call(x)`, a call of an
## Fn field, a builtin given a function value, a Lazy terminal. A call the checker did not resolve is not pure either:
## what is not known to be pure is not. A reference `&name` counts as a call of `name`. Each reason is found once, by
## the shortest chain of calls, so recursion and cycles end.

import Builtins from "../catalog/builtins"
import State from "../check/check_state"
import Checker from "../check/checker"
import DiagnosticModel from "../diagnostics/diagnostic_model"
import Linker from "../modules/linker"
import Ast from "../syntax/ast"
import AstWalk from "../syntax/ast_walk"
import Source from "../syntax/source"
import Types from "../syntax/types"
import Model from "model"

## The functions of every module of `linked`, by linked name.
struct Program
  functions: Map[String, Ast.FunctionDecl]
  checked: Checker.Checked
end

## What the walk of each function found, by linked name: computed once, as a question needs it.
struct Known
  direct: Map[String, Direct]
end

## The reasons of one function and what is known after the question.
struct Reasoned
  reasons: List[Model.Reason]
  known: Known
end

## The functions of `linked` (checked as `checked`), and nothing known yet.
def program(linked: Linker.Linked, checked: Checker.Checked) -> Program
  functions: Map[String, Ast.FunctionDecl] = {}
  for module in linked.modules
    for decl in module.declarations
      case decl
        Ast.Decl.Function(node) -> functions = functions.put(node.name, node)
        _ -> next
      end
    end
  end

  Program(functions: functions, checked: checked)
end

## Nothing known yet.
def unknown() -> Known = Known(direct: {})

## Why the function `name` is not pure (none when it is), with what `known` held and what this question added. A
## reason's `through` is the chain of functions from the first one `name` calls to the one that makes the call.
def reasons(program: Program, known: Known, name: String) -> Reasoned
  found: List[Model.Reason] = []
  seen: Set[String] = Set.new([name])
  queue = [Step(name: name, path: [])]
  at = 0
  while at < queue.size
    step = queue[at]
    at += 1
    direct = known.direct.get(step.name)
    if direct.none?
      made = walk(program, program.functions[step.name])
      known = known.with(direct: known.direct.put(step.name, made))
      direct = some(made)
    end

    own = direct.unwrap!
    found = found.concat(own.reasons.map do |reason: Model.Reason| reason.with(through: step.path) end)
    for callee in own.calls
      if !seen.include?(callee)
        seen = seen.add(callee)
        queue = queue.push(Step(name: callee, path: step.path.push(callee)))
      end
    end
  end

  Reasoned(reasons: found, known: known)
end

private

# The effect of a call of a function value: what it calls is not known here.
FUNCTION_VALUE = "function-value"

# The effect of a call of a function of an `extern module`.
NATIVE = "native"

# The effect of a call whose target the checker did not record: it is not known to be pure.
UNRESOLVED = "unresolved"

# What one function does itself: its reasons (with no chain) and the functions of the program it calls, in order.
struct Direct
  reasons: List[Model.Reason]
  calls: List[String]
end

struct Step
  name: String
  path: List[String]
end

# Walks the body and the parameter defaults of `node` with a worklist, as AstWalk does: the tree may be deep.
def walk(program: Program, node: Ast.FunctionDecl) -> Direct
  work = node.body.map do |stmt: Ast.Stmt| AstWalk.Node.Stmt(stmt) end
  for param in node.params
    case param.default
      some(value) -> work = work.push(AstWalk.Node.Expr(value))
      none -> next
    end
  end

  direct = Direct(reasons: [], calls: [])
  while work.size > 0
    item = work.last
    work = work.take(work.size - 1).concat(AstWalk.children(item).reverse)
    case item
      AstWalk.Node.Expr(expr) -> direct = expression(program, direct, expr)
      AstWalk.Node.Stmt(_) -> next
    end
  end

  direct
end

def expression(program: Program, direct: Direct, expr: Ast.Expr) -> Direct
  span = Ast.expr_span(expr)
  case expr
    Ast.Expr.Call(node) -> named(program, direct, node.name, span, given(node.args, node.named))
    Ast.Expr.FunctionRef(node) -> named(program, direct, node.name, span, [])
    Ast.Expr.MethodCall(node) ->
      resolved(program, direct, node.id, span, [node.target].concat(given(node.args, node.named)), true)
    Ast.Expr.FieldAccess(node) -> resolved(program, direct, node.id, span, [node.target], false)
    Ast.Expr.Invoke(_) -> with_reason(direct, FUNCTION_VALUE, "call", span)
    _ -> direct
  end
end

# What a method call or a field access resolved to. A field read resolves to nothing; a method call that resolved to
# nothing is not known, so it is not pure.
def resolved(
  program: Program,
  direct: Direct,
  id: Int,
  span: Source.Span,
  args: List[Ast.Expr],
  method: Bool,
) -> Direct
  case program.checked.resolved.get(id)
    some(found) ->
      case found
        State.Resolved.Call(name, _) -> named(program, direct, name, span, args)
        State.Resolved.FieldCall -> with_reason(direct, FUNCTION_VALUE, "call", span)
        State.Resolved.Self(_) -> direct
        State.Resolved.Text(_) -> direct
        State.Resolved.Inspect(_) -> direct
        State.Resolved.Members(_) -> direct
        State.Resolved.Codec(_, _) -> direct
      end

    none ->
      return with_reason(direct, UNRESOLVED, "", span) if method

      direct
  end
end

# A call of `name` with `args`: a function of the program (one of an `extern module` is not pure), or a builtin with
# its effects. A builtin given a function value that is not a block or `&name` written here may call it.
def named(program: Program, direct: Direct, name: String, span: Source.Span, args: List[Ast.Expr]) -> Direct
  case program.functions.get(name)
    some(node) ->
      return with_reason(direct, NATIVE, name, span) if node.native.some?
      return direct if direct.calls.include?(name)

      return direct.with(calls: direct.calls.push(name))
    none -> direct = direct
  end

  case Builtins.lookup(name)
    some(builtin) ->
      made = direct
      for effect in builtin.effects
        made = with_reason(made, effect, name, span)
      end

      if args.any? do |arg: Ast.Expr| function_value?(program, arg) end
        made = with_reason(made, FUNCTION_VALUE, name, span)
      end

      # A terminal of a Lazy runs the source and the steps that made it, which the caller may have built.
      if name.start_with?("Lazy.") and !lazy?(builtin.result)
        made = with_reason(made, FUNCTION_VALUE, name, span)
      end

      made
    none -> with_reason(direct, UNRESOLVED, name, span)
  end
end

def given(args: List[Ast.Expr], named: List[Ast.NamedArg]) -> List[Ast.Expr]
  args.concat(named.map do |arg: Ast.NamedArg| arg.value end)
end

def function_value?(program: Program, arg: Ast.Expr) -> Bool
  case arg
    Ast.Expr.BlockLit(_) -> false
    Ast.Expr.FunctionRef(_) -> false
    _ ->
      id = Ast.expr_id(arg)
      return false if id < 0 or id >= program.checked.types.size

      case program.checked.types[id]
        Types.Type.Fn(_, _) -> true
        _ -> false
      end
  end
end

def lazy?(type: Types.Type) -> Bool
  case type
    Types.Type.Lazy(_) -> true
    _ -> false
  end
end

def with_reason(direct: Direct, effect: String, call: String, span: Source.Span) -> Direct
  reason = Model.Reason(effect: effect, call: call, range: DiagnosticModel.range_of(span), through: [])
  direct.with(reasons: direct.reasons.push(reason))
end
