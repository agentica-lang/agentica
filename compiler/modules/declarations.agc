## Helpers for the top-level declarations of a parsed file, and the declaration order rule (CHECK-DECL-ORDER).

import Diag from "../diagnostics/diagnostic"
import Ast from "../syntax/ast"
import Base from "../syntax/parse_base"
import Source from "../syntax/source"
import Failure from "link_failure"

## What a top-level declaration is.
export enum Kind
  Struct
  Enum
  TypeAlias
  Resource
  Function
  Constant
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
    Ast.Decl.TypeAlias(node) -> return node.span
    Ast.Decl.Resource(node) -> return node.span
    Ast.Decl.Constant(node) -> return node.span
  end
end

## Returns the span of the name of a type alias, and the span of the whole declaration for any other one.
export def name_span_of(decl: Ast.Decl) -> Source.Span
  case unwrap(decl)
    Ast.Decl.TypeAlias(node) -> return node.name_span
    _ -> return span_of(decl)
  end
end

## The name a struct, enum, alias, resource, function or constant declares; "" for an import.
export def name_of(decl: Ast.Decl) -> String
  case unwrap(decl)
    Ast.Decl.Function(node) -> return node.name
    Ast.Decl.Struct(node) -> return node.name
    Ast.Decl.Enum(node) -> return node.name
    Ast.Decl.TypeAlias(node) -> return node.name
    Ast.Decl.Resource(node) -> return node.name
    Ast.Decl.Constant(node) -> return node.name
    _ -> return ""
  end
end

## The kind of the declaration inside an export, or of the declaration itself.
export def kind_of(decl: Ast.Decl) -> Kind
  case unwrap(decl)
    Ast.Decl.Function(node) -> return Kind.Function
    Ast.Decl.Struct(node) -> return Kind.Struct
    Ast.Decl.Enum(node) -> return Kind.Enum
    Ast.Decl.TypeAlias(node) -> return Kind.TypeAlias
    Ast.Decl.Resource(node) -> return Kind.Resource
    Ast.Decl.Constant(node) -> return Kind.Constant
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

## Whether the kind is a type alias.
export def type_alias?(kind: Kind) -> Bool
  case kind
    Kind.TypeAlias -> return true
    _ -> return false
  end
end

## True for a resource of an extern block.
export def resource?(kind: Kind) -> Bool
  case kind
    Kind.Resource -> return true
    _ -> return false
  end
end

## True for a constant.
export def constant?(kind: Kind) -> Bool
  case kind
    Kind.Constant -> return true
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

## True for an export, or a constant written with export.
export def exported?(decl: Ast.Decl) -> Bool
  case decl
    Ast.Decl.Export(node) -> return true
    Ast.Decl.Constant(node) -> return node.exported
    _ -> return false
  end
end

## The text of the import line a help shows, for the path as written (quoted): the alias form, or the name list.
export def import_line(written: String, decl: Ast.ImportDecl) -> String
  case decl.alias
    Ast.Optional.Present(alias) -> return "import #{alias} from #{written}"
    Ast.Optional.Absent ->
      pieces = decl.names.map do |entry| entry_text(entry) end
      return "import {#{pieces.join(", ")}} from #{written}"
  end
end

## The alias of an import, or "" for an import list (an alias is never empty).
export def alias_of(decl: Ast.ImportDecl) -> String
  case decl.alias
    Ast.Optional.Present(alias) -> return alias
    Ast.Optional.Absent -> return ""
  end
end

## True when the name starts with a capital letter, as a TYPE_NAME token does: the case rule that tells a type from a
## function.
export def type_name?(name: String) -> Bool
  return "ABCDEFGHIJKLMNOPQRSTUVWXYZ".contains?(name.slice(0, 1))
end

## True for the name of a constant: capitals, digits and `_`, starting with a capital, at least two characters.
export def constant_name?(name: String) -> Bool
  return Base.constant_name?(name)
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

## CHECK-DECL-ORDER, in file, for the first declaration that comes after a later group. The groups are: imports, then
## constants, then struct, enum, type alias and resource (exported or not), then export def, then def. The span is of
## the declaration out of place; the help names the group it belongs to. The functions of an extern block that declares
## a resource are in the group of the types, with the resource. The record of an extern function with out parameters
## (Ast.StructDecl.record_of) goes with its function, so it has no group. This is a style rule with no meaning for
## evaluation.
export def check_order(file: String, declarations: List[Ast.Decl]) -> Result[Void]
  highest = 0
  for decl in declarations
    group = rank(decl)
    if record?(unwrap(decl))
      group = highest
    end

    if group < highest
      problem = Diag.fail(
        "CHECK-DECL-ORDER",
        "declaration is out of order",
        span_of(decl),
        Diag.Help.Hint(order_help(group)),
      )
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
    Ast.Decl.Constant(node) -> return 1
    Ast.Decl.Struct(node) -> return 2
    Ast.Decl.Enum(node) -> return 2
    Ast.Decl.TypeAlias(node) -> return 2
    Ast.Decl.Resource(node) -> return 2
    Ast.Decl.Export(node) ->
      case node.declaration
        Ast.Decl.Struct(inner) -> return 2
        Ast.Decl.Enum(inner) -> return 2
        Ast.Decl.TypeAlias(inner) -> return 2
        Ast.Decl.Resource(inner) -> return 2
        Ast.Decl.Function(inner) -> return function_rank(inner, 3)
        _ -> return 3
      end

    Ast.Decl.Function(node) -> return function_rank(node, 4)
  end
end

# A function takes the rank of its kind (3 exported, 4 private), except one of an extern block that declares a
# resource or a struct: the block sits with the types, as a whole.
def function_rank(function: Ast.FunctionDecl, plain: Int) -> Int
  case function.native
    Ast.Optional.Present(link) ->
      if link.with_types
        return 2
      end

      return plain
    Ast.Optional.Absent -> return plain
  end
end

# Whether the declaration is the record that the parser made for an extern function.
def record?(decl: Ast.Decl) -> Bool
  case decl
    Ast.Decl.Struct(node) -> return node.record_of != ""
    _ -> return false
  end
end

def order_help(group: Int) -> String
  case group
    0 -> return "imports come first, before any constant, struct, enum, type alias or function"
    1 -> return "constants come right after the imports"
    2 -> return "structs, enums, type aliases and resources come before functions"
    _ -> return "exported functions come before private functions"
  end
end

def entry_text(entry: Ast.ImportName) -> String
  if entry.name == entry.local
    return entry.name
  end

  return "#{entry.name} as #{entry.local}"
end
