## What the statements of a body return (src/checker.rkt: block-returns?, missing-return-help,
## captured-assignment-help): whether every path ends in a return, and the help texts that depend only on the shape of
## the code.

import Ast from "ast"
import State from "check_state"

## True when every path of the statements ends in a return.
export def block_returns?(statements: List[Ast.Stmt]) -> Bool
  return statements.any? do |statement: Ast.Stmt| returns?(statement) end
end

## The help of CHECK-MISSING-RETURN: what is missing at the end of the body, or "".
export def missing_return_help(body: List[Ast.Stmt], type_name: String) -> String
  if !contains_return?(body)
    return "add \"return <value>\" of type " + type_name + " at the end"
  elsif body.size == 0
    return ""
  end
  last = body[body.size - 1]
  case last
    Ast.Stmt.If(node) -> return if_help(node, type_name)
    Ast.Stmt.While(node) -> return loop_help(type_name)
    Ast.Stmt.For(node) -> return loop_help(type_name)
    Ast.Stmt.Case(node) -> return (
      "every arm of the last \"case\" must end with return, or return " +
      type_name +
      " after it"
    )
    _ -> return ""
  end
end

## The help of CHECK-MISSING-RETURN for a loop at the end of the body.
export def loop_help(type_name: String) -> String
  return "a loop does not count as a return; add \"return <value>\" of type " + type_name + " after it"
end

## The help of CHECK-CAPTURED-ASSIGNMENT: a for loop can assign.
export def captured_help(name: String, capture: State.Capture) -> String
  element = "x"
  if capture.params.size == 1
    element = capture.params[0].name
  end
  path = ""
  case capture.each_receiver
    Ast.Optional.Present(receiver) -> path = path_text(receiver)
    Ast.Optional.Absent -> path = path
  end
  if path != "" and path.length <= 40
    return (
      "blocks capture values; use a for loop, which can assign \"" +
      name +
      "\": for " +
      element +
      " in " +
      path +
      " ... end"
    )
  end
  return (
    "blocks capture values; use a for loop, which can assign \"" +
    name +
    "\": for " +
    element +
    " in xs ... end, or build it with xs.reduce(" +
    name +
    ") do |acc, " +
    element +
    "| ... end"
  )
end

def returns?(statement: Ast.Stmt) -> Bool
  case statement
    Ast.Stmt.Return(node) -> return true
    Ast.Stmt.If(node) -> return if_returns?(node)
    Ast.Stmt.Case(node) -> return node.arms.all? do |arm: Ast.CaseArm| block_returns?(arm.body) end
    _ -> return false
  end
end

# An if returns on every path when it has an else and every branch returns.
def if_returns?(node: Ast.IfStmt) -> Bool
  case node.else_body
    Ast.Optional.Present(body) ->
      return block_returns?(body) and node.branches.all? do |branch: Ast.IfBranch| block_returns?(branch.body) end
    Ast.Optional.Absent -> return false
  end
end

def contains_return?(statements: List[Ast.Stmt]) -> Bool
  return statements.any? do |statement: Ast.Stmt| holds_return?(statement) end
end

def holds_return?(statement: Ast.Stmt) -> Bool
  case statement
    Ast.Stmt.Return(node) -> return true
    Ast.Stmt.If(node) -> return if_holds_return?(node)
    Ast.Stmt.While(node) -> return contains_return?(node.body)
    Ast.Stmt.For(node) -> return contains_return?(node.body)
    Ast.Stmt.Case(node) -> return node.arms.any? do |arm: Ast.CaseArm| contains_return?(arm.body) end
    _ -> return false
  end
end

def if_holds_return?(node: Ast.IfStmt) -> Bool
  if node.branches.any? do |branch: Ast.IfBranch| contains_return?(branch.body) end
    return true
  end
  case node.else_body
    Ast.Optional.Present(body) -> return contains_return?(body)
    Ast.Optional.Absent -> return false
  end
end

def if_help(node: Ast.IfStmt, type_name: String) -> String
  case node.else_body
    Ast.Optional.Present(body) -> return (
      "every branch of the last \"if\" must end with return, or return " +
      type_name +
      " after it"
    )
    Ast.Optional.Absent -> return (
      "the last \"if\" has no \"else\"; add an \"else\" that returns " +
      type_name +
      ", or return after it"
    )
  end
end

# A name or a chain of field accesses as text (a.b.c), or "" for any other expression.
def path_text(expr: Ast.Expr) -> String
  case expr
    Ast.Expr.Name(node) -> return node.name
    Ast.Expr.FieldAccess(node) -> return field_path(node)
    Ast.Expr.Typed(node) -> return path_text(node.target)
    _ -> return ""
  end
end

def field_path(node: Ast.FieldAccess) -> String
  target = path_text(node.target)
  if target == ""
    return ""
  end
  return target + "." + node.name
end
