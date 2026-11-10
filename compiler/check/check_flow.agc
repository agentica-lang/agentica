## What the statements of a body return: whether every path ends in a return, and the help texts that depend only on
## the shape of the code.

import Ast from "../syntax/ast"
import State from "check_state"

## True when every path of the statements ends in a return. A terminator is always the last statement of its block
## (CHECK-UNREACHABLE-CODE), so only the last one is looked at.
export def block_returns?(statements: List[Ast.Stmt]) -> Bool
  return false if statements.size == 0

  return returns?(statements[statements.size - 1])
end

## True when the statement never falls through to the next one: a return, break or next, an if with an else whose
## branches all end so, or a case whose arms all do. It does not look into loops or calls (System.exit and the `!`
## functions may halt, but have no "never returns" type), and a try leaves early only on an error.
export def ends?(statement: Ast.Stmt) -> Bool
  case statement
    Ast.Stmt.Return(_) -> return true
    Ast.Stmt.Control(_) -> return true
    Ast.Stmt.If(node) -> return if_ends?(node)
    Ast.Stmt.Case(node) -> return node.arms.all? do |arm: Ast.CaseArm| block_ends?(arm.body) end
    _ -> return false
  end
end

## The help of CHECK-UNREACHABLE-CODE: the statement before the dead one is the terminator, on `line`.
export def unreachable_help(terminator: Ast.Stmt, line: Int) -> String
  case terminator
    Ast.Stmt.If(_) -> return "every branch of the if above ends with return, break or next; #{fix_text("if")}"
    Ast.Stmt.Case(_) -> return "every arm of the case above ends with return, break or next; #{fix_text("case")}"
    Ast.Stmt.Return(_) -> return "the block ends at the return on line #{line}; #{fix_text("return")}"
    Ast.Stmt.Control(node) -> return "the block ends at the #{node.kind} on line #{line}; #{fix_text(node.kind)}"
    _ -> return ""
  end
end

## True when the statements give an error(...) call or none as the value of a return (also inside an if, a loop or a
## case arm) or as the last expression. The call has no type of its own, so a block with such a value may need its
## result type from another path (Stmt.check_block_in).
export def gives_error?(statements: List[Ast.Stmt]) -> Bool
  return false if statements.size == 0

  last = statements[statements.size - 1]
  case last
    Ast.Stmt.Expression(node) -> return error_call?(node.value) or error_returns?(statements)
    _ -> return error_returns?(statements)
  end
end

## The help of CHECK-MISSING-RETURN: what is missing at the end of the body, or "".
export def missing_return_help(body: List[Ast.Stmt], type_name: String) -> String
  if !contains_return?(body)
    return "add \"return <value>\" of type #{type_name} at the end"
  elsif body.size == 0
    return ""
  end

  last = body[body.size - 1]
  case last
    Ast.Stmt.If(node) -> return if_help(node, type_name)
    Ast.Stmt.While(_) -> return loop_help(type_name)
    Ast.Stmt.For(_) -> return loop_help(type_name)
    Ast.Stmt.Case(_) -> return "every arm of the last \"case\" must end with return, or return #{type_name} after it"
    _ -> return ""
  end
end

## The help of CHECK-MISSING-RETURN for a loop at the end of the body.
export def loop_help(type_name: String) -> String
  return "a loop does not count as a return; add \"return <value>\" of type #{type_name} after it"
end

## The message of CHECK-CAPTURED-ASSIGNMENT. A template is a block of its function (eag.agc), so two assignments get a
## message of their own: a block of a tag that writes the output, and a tag that assigns a variable of the function.
export def captured_message(name: String, capture: State.Capture) -> String
  if name == Ast.EAG_PIECES
    return "a block in a template cannot write output"
  elsif template_block?(capture)
    return "a template cannot assign \"#{name}\", a variable of the function"
  end

  return "a block cannot assign to \"#{name}\", which belongs to the enclosing code"
end

## The help of CHECK-CAPTURED-ASSIGNMENT: a for loop can assign.
export def captured_help(name: String, capture: State.Capture) -> String
  return "compute it before the template, or use a new name inside it" if template_block?(capture)

  element = "x"
  if capture.params.size == 1 and capture.params[0].name != "_"
    element = capture.params[0].name
  end

  path = ""
  case capture.each_receiver
    some(receiver) -> path = path_text(receiver)
    none -> path = path
  end

  if name == Ast.EAG_PIECES
    shown = "xs"
    if path != "" and path.length <= 40
      shown = path
    end

    return "a block cannot write the output of a template: use a for loop, for #{element} in #{shown} ... end"
  end

  if path != "" and path.length <= 40
    return "blocks capture values; use a for loop, which can assign \"#{name}\": for #{element} in #{path} ... end"
  end

  return (
    "blocks capture values; use a for loop, which can assign \"#{name}\": for #{element} in xs ... end, " +
    "or build it with xs.reduce(#{name}) do |acc, #{element}| ... end"
  )
