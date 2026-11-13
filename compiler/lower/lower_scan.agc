## What lowering reads off the tree before it lowers anything: the module constants, the functions and the watched type
## names a body mentions. One walk per body, with a worklist, so the depth of the tree does not matter.

import Ast from "../syntax/ast"
import AstWalk from "../syntax/ast_walk"

## What a body mentions. consts are the linked names of the constants it reads and calls the names of the functions it
## calls or takes with `&`, in the order found. written are the watched type names it writes (a type, a type used as a
## value, an enum constructor, a pattern), type_names the linked names it uses as a value (JSON.decode(Person, ...)),
## and type_ids the ids of those nodes, where the checker recorded the type of a JSON target, and of the Type.codec
## field accesses, whose type is the Codec (lowering.agc json_targets). covered are the ids of some(x), ok(x) and
## [x, ...]: check_some, check_ok and check_list build their type, a List, Optional or Result, around a type with the
## names of the type recorded at x's id, so lowering.agc's top_names reads only its top. regexes are the regex literals
## of a function body: each one reads the constant regex_constant names, which lowering.agc makes for it, so a literal
## is compiled once.
struct Scan
  consts: List[String]
  calls: List[String]
  written: List[String]
  type_names: List[String]
  type_ids: List[Int]
  covered: List[Int]
  regexes: List[Ast.RegexLit]
end

## The scan of the statements of a function body, and of the types it writes.
def scan_body(body: List[Ast.Stmt], watched: Set[String]) -> Scan
  work: List[AstWalk.Node] = body.map do |stmt: Ast.Stmt| AstWalk.Node.Stmt(stmt) end
  walk(work, watched, empty(), true)
end

## The scan of the initializer of a constant. A regex literal there is built with the constant, so the scan goes into
## its call.
def scan_value(value: Ast.Expr, watched: Set[String]) -> Scan
  walk([AstWalk.Node.Expr(value)], watched, empty(), false)
end

## The linked name of the constant that holds a regex literal of a function body. `#` keeps it apart from every name a
## program can write.
def regex_constant(node: Ast.RegexLit) -> String = "regex##{node.id}"

## The watched names a type annotation writes, nested names included.
def written_in(ref: Ast.TypeRef, watched: Set[String]) -> List[String]
  found: List[String] = []
  if watched.include?(ref.name)
    found = [ref.name]
  end

  for arg in ref.args
    found = found.concat(written_in(arg, watched))
  end

  found
end

## The watched names the signature of a function writes: its parameters and result.
def written_signature(decl: Ast.FunctionDecl, watched: Set[String]) -> List[String]
  found = written_in(decl.result, watched)
  for param in decl.params
    found = found.concat(written_in(param.type, watched))
  end

  found
end

private

def empty() -> Scan = Scan(consts: [], calls: [], written: [], type_names: [], type_ids: [], covered: [], regexes: [])

def walk(start: List[AstWalk.Node], watched: Set[String], first: Scan, hoist: Bool) -> Scan
  work = start
  found = first
  at = 0
  while at < work.size
    node = work[at]
    at += 1
    case node
      AstWalk.Node.Expr(expr) -> found = see_expr(found, expr, watched)
      AstWalk.Node.Stmt(stmt) -> found = see_stmt(found, stmt, watched)
    end

    work = work.concat(walked_children(node))
    case node
      AstWalk.Node.Expr(Ast.Expr.RegexLit(regex)) ->
        if hoist
          found = found.with(consts: found.consts.push(regex_constant(regex)), regexes: found.regexes.push(regex))
        else
          work = work.push(AstWalk.Node.Expr(regex.call))
        end

      _ -> found = found
    end
  end

  found
end

