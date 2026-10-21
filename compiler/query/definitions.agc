## Where the declaration of an expression is (docs/future/39-semantic-cli.md, 39.3): the function a call names, the
## variant of an enum constructor, the struct of a construction, the field of a field access, a constant. The
## names of the linked program are unique (`@N::name` for a file that is not the root), so one scan of its declarations
## finds the declaration. A builtin and a local have no declaration here, so they have no definition.

import Ast from "../syntax/ast"
import Linker from "../modules/linker"
import Source from "../syntax/source"
import T from "../syntax/types"

## A declaration found: its `kind` (`function`, `struct`, `enum`, `variant`, `field` or `constant`; `alias` is for a
## type argument, which no answer gives yet), its name as the file wrote it, and the file (the `file` of its
## LinkedModule), the whole declaration and its name.
export struct Definition
  kind: String
  name: String
  file: String
  span: Source.Span
  name_span: Source.Span
end

# A top-level declaration of the linked program and the file it is in.
struct Found
  file: String
  declaration: Ast.Decl
end

## The definition of what `expr` names, or Absent. `types` is `Checked.types`: the struct of a field access is the type
## of its target.
export def of_expr(modules: List[Linker.LinkedModule], types: List[T.Type], expr: Ast.Expr) -> Ast.Optional[Definition]
  case expr
    Ast.Expr.Call(node) -> return top_level(modules, node.name)
    Ast.Expr.FunctionRef(node) -> return top_level(modules, node.name)
    Ast.Expr.Construct(node) -> return top_level(modules, node.type_name)
    # Not reached yet: the checker records no type for a TypeName (a type argument), so `type-at` skips it. The arm
    # waits for a later PR that answers a type argument; it is also the only way to an `alias` definition.
    Ast.Expr.TypeName(node) -> return top_level(modules, node.name)
    Ast.Expr.ConstRef(node) -> return top_level(modules, node.name)
    Ast.Expr.EnumConstructor(node) -> return variant(find(modules, node.enum_name), node.variant_name)
    Ast.Expr.FieldAccess(node) -> return field(find(modules, T.name(target_type(types, node.target))), node.name)
    _ -> return Ast.Optional.Absent
  end
end

# The type recorded for the target of a field access; Unknown when there is none.
def target_type(types: List[T.Type], target: Ast.Expr) -> T.Type
  id = Ast.expr_id(target)
  if id < types.size
    return types[id]
  end
  return T.Type.Unknown
end

def top_level(modules: List[Linker.LinkedModule], name: String) -> Ast.Optional[Definition]
  case find(modules, name)
    Ast.Optional.Present(found) -> return Ast.Optional.Present(whole(found))
    Ast.Optional.Absent -> return Ast.Optional.Absent
  end
end

# The first declaration with the linked name `name`; Absent for a builtin, which no file declares.
def find(modules: List[Linker.LinkedModule], name: String) -> Ast.Optional[Found]
  if name == ""
    return Ast.Optional.Absent
  end
  for module in modules
    for declaration in module.declarations
      if declared_name(declaration) == name
        return Ast.Optional.Present(Found(file: module.file, declaration: declaration))
      end
    end
  end
  return Ast.Optional.Absent
end

def declared_name(declaration: Ast.Decl) -> String
  case declaration
    Ast.Decl.Function(node) -> return node.name
    Ast.Decl.Struct(node) -> return node.name
    Ast.Decl.Enum(node) -> return node.name
    Ast.Decl.TypeAlias(node) -> return node.name
    Ast.Decl.Constant(node) -> return node.name
    Ast.Decl.Import(_) -> return ""
    Ast.Decl.Export(_) -> return ""
  end
end

# Imports and exports are not in the linked program and have no name, so `find` never gives them; their arms keep the
# case complete.
def whole(found: Found) -> Definition
  case found.declaration
    Ast.Decl.Function(node) -> return made("function", node.name, found.file, node.span, node.name_span)
    Ast.Decl.Struct(node) -> return made("struct", node.name, found.file, node.span, node.name_span)
    Ast.Decl.Enum(node) -> return made("enum", node.name, found.file, node.span, node.name_span)
    Ast.Decl.TypeAlias(node) -> return made("alias", node.name, found.file, node.span, node.name_span)
    Ast.Decl.Constant(node) -> return made("constant", node.name, found.file, node.span, node.name_span)
    Ast.Decl.Import(node) -> return made("import", "", found.file, node.span, node.span)
    Ast.Decl.Export(node) -> return made("export", "", found.file, node.span, node.span)
  end
end

def variant(found: Ast.Optional[Found], name: String) -> Ast.Optional[Definition]
  case found
    Ast.Optional.Absent -> return Ast.Optional.Absent
    Ast.Optional.Present(at) ->
      case at.declaration
        Ast.Decl.Enum(node) ->
          for item in node.variants
            if item.name == name
              return Ast.Optional.Present(made("variant", name, at.file, item.span, item.name_span))
            end
          end
          return Ast.Optional.Absent
        _ -> return Ast.Optional.Absent
      end
  end
end

def field(found: Ast.Optional[Found], name: String) -> Ast.Optional[Definition]
  case found
    Ast.Optional.Absent -> return Ast.Optional.Absent
    Ast.Optional.Present(at) ->
      case at.declaration
        Ast.Decl.Struct(node) ->
          for item in node.fields
            if item.name == name
              return Ast.Optional.Present(made("field", name, at.file, item.span, item.name_span))
            end
          end
          return Ast.Optional.Absent
        _ -> return Ast.Optional.Absent
      end
  end
end

# The name as its own file wrote it, without the "@N::" prefix of the linked name.
def made(kind: String, linked: String, file: String, span: Source.Span, name_span: Source.Span) -> Definition
  return Definition(kind: kind, name: T.display_name(linked), file: file, span: span, name_span: name_span)
end
