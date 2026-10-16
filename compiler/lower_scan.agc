## What lowering reads off the tree before it lowers anything: the module constants, the functions and the watched type
## names a body mentions. One walk per body, with a worklist, so the depth of the tree does not matter.

import Ast from "ast"
import ConstWalk from "const_walk"

## What a body mentions. consts are the linked names of the constants it reads and calls the names of the functions it
## calls or takes with `&`, in the order found. written are the watched type names it writes (a type, a type used as a
## value, an enum constructor, a pattern), and type_value says that it uses a type name as a value (JSON.decode(Person,
## ...)).
export struct Scan
  consts: List[String]
  calls: List[String]
  written: List[String]
  type_value: Bool
end

## The scan of the statements of a function body, and of the types it writes.
export def scan_body(body: List[Ast.Stmt], watched: Set[String]) -> Scan
  work: List[ConstWalk.Node] = body.map do |stmt: Ast.Stmt| ConstWalk.Node.Stmt(stmt) end
  return walk(work, watched, empty())
end

## The scan of the initializer of a constant.
export def scan_value(value: Ast.Expr, watched: Set[String]) -> Scan
  return walk([ConstWalk.Node.Expr(value)], watched, empty())
end

## The watched names a type annotation writes, nested names included.
export def written_in(ref: Ast.TypeRef, watched: Set[String]) -> List[String]
  found: List[String] = []
  if watched.include?(ref.name)
    found = [ref.name]
  end
  for arg in ref.args
    found = found.concat(written_in(arg, watched))
  end
  return found
end

## The watched names the signature of a function writes: its parameters and result.
export def written_signature(decl: Ast.FunctionDecl, watched: Set[String]) -> List[String]
  found = written_in(decl.result, watched)
  for param in decl.params
    found = found.concat(written_in(param.type, watched))
  end
  return found
end

def empty() -> Scan
  return Scan(consts: [], calls: [], written: [], type_value: false)
end

def walk(start: List[ConstWalk.Node], watched: Set[String], first: Scan) -> Scan
  work = start
  found = first
  at = 0
  while at < work.size
    node = work[at]
    at += 1
    case node
      ConstWalk.Node.Expr(expr) -> found = see_expr(found, expr, watched)
      ConstWalk.Node.Stmt(stmt) -> found = see_stmt(found, stmt, watched)
    end
    work = work.concat(ConstWalk.children(node))
  end
  return found
end

def see_expr(found: Scan, expr: Ast.Expr, watched: Set[String]) -> Scan
  case expr
    Ast.Expr.ConstRef(node) -> return found.with(consts: found.consts.push(node.name))
    Ast.Expr.Call(node) -> return found.with(calls: found.calls.push(node.name))
    Ast.Expr.FunctionRef(node) -> return found.with(calls: found.calls.push(node.name))
    Ast.Expr.TypeName(node) -> return found.with(written: named(found.written, node.name, watched), type_value: true)
    Ast.Expr.EnumConstructor(node) -> return found.with(written: named(found.written, node.enum_name, watched))
    Ast.Expr.BlockLit(node) -> return found.with(written: block_types(found.written, node, watched))
    _ -> return found
  end
end

def see_stmt(found: Scan, stmt: Ast.Stmt, watched: Set[String]) -> Scan
  case stmt
    Ast.Stmt.Binding(node) -> return found.with(written: optional_type(found.written, node.type, watched))
    Ast.Stmt.Case(node) -> return found.with(written: arm_names(found.written, node.arms, watched))
    _ -> return found
  end
end

def named(written: List[String], name: String, watched: Set[String]) -> List[String]
  if watched.include?(name)
    return written.push(name)
  end
  return written
end

def optional_type(written: List[String], type: Ast.Optional[Ast.TypeRef], watched: Set[String]) -> List[String]
  case type
    Ast.Optional.Present(ref) -> return written.concat(written_in(ref, watched))
    Ast.Optional.Absent -> return written
  end
end

def block_types(written: List[String], node: Ast.BlockLit, watched: Set[String]) -> List[String]
  for param in node.params
    written = optional_type(written, param.type, watched)
  end
  return written
end

def arm_names(written: List[String], arms: List[Ast.CaseArm], watched: Set[String]) -> List[String]
  for arm in arms
    case arm.pattern
      Ast.Pattern.Variant(pattern) -> written = named(written, pattern.enum_name, watched)
      _ -> written = written
    end
  end
  return written
end
