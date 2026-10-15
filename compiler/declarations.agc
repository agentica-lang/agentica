## Helpers for the top-level declarations of a parsed file, and the declaration order rule (CHECK-DECL-ORDER).

import "ast" as Ast
import "diagnostic" as Diag
import "link_failure" as Failure
import "source" as Source

## What a top-level declaration is.
export enum Kind
  Struct
  Enum
  Function
  Import
end

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

## The kind of the declaration inside an export, or of the declaration itself.
export def kind_of(decl: Ast.Decl) -> Kind
  case unwrap(decl)
    Ast.Decl.Function(node) -> return Kind.Function
    Ast.Decl.Struct(node) -> return Kind.Struct
    Ast.Decl.Enum(node) -> return Kind.Enum
    _ -> return Kind.Import
  end
end

## True for a struct.
export def struct?(kind: Kind) -> Bool
  case kind
    Kind.Struct -> return true
    _ -> return false
  end
end

## True for a function.
export def function?(kind: Kind) -> Bool
  case kind
    Kind.Function -> return true
    _ -> return false
  end
end

## True for an enum.
export def enum?(kind: Kind) -> Bool
  case kind
    Kind.Enum -> return true
    _ -> return false
  end
end

## True for an import.
export def import?(kind: Kind) -> Bool
  case kind
    Kind.Import -> return true
    _ -> return false
  end
end

## True for an export.
export def exported?(decl: Ast.Decl) -> Bool
  case decl
    Ast.Decl.Export(node) -> return true
    _ -> return false
  end
end

## The text of the import line a help shows, for the path as written (quoted): the alias form as the file wrote it, or the name list.
export def import_line(written: String, decl: Ast.ImportDecl) -> String
  case decl.alias
    Ast.Optional.Present(alias) -> return "import " + written + " as " + alias
    Ast.Optional.Absent ->
      pieces = decl.names.map do |entry| entry_text(entry) end
      return "import {" + pieces.join(", ") + "} from " + written
  end
end

## The alias of an import, or "" for an import list (an alias is never empty).
export def alias_of(decl: Ast.ImportDecl) -> String
  case decl.alias
    Ast.Optional.Present(alias) -> return alias
    Ast.Optional.Absent -> return ""
  end
end

## True when the name starts with a capital letter, as a TYPE_NAME token does: the case rule that tells a type from a function.
export def type_name?(name: String) -> Bool
  return "ABCDEFGHIJKLMNOPQRSTUVWXYZ".contains?(name.slice(0, 1))
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

def entry_text(entry: Ast.ImportName) -> String
  if entry.name == entry.local
    return entry.name
  end
  return entry.name + " as " + entry.local
end
