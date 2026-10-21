## Where the declaration of an expression is (docs/future/39-semantic-cli.md, 39.3): the function a call names, the
## variant of an enum constructor, the struct of a construction, the field of a field access, a constant. The
## names of the linked program are unique (`@N::name` for a file that is not the root), so one scan of its declarations
## finds the declaration. A builtin has no declaration here, so it has no definition. A local is not in the
## declarations: `of_local` makes its definition from the binding that query/locals.agc found. A definition carries
## the `##` doc and the signature of its declaration, read from the file as the parser gave it
## (`LinkedModule.parsed`), because the linker drops the doc of an `export`.

import Ast from "../syntax/ast"
import Linker from "../modules/linker"
import Model from "../docs/doc_model"
import Signature from "../docs/signature"
import Source from "../syntax/source"
import T from "../syntax/types"
import Locals from "locals"

## A declaration found: its `kind` (`function`, `struct`, `enum`, `variant`, `field` or `constant`; `parameter`,
## `local`, `loop` or `pattern` for a local; `alias` is for a type argument, which no answer gives yet), its name as
## the file wrote it, and the file (the `file` of its LinkedModule), the whole declaration and its name (for a
## local, the binding node and the name; see `of_local`). `doc` is the whole `##` text or Absent; `signature` is the
## one line `agentica doc` gives the declaration (`make(name: String) -> User`), `name: Type` for a field and
## `Circle(Float)` for a variant.
export struct Definition
  kind: String
  name: String
  file: String
  span: Source.Span
  name_span: Source.Span
  doc: Ast.Optional[String]
  signature: String
end

# A top-level declaration of the linked program and the module it is in.
struct Found
  module: Linker.LinkedModule
  declaration: Ast.Decl
end

# What the parsed file says about a declaration: its doc and its signature.
struct Described
  doc: Ast.Optional[String]
  signature: String
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

## The definition of a local: the binding site, with `kind` `parameter`, `local`, `loop` or `pattern` (see
## Locals.Local), and the name and the type as the file writes it (`total: Int`) for a signature and no doc. `span` is
## the binding node when it has one (the whole parameter or assignment), else the name (`loop` and `pattern`);
## `name_span` is the name.
export def of_local(module: Linker.LinkedModule, local: Locals.Local, type_text: String) -> Definition
  return made(
    local.kind,
    local.name,
    module,
    local.span,
    local.name_span,
    Described(doc: Ast.Optional.Absent, signature: "#{local.name}: #{type_text}"),
  )
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
        return Ast.Optional.Present(Found(module: module, declaration: declaration))
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
  module = found.module
  case found.declaration
    Ast.Decl.Function(node) -> return top("function", node.name, module, node.span, node.name_span)
    Ast.Decl.Struct(node) -> return top("struct", node.name, module, node.span, node.name_span)
    Ast.Decl.Enum(node) -> return top("enum", node.name, module, node.span, node.name_span)
    Ast.Decl.TypeAlias(node) -> return top("alias", node.name, module, node.span, node.name_span)
    Ast.Decl.Constant(node) -> return top("constant", node.name, module, node.span, node.name_span)
    Ast.Decl.Import(node) -> return made("import", "", module, node.span, node.span, nothing_said())
    Ast.Decl.Export(node) -> return made("export", "", module, node.span, node.span, nothing_said())
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
              said = of_member(at.module, node.name, name)
              return Ast.Optional.Present(made("variant", name, at.module, item.span, item.name_span, said))
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
              said = of_member(at.module, node.name, name)
              return Ast.Optional.Present(made("field", name, at.module, item.span, item.name_span, said))
            end
          end
          return Ast.Optional.Absent
        _ -> return Ast.Optional.Absent
      end
  end
end

# The name as its own file wrote it, without the "@N::" prefix of the linked name.
def made(
  kind: String,
  linked: String,
  module: Linker.LinkedModule,
  span: Source.Span,
  name_span: Source.Span,
  said: Described,
) -> Definition
  return Definition(
    kind: kind,
    name: T.display_name(linked),
    file: module.file,
    span: span,
    name_span: name_span,
    doc: said.doc,
    signature: said.signature,
  )
end

# A declaration of the top level, with the doc and signature the parsed file gives it.
def top(
  kind: String,
  linked: String,
  module: Linker.LinkedModule,
  span: Source.Span,
  name_span: Source.Span,
) -> Definition
  return made(kind, linked, module, span, name_span, of_item(module, linked))
end

def nothing_said() -> Described
  return Described(doc: Ast.Optional.Absent, signature: "")
end

# The doc and signature of the top-level declaration with the linked name `linked`, from the parsed file.
def of_item(module: Linker.LinkedModule, linked: String) -> Described
  name = T.display_name(linked)
  for item in Model.declared(module.parsed, module.text)
    if item.name == name
      return Described(doc: item.doc, signature: item.signature)
    end
  end
  return nothing_said()
end

# The doc and signature of a field of the struct, or a variant of the enum, `owner` (a linked name).
def of_member(module: Linker.LinkedModule, owner: String, name: String) -> Described
  owner_name = T.display_name(owner)
  for item in Model.declared(module.parsed, module.text)
    if item.name == owner_name
      case item.detail
        Model.Detail.Struct(fields) ->
          for field in fields
            if field.name == name
              return Described(doc: field.doc, signature: "#{field.name}: #{field.type}")
            end
          end
        Model.Detail.Enum(variants) ->
          for variant in variants
            if variant.name == name
              return Described(doc: variant.doc, signature: Signature.variant_text(variant.name, variant.payload))
            end
          end
        Model.Detail.Function(_, _) -> return nothing_said()
        Model.Detail.Plain -> return nothing_said()
      end
    end
  end
  return nothing_said()
end