end

# Whether the block is the one that holds a template.
def template_block?(capture: State.Capture) -> Bool
  return capture.params.size == 1 and capture.params[0].name == Ast.EAG_SEED
end

def fix_text(word: String) -> String = "remove this statement, or move it before the #{word}"

def returns?(statement: Ast.Stmt) -> Bool
  case statement
    Ast.Stmt.Return(_) -> return true
    Ast.Stmt.If(node) -> return if_returns?(node)
    Ast.Stmt.Case(node) -> return node.arms.all? do |arm: Ast.CaseArm| block_returns?(arm.body) end
    _ -> return false
  end
end

def block_ends?(statements: List[Ast.Stmt]) -> Bool
  return false if statements.size == 0

  return ends?(statements[statements.size - 1])
end

# An if ends on every path when it has an else and every branch ends.
def if_ends?(node: Ast.IfStmt) -> Bool
  case node.else_body
    some(body) ->
      return block_ends?(body) and node.branches.all? do |branch: Ast.IfBranch| block_ends?(branch.body) end
    none -> return false
  end
end

# An if returns on every path when it has an else and every branch returns.
def if_returns?(node: Ast.IfStmt) -> Bool
  case node.else_body
    some(body) ->
      return block_returns?(body) and node.branches.all? do |branch: Ast.IfBranch| block_returns?(branch.body) end
    none -> return false
  end
end

def contains_return?(statements: List[Ast.Stmt]) -> Bool
  return statements.any? do |statement: Ast.Stmt| holds_return?(statement) end
end

def holds_return?(statement: Ast.Stmt) -> Bool
  case statement
    Ast.Stmt.Return(_) -> return true
    Ast.Stmt.If(node) -> return if_holds_return?(node)
    Ast.Stmt.While(node) -> return contains_return?(node.body)
    Ast.Stmt.For(node) -> return contains_return?(node.body)
    Ast.Stmt.Case(node) -> return node.arms.any? do |arm: Ast.CaseArm| contains_return?(arm.body) end
    _ -> return false
  end
end

def if_holds_return?(node: Ast.IfStmt) -> Bool
  return true if node.branches.any? do |branch: Ast.IfBranch| contains_return?(branch.body) end

  case node.else_body
    some(body) -> return contains_return?(body)
    none -> return false
  end
end

def if_help(node: Ast.IfStmt, type_name: String) -> String
  if node.guard
    return "the last statement is a guard, which returns only when its condition holds; return #{type_name} after it"
  end

  case node.else_body
    some(_) -> return "every branch of the last \"if\" must end with return, or return #{type_name} after it"
    none -> return "the last \"if\" has no \"else\"; add an \"else\" that returns #{type_name}, or return after it"
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
  return "" if target == ""

  return "#{target}.#{node.name}"
end

def error_returns?(statements: List[Ast.Stmt]) -> Bool
  return statements.any? do |statement: Ast.Stmt| returns_error?(statement) end
end

def returns_error?(statement: Ast.Stmt) -> Bool
  case statement
    Ast.Stmt.Return(node) -> return returned_error?(node)
    Ast.Stmt.If(node) -> return if_returns_error?(node)
    Ast.Stmt.While(node) -> return error_returns?(node.body)
    Ast.Stmt.For(node) -> return error_returns?(node.body)
    Ast.Stmt.Case(node) -> return node.arms.any? do |arm: Ast.CaseArm| error_returns?(arm.body) end
    _ -> return false
  end
end

def returned_error?(node: Ast.Return) -> Bool
  case node.value
    some(value) -> return error_call?(value)
    none -> return false
  end
end

def if_returns_error?(node: Ast.IfStmt) -> Bool
  return true if node.branches.any? do |branch: Ast.IfBranch| error_returns?(branch.body) end

  case node.else_body
    some(body) -> return error_returns?(body)
    none -> return false
  end
end

def error_call?(expr: Ast.Expr) -> Bool
  case expr
    Ast.Expr.Call(node) -> return node.name == "error" or node.name == "none"
    _ -> return false
  end
end
