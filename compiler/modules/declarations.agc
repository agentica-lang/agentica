## Helpers for the top-level declarations of a parsed file, and the declaration order rule (CHECK-DECL-ORDER).

import Diag from "../diagnostics/diagnostic"
import Ast from "../syntax/ast"
import Base from "../syntax/parse_base"
import Source from "../syntax/source"
import Failure from "link_failure"

## What a top-level declaration is.
enum Kind
  Struct
  Enum
  TypeAlias
  Resource
  Function
  Constant
  Module
  Import
end

## The declaration inside an export, or the declaration itself.
def unwrap(decl: Ast.Decl) -> Ast.Decl
  case decl
    Ast.Decl.Export(node) -> node.declaration
    _ -> decl
  end
end

## The span of a declaration (of the whole export, for an exported one).
def span_of(decl: Ast.Decl) -> Source.Span
  case decl
    Ast.Decl.Import(node) -> node.span
    Ast.Decl.Reexport(node) -> node.span
    Ast.Decl.Export(node) -> node.span
    Ast.Decl.Function(node) -> node.span
    Ast.Decl.Struct(node) -> node.span
    Ast.Decl.Enum(node) -> node.span
    Ast.Decl.TypeAlias(node) -> node.span
    Ast.Decl.Resource(node) -> node.span
    Ast.Decl.Constant(node) -> node.span
    Ast.Decl.Module(node) -> node.span
  end
end

## Returns the span of the name of a type alias or a module block, and the span of the whole declaration for any other
## one.
def name_span_of(decl: Ast.Decl) -> Source.Span
  case unwrap(decl)
    Ast.Decl.TypeAlias(node) -> node.name_span
    Ast.Decl.Module(node) -> node.name_span
    _ -> span_of(decl)
  end
end

## The span of the name of a declaration: of the name itself for a constant, a function, a struct, an enum, a type
## alias or a module block, and of the whole declaration for a resource.
def declared_name_span(decl: Ast.Decl) -> Source.Span
  case unwrap(decl)
    Ast.Decl.Constant(node) -> node.name_span
    Ast.Decl.Function(node) -> node.name_span
    Ast.Decl.Struct(node) -> node.name_span
    Ast.Decl.Enum(node) -> node.name_span
    _ -> name_span_of(decl)
  end
end

## The name a struct, enum, alias, resource, function, constant or module block declares; "" for an import.
def name_of(decl: Ast.Decl) -> String
  case unwrap(decl)
    Ast.Decl.Function(node) -> node.name
    Ast.Decl.Struct(node) -> node.name
    Ast.Decl.Enum(node) -> node.name
    Ast.Decl.TypeAlias(node) -> node.name
    Ast.Decl.Resource(node) -> node.name
    Ast.Decl.Constant(node) -> node.name
    Ast.Decl.Module(node) -> node.name
    _ -> ""
  end
end

## The kind of the declaration inside an export, or of the declaration itself.
def kind_of(decl: Ast.Decl) -> Kind
  case unwrap(decl)
    Ast.Decl.Function(_) -> Kind.Function
    Ast.Decl.Struct(_) -> Kind.Struct
    Ast.Decl.Enum(_) -> Kind.Enum
    Ast.Decl.TypeAlias(_) -> Kind.TypeAlias
    Ast.Decl.Resource(_) -> Kind.Resource
    Ast.Decl.Constant(_) -> Kind.Constant
    Ast.Decl.Module(_) -> Kind.Module
    _ -> Kind.Import
  end
end

## True for a struct.
def struct?(kind: Kind) -> Bool
  case kind
    Kind.Struct -> true
    _ -> false
  end
end

## True for a function.
def function?(kind: Kind) -> Bool
  case kind
    Kind.Function -> true
    _ -> false
  end
end

## True for an enum.
def enum?(kind: Kind) -> Bool
  case kind
    Kind.Enum -> true
    _ -> false
  end
end

## Whether the kind is a type alias.
def type_alias?(kind: Kind) -> Bool
  case kind
    Kind.TypeAlias -> true
    _ -> false
  end
end

## True for a resource of an extern block.
def resource?(kind: Kind) -> Bool
  case kind
    Kind.Resource -> true
    _ -> false
  end
end

## True for a constant.
def constant?(kind: Kind) -> Bool
  case kind
    Kind.Constant -> true
    _ -> false
  end
end

## True for a module block.
def module?(kind: Kind) -> Bool
  case kind
    Kind.Module -> true
    _ -> false
  end
end

## True for an import.
def import?(kind: Kind) -> Bool
  case kind
    Kind.Import -> true
    _ -> false
  end
end

## True for an export, or a constant written with export.
def exported?(decl: Ast.Decl) -> Bool
  case decl
    Ast.Decl.Export(_) -> true
    Ast.Decl.Constant(node) -> node.exported
    _ -> false
  end
end

## The text of the import line a help shows, for the path as written (quoted): the alias form, or the name list.
def import_line(written: String, decl: Ast.ImportDecl) -> String
  case decl.alias
    some(alias) -> "import #{alias} from #{written}"
    none ->
      pieces = decl.names.map do |entry| entry_text(entry) end
      "import {#{pieces.join(", ")}} from #{written}"
  end
end

## The alias of an import, or "" for an import list (an alias is never empty).
def alias_of(decl: Ast.ImportDecl) -> String = decl.alias.unwrap_or("")

