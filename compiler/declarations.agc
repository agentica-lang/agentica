## Helpers for the top-level declarations of a parsed file, and the declaration order rule (CHECK-DECL-ORDER).

import "ast" as Ast
import "diagnostic" as Diag
import "link_failure" as Failure
import "source" as Source

## The declaration inside an export, or the declaration itself.
export def unwrap(decl: Ast.Decl) -> Ast.Decl
  case decl
    Ast.Decl.Export(node) -> return node.declaration
    _ -> return decl
  end
end

## The span of a declaration (of the whole export, for an exported one).
export def span_of(decl: Ast.Decl) -> Source.Span
  case decl
    Ast.Decl.Import(node) -> return node.span
    Ast.Decl.Export(node) -> return node.span
    Ast.Decl.Function(node) -> return node.span
    Ast.Decl.Struct(node) -> return node.span
    Ast.Decl.Enum(node) -> return node.span
  end
end

## The name a struct, enum or function declares; "" for an import.
export def name_of(decl: Ast.Decl) -> String
  case unwrap(decl)
    Ast.Decl.Function(node) -> return node.name
    Ast.Decl.Struct(node) -> return node.name
    Ast.Decl.Enum(node) -> return node.name
    _ -> return ""
  end
end

## "struct", "enum" or "function" for the declaration inside an export or not; "import" for an import.
export def kind_of(decl: Ast.Decl) -> String
  case unwrap(decl)
    Ast.Decl.Function(node) -> return "function"
    Ast.Decl.Struct(node) -> return "struct"
    Ast.Decl.Enum(node) -> return "enum"
    _ -> return "import"
  end
end

## True for an export.
export def exported?(decl: Ast.Decl) -> Bool
  case decl
    Ast.Decl.Export(node) -> return true
    _ -> return false
  end
end

## The imports of a file, in order.
export def imports_of(declarations: List[Ast.Decl]) -> List[Ast.ImportDecl]
  found: List[Ast.ImportDecl] = []
  for decl in declarations
    case decl
      Ast.Decl.Import(node) -> found = found.push(node)
      _ -> next
    end
  end
  return found
end

## CHECK-DECL-ORDER, in file, for the first declaration that comes after a later group. The groups are: imports, then struct and enum (exported or not), then export def, then def. The span is that of the declaration out of place; the help names the group it belongs to. This is a style rule with no meaning for evaluation (src/modules.rkt, declaration-order-error).
export def check_order(file: String, declarations: List[Ast.Decl]) -> Result[Void]
  highest = 0
  for decl in declarations
    group = rank(decl)
    if group < highest
      problem = Diag.fail("CHECK-DECL-ORDER", "declaration is out of order", span_of(decl), Diag.Help.Hint(order_help(group)))
      return error(Failure.from_stage(file, problem))
    end
    if group > highest
      highest = group
    end
  end
  return ok()
end

def rank(decl: Ast.Decl) -> Int
  case decl
    Ast.Decl.Import(node) -> return 0
    Ast.Decl.Struct(node) -> return 1
    Ast.Decl.Enum(node) -> return 1
    Ast.Decl.Export(node) ->
      case node.declaration
        Ast.Decl.Struct(inner) -> return 1
        Ast.Decl.Enum(inner) -> return 1
        _ -> return 2
      end
    Ast.Decl.Function(node) -> return 3
  end
end

def order_help(group: Int) -> String
  case group
    0 -> return "imports come first, before any struct, enum or function"
    1 -> return "structs and enums come before functions"
    _ -> return "exported functions come before private functions"
  end
end
