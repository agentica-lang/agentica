## How the stages walk a tree without recursion: the children of a node in source order, and the reads of other
## constants below the initializer of a constant (docs/grammar/06-semantics.md). The linker (unused imports), the
## checker, lowering and the queries share it.

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
    Node.Expr(expr) -> expr_children(expr)
    Node.Stmt(stmt) -> stmt_children(stmt)
  end
end

## The start offset of a read, the key the reads are ordered by.
export def read_offset(read: Ast.ConstRef) -> Int = read.span.start.offset

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
      Node.Stmt(_) -> found = found
    end

    for child in children(node)
      work = work.push(child)
    end
  end

  found.sort_by do |read: Ast.ConstRef| read_offset(read) end
end

def push_read(found: List[Ast.ConstRef], expr: Ast.Expr) -> List[Ast.ConstRef]
  case expr
    Ast.Expr.ConstRef(read) -> found.push(read)
    _ -> found
  end
end

def exprs(items: List[Ast.Expr]) -> List[Node] = items.map do |item: Ast.Expr| Node.Expr(item) end

def stmts(items: List[Ast.Stmt]) -> List[Node] = items.map do |item: Ast.Stmt| Node.Stmt(item) end

def named_values(args: List[Ast.NamedArg]) -> List[Node] = args.map do |arg: Ast.NamedArg| Node.Expr(arg.value) end

def expr_children(expr: Ast.Expr) -> List[Node]
  case expr
    Ast.Expr.Call(node) -> exprs(node.args).concat(named_values(node.named))
    Ast.Expr.EnumConstructor(node) -> exprs(node.args).concat(named_values(node.named))
    Ast.Expr.Invoke(node) -> [Node.Expr(node.target)].concat(exprs(node.args))
    Ast.Expr.Construct(node) -> named_values(node.args)
    Ast.Expr.Update(node) -> [Node.Expr(node.target)].concat(named_values(node.args))
    Ast.Expr.ListLit(node) -> exprs(node.elements)
    Ast.Expr.MapLit(node) -> entries(node.entries)
    Ast.Expr.FieldAccess(node) -> [Node.Expr(node.target)]
    Ast.Expr.MethodCall(node) -> [Node.Expr(node.target)].concat(exprs(node.args)).concat(named_values(node.named))
    Ast.Expr.Interpolation(node) -> interpolated(node.parts)
    Ast.Expr.BlockLit(node) -> stmts(node.body)
    Ast.Expr.Index(node) -> [Node.Expr(node.target), Node.Expr(node.index)]
    Ast.Expr.Try(node) -> [Node.Expr(node.operand)]
    Ast.Expr.Unary(node) -> [Node.Expr(node.operand)]
    Ast.Expr.Binary(node) -> [Node.Expr(node.left), Node.Expr(node.right)]
    Ast.Expr.Typed(node) -> [Node.Expr(node.target)]
    Ast.Expr.EagLit(node) -> [Node.Expr(node.call)]
    Ast.Expr.Case(node) -> case_children(node)
    _ -> []
  end
end

def entries(items: List[Ast.MapEntry]) -> List[Node]
  out: List[Node] = []
  for entry in items
    out = out.push(Node.Expr(entry.key)).push(Node.Expr(entry.value))
  end

  out
end

def interpolated(parts: List[Ast.Part]) -> List[Node]
  out: List[Node] = []
  for part in parts
    case part
      Ast.Part.Code(code) -> out = out.push(Node.Expr(code))
      Ast.Part.Text(_) -> out = out
    end
  end

  out
end

def stmt_children(stmt: Ast.Stmt) -> List[Node]
  case stmt
    Ast.Stmt.Binding(node) -> [Node.Expr(node.value)]
    Ast.Stmt.Return(node) -> optional_value(node.value)
    Ast.Stmt.Expression(node) -> [Node.Expr(node.value)]
    Ast.Stmt.If(node) -> if_children(node)
    Ast.Stmt.While(node) -> [Node.Expr(node.condition)].concat(stmts(node.body))
    Ast.Stmt.For(node) -> [Node.Expr(node.iterable)].concat(stmts(node.body))
    Ast.Stmt.Case(node) -> case_children(node)
    Ast.Stmt.Control(_) -> []
  end
end

def optional_value(value: Optional[Ast.Expr]) -> List[Node]
  case value
    some(found) -> [Node.Expr(found)]
    none -> []
  end
end

def if_children(node: Ast.IfStmt) -> List[Node]
  out: List[Node] = []
  for branch in node.branches
    out = out.push(Node.Expr(branch.condition)).concat(stmts(branch.body))
  end

  case node.else_body
    some(body) -> out.concat(stmts(body))
    none -> out
  end
end

def case_children(node: Ast.CaseStmt) -> List[Node]
  out: List[Node] = [Node.Expr(node.value)]
  for arm in node.arms
    out = out.concat(optional_value(arm.guard)).concat(stmts(arm.body))
  end

  out
end
