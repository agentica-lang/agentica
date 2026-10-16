## How the checker reads the tree of a constant's initializer (docs/future/44-module-constants.md): the children of a
## node in source order, and the reads of other constants below it.

import Ast from "ast"

## An expression or a statement, the two kinds of node a block body mixes.
export enum Node
  Expr(Ast.Expr)
  Stmt(Ast.Stmt)
end

## The expressions and statements directly below a node, in source order. Named arguments, map entries, if branches and
## case arms are not nodes of their own here: their parts come in the place of the wrapper.
export def children(node: Node) -> List[Node]
  case node
    Node.Expr(expr) -> return expr_children(expr)
    Node.Stmt(stmt) -> return stmt_children(stmt)
  end
end

## The start offset of a read, the key the reads are ordered by.
export def read_offset(read: Ast.ConstRef) -> Int
  return read.span.start.offset
end

## The reads of constants below an initializer, ordered by the start offsets of the reads in the source text, so the
## order does not depend on how a tree stores its parts (a map entry gives its key before its value). It walks with a
## worklist and no recursion: it runs before the checker has bounded the depth of the tree.
export def references(root: Ast.Expr) -> List[Ast.ConstRef]
  found: List[Ast.ConstRef] = []
  work: List[Node] = [Node.Expr(root)]
  at = 0
  while at < work.size
    node = work[at]
    at += 1
    case node
      Node.Expr(expr) -> found = push_read(found, expr)
      Node.Stmt(stmt) -> found = found
    end
    for child in children(node)
      work = work.push(child)
    end
  end
  return found.sort_by do |read: Ast.ConstRef| read_offset(read) end
end

def push_read(found: List[Ast.ConstRef], expr: Ast.Expr) -> List[Ast.ConstRef]
  case expr
    Ast.Expr.ConstRef(read) -> return found.push(read)
    _ -> return found
  end
end

def exprs(items: List[Ast.Expr]) -> List[Node]
  return items.map do |item: Ast.Expr| Node.Expr(item) end
end

def stmts(items: List[Ast.Stmt]) -> List[Node]
  return items.map do |item: Ast.Stmt| Node.Stmt(item) end
end

def named_values(args: List[Ast.NamedArg]) -> List[Node]
  return args.map do |arg: Ast.NamedArg| Node.Expr(arg.value) end
end

def expr_children(expr: Ast.Expr) -> List[Node]
  case expr
    Ast.Expr.Call(node) -> return exprs(node.args)
    Ast.Expr.EnumConstructor(node) -> return exprs(node.args).concat(named_values(node.named))
    Ast.Expr.Invoke(node) -> return [Node.Expr(node.target)].concat(exprs(node.args))
    Ast.Expr.Construct(node) -> return named_values(node.args)
    Ast.Expr.Update(node) -> return [Node.Expr(node.target)].concat(named_values(node.args))
    Ast.Expr.ListLit(node) -> return exprs(node.elements)
    Ast.Expr.MapLit(node) -> return entries(node.entries)
    Ast.Expr.FieldAccess(node) -> return [Node.Expr(node.target)]
    Ast.Expr.MethodCall(node) -> return [Node.Expr(node.target)].concat(exprs(node.args))
    Ast.Expr.Interpolation(node) -> return interpolated(node.parts)
    Ast.Expr.BlockLit(node) -> return stmts(node.body)
    Ast.Expr.Index(node) -> return [Node.Expr(node.target), Node.Expr(node.index)]
    Ast.Expr.Try(node) -> return [Node.Expr(node.operand)]
    Ast.Expr.Unary(node) -> return [Node.Expr(node.operand)]
    Ast.Expr.Binary(node) -> return [Node.Expr(node.left), Node.Expr(node.right)]
    Ast.Expr.Typed(node) -> return [Node.Expr(node.target)]
    _ -> return []
  end
end

def entries(items: List[Ast.MapEntry]) -> List[Node]
  out: List[Node] = []
  for entry in items
    out = out.push(Node.Expr(entry.key)).push(Node.Expr(entry.value))
  end
  return out
end

def interpolated(parts: List[Ast.Part]) -> List[Node]
  out: List[Node] = []
  for part in parts
    case part
      Ast.Part.Code(code) -> out = out.push(Node.Expr(code))
      Ast.Part.Text(text) -> out = out
    end
  end
  return out
end

def stmt_children(stmt: Ast.Stmt) -> List[Node]
  case stmt
    Ast.Stmt.Binding(node) -> return [Node.Expr(node.value)]
    Ast.Stmt.Return(node) -> return optional_value(node.value)
    Ast.Stmt.Expression(node) -> return [Node.Expr(node.value)]
    Ast.Stmt.If(node) -> return if_children(node)
    Ast.Stmt.While(node) -> return [Node.Expr(node.condition)].concat(stmts(node.body))
    Ast.Stmt.For(node) -> return [Node.Expr(node.iterable)].concat(stmts(node.body))
    Ast.Stmt.Case(node) -> return case_children(node)
    Ast.Stmt.Control(node) -> return []
  end
end

def optional_value(value: Ast.Optional[Ast.Expr]) -> List[Node]
  case value
    Ast.Optional.Present(found) -> return [Node.Expr(found)]
    Ast.Optional.Absent -> return []
  end
end

def if_children(node: Ast.IfStmt) -> List[Node]
  out: List[Node] = []
  for branch in node.branches
    out = out.push(Node.Expr(branch.condition)).concat(stmts(branch.body))
  end
  case node.else_body
    Ast.Optional.Present(body) -> return out.concat(stmts(body))
    Ast.Optional.Absent -> return out
  end
end

def case_children(node: Ast.CaseStmt) -> List[Node]
  out: List[Node] = [Node.Expr(node.value)]
  for arm in node.arms
    out = out.concat(optional_value(arm.guard)).concat(stmts(arm.body))
  end
  return out
end