# The children of a node, except the type name of Type.members, which is no type used as a value.
def walked_children(node: AstWalk.Node) -> List[AstWalk.Node]
  case node
    AstWalk.Node.Expr(expr) ->
      case expr
        Ast.Expr.FieldAccess(access) ->
          case access.target
            Ast.Expr.TypeName(_) ->
              # Type.codec reads the type at run time, so its name counts as a type used as a value.
              return AstWalk.children(node) if access.name == "codec"

              []
            _ -> AstWalk.children(node)
          end

        _ -> AstWalk.children(node)
      end

    _ -> AstWalk.children(node)
  end
end

def see_expr(found: Scan, expr: Ast.Expr, watched: Set[String]) -> Scan
  case expr
    Ast.Expr.ConstRef(node) -> found.with(consts: found.consts.push(node.name))
    Ast.Expr.Call(node) -> found.with(calls: found.calls.push(node.name), covered: wrapping(found.covered, node))
    Ast.Expr.FunctionRef(node) -> found.with(calls: found.calls.push(node.name))
    Ast.Expr.FieldAccess(node) ->
      # Type.codec: its type, a Codec of the struct or enum, is recorded here, not at the type name, whose id the
      # linker made past the program's.
      case node.target
        Ast.Expr.TypeName(_) -> return found.with(type_ids: found.type_ids.push(node.id)) if node.name == "codec"

        _ -> return found
      end

      found
    Ast.Expr.TypeName(node) ->
      ref = Ast.TypeRef(id: node.id, name: node.name, args: node.args, span: node.span)
      written = found.written.concat(written_in(ref, watched))
      names = found.type_names.push(node.name)
      found.with(written: written, type_names: names, type_ids: found.type_ids.push(node.id))
    Ast.Expr.EnumConstructor(node) -> found.with(written: named(found.written, node.enum_name, watched))
    Ast.Expr.BlockLit(node) -> found.with(written: block_types(found.written, node, watched))
    Ast.Expr.Case(node) -> found.with(written: arm_names(found.written, node.arms, watched))
    Ast.Expr.ListLit(node) ->
      return found.with(covered: found.covered.push(node.id)) if node.elements.size > 0

      found
    _ -> found
  end
end

# covered with the call added when it is some(x) or ok(x), whose type check_some and check_ok build around the type of
# x. Both names are builtin constructors that nothing may redefine.
def wrapping(covered: List[Int], node: Ast.Call) -> List[Int]
  return covered.push(node.id) if (node.name == "some" or node.name == "ok") and node.args.size == 1

  covered
end

def see_stmt(found: Scan, stmt: Ast.Stmt, watched: Set[String]) -> Scan
  case stmt
    Ast.Stmt.Binding(node) -> found.with(written: optional_type(found.written, node.type, watched))
    Ast.Stmt.Case(node) -> found.with(written: arm_names(found.written, node.arms, watched))
    _ -> found
  end
end

def named(written: List[String], name: String, watched: Set[String]) -> List[String]
  return written.push(name) if watched.include?(name)

  written
end

def optional_type(written: List[String], type: Optional[Ast.TypeRef], watched: Set[String]) -> List[String]
  case type
    some(ref) -> written.concat(written_in(ref, watched))
    none -> written
  end
end

def block_types(written: List[String], node: Ast.BlockLit, watched: Set[String]) -> List[String]
  for param in node.params
    written = optional_type(written, param.type, watched)
  end

  written
end

def arm_names(written: List[String], arms: List[Ast.CaseArm], watched: Set[String]) -> List[String]
  for arm in arms
    written = pattern_names(written, arm.pattern, watched)
  end

  written
end

# The enums a pattern names: its own, and those of the variants nested in its slots.
def pattern_names(written: List[String], pattern: Ast.Pattern, watched: Set[String]) -> List[String]
  case pattern
    Ast.Pattern.Variant(node) ->
      written = named(written, node.enum_name, watched)
      for slot in node.slots
        case slot
          Ast.Slot.Nested(inner) -> written = pattern_names(written, inner, watched)
          _ -> written = written
        end
      end

      written
    Ast.Pattern.Or(node) ->
      for inner in node.patterns
        written = pattern_names(written, inner, watched)
      end

      written
    _ -> written
  end
end