## True when the name starts with a capital letter, as a TYPE_NAME token does: the case rule that tells a type from a
## function.
def type_name?(name: String) -> Bool = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".include?(name.slice(0, 1))

## True for the name of a constant: capitals, digits and `_`, starting with a capital, at least two characters.
def constant_name?(name: String) -> Bool = Base.constant_name?(name)

## The imports of a file, in order.
def imports_of(declarations: List[Ast.Decl]) -> List[Ast.ImportDecl]
  found: List[Ast.ImportDecl] = []
  for decl in declarations
    case decl
      Ast.Decl.Import(node) -> found = found.push(node)
      _ -> next
    end
  end

  found
end

## The module blocks of a file, exported or not, in order.
def modules_of(declarations: List[Ast.Decl]) -> List[Ast.ModuleDecl]
  found: List[Ast.ModuleDecl] = []
  for decl in declarations
    case unwrap(decl)
      Ast.Decl.Module(node) -> found = found.push(node)
      _ -> next
    end
  end

  found
end

## The re-exports of a file, in order.
def reexports_of(declarations: List[Ast.Decl]) -> List[Ast.ReexportDecl]
  found: List[Ast.ReexportDecl] = []
  for decl in declarations
    case decl
      Ast.Decl.Reexport(node) -> found = found.push(node)
      _ -> next
    end
  end

  found
end

## CHECK-DECL-ORDER, in file, for the first declaration that comes after a later group. The groups are: imports; the
## public part (constants and re-exports, then struct, enum, type alias, resource and module block, then functions);
## and, in a scope with `private` (`mark`), the private part in the same order. The span is of the declaration out of
## place; the help names the group it belongs to. The functions of an extern block that declares a resource are in the
## group of the types, with the resource; a resource of an extern module block is in the group of a function, with the
## block's functions. The record of an extern function with out parameters (Ast.StructDecl.record_of) goes with its
## function, so it has no group. This is a style rule with no meaning for evaluation.
def check_order(file: String, declarations: List[Ast.Decl], mark: Optional[Ast.PrivateMark]) -> Result[Void]
  highest = 0
  at = 0
  for decl in declarations
    private_part = mark.some? and at >= mark.unwrap!.index
    group = rank(decl, private_part)
    if private_part and highest < PRIVATE_PART
      highest = PRIVATE_PART
    end

    if record?(unwrap(decl))
      group = highest
    end

    if group < highest
      problem = Diag.fail(
        "CHECK-DECL-ORDER",
        "declaration is out of order",
        span_of(decl),
        Diag.Help.Hint(order_help(decl, group)),
      )

      return error(Failure.from_stage(file, problem))
    end

    if group > highest
      highest = group
    end

    at += 1
  end

  ok()
end

private

# The first group of the private part, in a scope with `private` (check_order).
PRIVATE_PART = 4

# The group of a declaration: imports 0, re-exports and constants 1, types and module blocks 2, functions 3; each but
# the imports and the re-exports 3 more in the private part. A resource of an extern module block takes the place of
# a function, as its functions do, so the block ranks as one unit with them; a resource of an extern block ranks with
# the types.
def rank(decl: Ast.Decl, private_part: Bool) -> Int
  group = plain_rank(decl)
  case decl
    Ast.Decl.Import(_) -> return group
    Ast.Decl.Reexport(_) -> return group
    _ -> group = group
  end

  return group + 3 if private_part

  group
end

def plain_rank(decl: Ast.Decl) -> Int
  case decl
    Ast.Decl.Import(_) -> 0
    Ast.Decl.Reexport(_) -> 1
    Ast.Decl.Constant(_) -> 1
    Ast.Decl.Struct(_) -> 2
    Ast.Decl.Enum(_) -> 2
    Ast.Decl.TypeAlias(_) -> 2
    Ast.Decl.Module(_) -> 2
    Ast.Decl.Resource(node) -> resource_rank(node)
    Ast.Decl.Export(node) -> plain_rank(node.declaration)
    Ast.Decl.Function(node) -> function_rank(node)
  end
end

def resource_rank(resource: Ast.ResourceDecl) -> Int
  return 3 if resource.module != ""

  2
end

# A function is in the group of the functions, except one of an extern block that declares a resource or a struct: the
# block sits with the types, as a whole.
def function_rank(function: Ast.FunctionDecl) -> Int
  case function.native
    some(link) ->
      return 2 if link.with_types

      3
    none -> 3
  end
end

# Whether the declaration is the record that the parser made for an extern function.
def record?(decl: Ast.Decl) -> Bool
  case decl
    Ast.Decl.Struct(node) -> node.record_of != ""
    _ -> false
  end
end

def order_help(decl: Ast.Decl, group: Int) -> String
  case decl
    Ast.Decl.Import(_) -> "imports come first, before any declaration and before private"
    Ast.Decl.Reexport(_) -> "a re-export is public: write it above private, with the constants"
    _ ->
      case group
        1 -> "constants come right after the imports and the re-exports"
        2 -> "structs, enums, type aliases, resources and modules come before functions"
        3 -> "the public functions come last above private"
        4 -> "the private constants come right after private"
        5 -> "the private structs, enums, type aliases, resources and modules come before the private functions"
        _ -> "a function comes after the constants and types of its part"
      end
  end
end

def entry_text(entry: Ast.ImportName) -> String
  return entry.name if entry.name == entry.local

  "#{entry.name} as #{entry.local}"
end
